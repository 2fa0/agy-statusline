const std = @import("std");
const builtin = @import("builtin");
const c = @import("common.zig");
const session = @import("session.zig");
const settings_mod = @import("settings.zig");
const A = c.A;
const V = c.V;
extern "c" fn sqlite3_open_v2([*:0]const u8, *?*anyopaque, c_int, ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(?*anyopaque) c_int;
extern "c" fn sqlite3_busy_timeout(?*anyopaque, c_int) c_int;
extern "c" fn sqlite3_errcode(?*anyopaque) c_int;
extern "c" fn sqlite3_prepare_v2(?*anyopaque, [*:0]const u8, c_int, *?*anyopaque, ?*?[*:0]const u8) c_int;
extern "c" fn sqlite3_step(?*anyopaque) c_int;
extern "c" fn sqlite3_finalize(?*anyopaque) c_int;
extern "c" fn sqlite3_column_blob(?*anyopaque, c_int) ?[*]const u8;
extern "c" fn sqlite3_column_bytes(?*anyopaque, c_int) c_int;
extern "c" fn sqlite3_column_int64(?*anyopaque, c_int) i64;
extern "c" fn sqlite3_column_type(?*anyopaque, c_int) c_int;

const Query = struct {
    stmt: ?*anyopaque,
    fn init(a: A, db: ?*anyopaque, sql: []const u8) !Query {
        var stmt: ?*anyopaque = null;
        const terminated = try a.dupeZ(u8, sql);
        if (sqlite3_prepare_v2(db, terminated, -1, &stmt, null) != 0) {
            if (stmt != null) _ = sqlite3_finalize(stmt);
            return error.SQLiteQuery;
        }
        return .{ .stmt = stmt };
    }
    fn deinit(self: Query) void {
        _ = sqlite3_finalize(self.stmt);
    }
    fn next(self: Query) !bool {
        return switch (sqlite3_step(self.stmt)) {
            100 => true,
            101 => false,
            else => error.SQLiteRead,
        };
    }
    fn blob(self: Query, col: c_int) []const u8 {
        const p = sqlite3_column_blob(self.stmt, col) orelse return "";
        const len = sqlite3_column_bytes(self.stmt, col);
        return if (len > 0) p[0..@intCast(len)] else "";
    }
    fn integer(self: Query, col: c_int) ?i64 {
        return if (sqlite3_column_type(self.stmt, col) == 1) sqlite3_column_int64(self.stmt, col) else null;
    }
};
const Usage = struct {
    requests: i64 = 0,
    recorded: i64 = 0,
    input: i64 = 0,
    cached: i64 = 0,
    output: i64 = 0,
    fn ingest(self: *Usage, vals: [3]?i64) void {
        self.requests += 1;
        const i = vals[0] orelse return;
        const r = vals[1] orelse return;
        const o = vals[2] orelse return;
        self.recorded += 1;
        self.input +|= i;
        self.cached +|= r;
        self.output +|= o;
    }
    fn value(self: Usage, a: A) !V {
        var out = c.object(a);
        try c.put(a, &out, "requestCount", c.n(self.requests));
        try c.put(a, &out, "recordedCount", c.n(self.recorded));
        try c.put(a, &out, "inputTokens", if (self.recorded > 0) c.n(self.input) else .null);
        try c.put(a, &out, "cacheReadTokens", if (self.recorded > 0) c.n(self.cached) else .null);
        try c.put(a, &out, "outputTokens", if (self.recorded > 0) c.n(self.output) else .null);
        try c.put(a, &out, "totalTokens", if (self.recorded > 0) c.n(self.input +| self.cached +| self.output) else .null);
        const denom = @as(f64, @floatFromInt(self.input)) + @as(f64, @floatFromInt(self.cached));
        try c.put(a, &out, "cacheHitPct", if (denom > 0) c.f(100 * @as(f64, @floatFromInt(self.cached)) / denom) else .null);
        return out;
    }
};
const Point = struct {
    request: i64,
    idx: ?i64,
    at: ?f64,
    model: []const u8,
    context: ?i64,
    compact: bool,
    /// Usage reported by the log for this request. Kept inside the bounded
    /// 120-point ring (instead of a per-request map) so completing a partial
    /// SQLite row never grows resident memory with the conversation.
    usage: [3]?i64 = .{ null, null, null },
};
// Ignore message bodies and tool payloads while parsing logs. They are not
// needed for telemetry and can dwarf the actual counters.
const TranscriptRow = struct {
    created_at: V = .null,
    type: V = .null,
    status: V = .null,
    source: V = .null,
    model: V = .null,
    step_index: V = .null,
    input_tokens: V = .null,
    cache_read_tokens: V = .null,
    output_tokens: V = .null,
};
const chunk_size: usize = 64 * 1024;
/// Below this size a suspicious write verifies every chunk: the cost is bounded
/// and it removes any sampling gap for the common short conversation.
const full_verify_limit: u64 = 512 * 1024;
/// 16384 chunks = 1 GiB of tracked history with 8 bytes per chunk.
const max_tracked_chunks: usize = 16384;
/// Bytes re-read per poll while the log is otherwise idle. The rotating scrub
/// walks one chunk per budget slot, so a block edited in place is corrected
/// after at most `tracked_chunks / chunks_per_poll` polls.
const verify_budget_bytes: usize = 128 * 1024;

const Transcript = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8 = "",
    identity: c.Sig = .{},
    offset: u64 = 0,
    chunk_hashes: std.ArrayList(u64),
    /// File offset of `chunk_hashes[0]`; non-zero only past the 1 GiB cap.
    verified_from: u64 = 0,
    /// Test seam: a small cap exercises the rolling window without 1 GiB files.
    chunk_cap: usize = max_tracked_chunks,
    cur_chunk_hash: std.hash.Wyhash = std.hash.Wyhash.init(0),
    cur_chunk_len: usize = 0,
    scrub_cursor: usize = 0,
    /// Full rescans triggered by verification failures; observable in tests.
    reloads: u64 = 0,
    corrupt_lines: usize = 0,
    first: ?f64 = null,
    last: ?f64 = null,
    user: ?f64 = null,
    steps: i64 = 0,
    /// Completed, non-compaction generations actually present in the log. This
    /// is evidence the log was parsed for real, unlike a lone USER_INPUT row.
    generations: i64 = 0,
    turns: i64 = 0,
    compactions: i64 = 0,
    usage: Usage = .{},
    models: std.StringArrayHashMap(Usage),
    points: [120]Point = undefined,
    point_count: usize = 0,
    latest: ?[3]?i64 = null,
    latest_model: []const u8 = "",
    fn init() Transcript {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
            .chunk_hashes = std.ArrayList(u64).init(std.heap.c_allocator),
            .models = std.StringArrayHashMap(Usage).init(std.heap.c_allocator),
        };
    }
    fn deinit(self: *Transcript) void {
        self.chunk_hashes.deinit();
        self.models.deinit();
        self.arena.deinit();
    }
    fn reset(self: *Transcript) void {
        const reloads = self.reloads;
        const cap = self.chunk_cap;
        self.deinit();
        self.* = init();
        self.reloads = reloads;
        self.chunk_cap = cap;
    }
    fn ingest(self: *Transcript, item: TranscriptRow) !void {
        self.steps += 1;
        const at = c.timestamp(c.str(item.created_at));
        if (at) |ts| {
            self.first = @min(self.first orelse ts, ts);
            self.last = @max(self.last orelse ts, ts);
        }
        const typ = c.str(item.type);
        if (c.eq(typ, "USER_INPUT") or c.eq(c.str(item.source), "USER_EXPLICIT")) {
            self.turns += 1;
            if (at) |ts| self.user = ts;
        }
        if (!c.eq(c.str(item.status), "DONE") or (!c.eq(typ, "PLANNER_RESPONSE") and !c.eq(typ, "CHECKPOINT"))) return;
        const name = c.modelKey(c.str(item.model));
        const entry = try self.models.getOrPut(name);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.arena.allocator().dupe(u8, name);
            entry.value_ptr.* = .{};
        }
        const vals = [3]?i64{ c.tokens(item.input_tokens), c.tokens(item.cache_read_tokens), c.tokens(item.output_tokens) };
        self.usage.ingest(vals);
        entry.value_ptr.ingest(vals);
        const compact = c.eq(typ, "CHECKPOINT");
        if (!compact) self.generations += 1;
        if (compact) self.compactions += 1 else {
            self.latest = vals;
            if (c.str(item.model).len > 0) self.latest_model = entry.key_ptr.*;
        }
        if (self.point_count == self.points.len) {
            std.mem.copyForwards(Point, self.points[0 .. self.points.len - 1], self.points[1..]);
            self.point_count -= 1;
        }
        self.points[self.point_count] = .{
            .request = self.usage.requests,
            .idx = c.int(item.step_index),
            .at = at,
            .model = entry.key_ptr.*,
            .context = if (!compact and vals[0] != null and vals[1] != null) vals[0].? +| vals[1].? else null,
            .compact = compact,
            // A real zero and an unknown value are different answers; both
            // survive because the value is an optional integer.
            .usage = vals,
        };
        self.point_count += 1;
    }
    /// Log usage for one step, searched newest-first inside the bounded 120-point
    /// ring. Deliberate limit: a step older than the window is *not* completed —
    /// callers keep whatever SQLite reported instead of borrowing another
    /// request's numbers (null stays unknown, a real zero stays zero).
    fn usageForStep(self: *const Transcript, step_idx: i64) ?[3]?i64 {
        var i = self.point_count;
        while (i > 0) {
            i -= 1;
            const point = self.points[i];
            if (point.compact) continue;
            if (point.idx) |idx| {
                if (idx == step_idx) return point.usage;
            }
        }
        return null;
    }
    fn recordPrefixBytes(self: *Transcript, data: []const u8) !void {
        var pos: usize = 0;
        while (pos < data.len) {
            const space = chunk_size - self.cur_chunk_len;
            const take = @min(space, data.len - pos);
            self.cur_chunk_hash.update(data[pos .. pos + take]);
            self.cur_chunk_len += take;
            pos += take;
            if (self.cur_chunk_len == chunk_size) {
                const finalized = self.cur_chunk_hash.final();
                if (self.chunk_hashes.items.len < self.chunk_cap) {
                    try self.chunk_hashes.append(finalized);
                } else {
                    // Past the cap the window rolls: drop the oldest chunk so the
                    // tracked range still ends at the file end. Memory, and the
                    // cost of one verification pass, stay bounded either way.
                    std.mem.copyForwards(u64, self.chunk_hashes.items[0 .. self.chunk_hashes.items.len - 1], self.chunk_hashes.items[1..]);
                    self.chunk_hashes.items[self.chunk_hashes.items.len - 1] = finalized;
                    self.verified_from += chunk_size;
                }
                self.cur_chunk_hash = std.hash.Wyhash.init(0);
                self.cur_chunk_len = 0;
            }
        }
    }
    fn trackedBytes(self: *const Transcript) u64 {
        return self.verified_from + @as(u64, self.chunk_hashes.items.len) * chunk_size + self.cur_chunk_len;
    }
    fn verifyRange(file: std.fs.File, start_pos: u64, len: usize, expected: u64) !bool {
        var buf: [chunk_size]u8 = undefined;
        var h = std.hash.Wyhash.init(0);
        var done: usize = 0;
        while (done < len) {
            const want = @min(len - done, buf.len);
            const got = try file.preadAll(buf[0..want], start_pos + done);
            if (got != want) return false;
            h.update(buf[0..want]);
            done += got;
        }
        return h.final() == expected;
    }
    fn verifyChunk(self: *Transcript, file: std.fs.File, idx: usize) !bool {
        return verifyRange(file, self.verified_from + @as(u64, idx) * chunk_size, chunk_size, self.chunk_hashes.items[idx]);
    }
    /// Re-read part of the tracked prefix. Runs on every poll, not only when the
    /// file grew: an edit that lands while nobody is appending still has to be
    /// corrected, and the rotating scrub is what eventually reaches it.
    fn prefixUnchanged(self: *Transcript, file: std.fs.File, thorough: bool) !bool {
        if (self.offset != self.trackedBytes()) return false;
        if (self.cur_chunk_len > 0) {
            var copy = self.cur_chunk_hash;
            if (!try verifyRange(file, self.offset - self.cur_chunk_len, self.cur_chunk_len, copy.final())) return false;
        }
        const n = self.chunk_hashes.items.len;
        if (n == 0) return true;
        if (thorough and self.offset <= full_verify_limit) {
            for (0..n) |idx| {
                if (!try self.verifyChunk(file, idx)) return false;
            }
            return true;
        }
        var scrub_budget = @max(1, verify_budget_bytes / chunk_size);
        if (thorough) {
            // A concurrent rewrite is most likely to touch the head, the middle
            // or the freshest data, so check those first.
            for ([_]usize{ 0, n / 2, n - 1 }) |idx| {
                if (!try self.verifyChunk(file, idx)) return false;
            }
            // Still advance the rotating scrub once per pass, otherwise a log
            // that keeps appending would never look anywhere else.
            scrub_budget = 1;
        }
        while (scrub_budget > 0) : (scrub_budget -= 1) {
            const idx = self.scrub_cursor % n;
            self.scrub_cursor +%= 1;
            if (!try self.verifyChunk(file, idx)) return false;
        }
        return true;
    }
    fn update(self: *Transcript, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const st = try file.stat();
        const replaced = !c.eq(self.path, path) or self.identity.inode != st.inode or st.size < self.offset;
        const changed = st.mtime != self.identity.mtime or st.ctime != self.identity.ctime or st.size != self.identity.size;
        // Growth alone does not prove append-only writes: verify prefix chunks
        // (exhaustively up to 512 KiB, and sampled + rotating scrub beyond).
        // The check also runs while the file looks untouched, otherwise a block
        // edited just before the log went quiet would never be re-read.
        var rescan = replaced;
        if (!rescan and (changed or self.identity.exists)) {
            if (!try self.prefixUnchanged(file, changed)) rescan = true;
        }
        if (rescan) {
            self.reloads += 1;
            self.reset();
            self.path = try self.arena.allocator().dupe(u8, path);
        }
        try file.seekTo(self.offset);
        var limited = std.io.limitedReader(file.reader(), st.size - self.offset);
        var buffered = std.io.bufferedReader(limited.reader());
        var line = std.ArrayList(u8).init(std.heap.c_allocator);
        defer line.deinit();
        var line_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer line_arena.deinit();
        while (true) {
            buffered.reader().readUntilDelimiterArrayList(&line, '\n', 16 * 1024 * 1024) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };
            try self.recordPrefixBytes(line.items);
            try self.recordPrefixBytes("\n");
            const item = std.json.parseFromSlice(TranscriptRow, line_arena.allocator(), line.items, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
                if (std.mem.trim(u8, line.items, " \t\r").len > 0) {
                    self.corrupt_lines += 1;
                }
                self.offset += line.items.len + 1;
                _ = line_arena.reset(.free_all);
                continue;
            };
            try self.ingest(item.value);
            self.offset += line.items.len + 1;
            _ = line_arena.reset(.free_all);
        }
        self.identity = .{ .inode = st.inode, .size = st.size, .mtime = st.mtime, .ctime = st.ctime, .exists = true };
    }
};
const Gen = struct {
    idx: i64,
    input: ?i64 = null,
    cached: ?i64 = null,
    written: ?i64 = null,
    output: ?i64 = null,
    /// Protobuf `chat` field 11 is TTFT; field 12 (`duration`) is streaming generation duration.
    ttft: ?f64 = null,
    duration: ?f64 = null,
    speed: ?f64 = null,
    model: []const u8 = "",
};
fn generation(idx: i64, raw: []const u8) ?Gen {
    const chat = c.bytes(raw, 1) orelse return null;
    if (chat.len == 0) return null;
    var out: Gen = .{ .idx = idx };
    if (c.bytes(chat, 4)) |u| {
        out.input = c.number(u, 2) orelse c.number(u, 1);
        out.cached = c.number(u, 5);
        out.written = c.number(u, 4);
        out.output = c.number(u, 3);
    }
    out.ttft = c.duration(c.bytes(chat, 11));
    out.duration = c.duration(c.bytes(chat, 12));
    if (out.duration) |d| {
        if (d >= 0.1 and (out.output orelse 0) > 0) {
            const speed = @as(f64, @floatFromInt(out.output.?)) / d;
            if (speed > 0 and speed < 1000) {
                out.speed = speed;
            }
        }
    }
    const name = std.mem.trim(u8, c.bytes(chat, 19) orelse "", " \r\n\t");
    var valid = true;
    for (name) |ch| {
        if (ch < 32 or ch >= 127) valid = false;
    }
    if (valid) out.model = name;
    return out;
}
const Speed = struct { tokens: f64 = 0, seconds: f64 = 0, samples: i64 = 0 };
/// Why the conversation database did or did not provide numbers. "No data" and
/// "could not read" look identical in the panel unless we say which it was.
pub const DbState = enum { ok, empty, missing, locked, unreadable, corrupt };
pub const TranscriptState = enum { ok, missing, failed };
pub const QuotaState = enum { ok, stale, missing, unreadable, disabled };

const DbResult = struct {
    state: DbState = .ok,
    readable: bool = false,
    latest_mtime_sec: ?f64 = null,
    latest: ?Gen = null,
    history: [12]Gen = undefined,
    count: usize = 0,
    speeds: std.StringArrayHashMap(Speed),
    usage: ?[4]?i64 = null,
    /// Step index the usage above belongs to, so the log can complete the same
    /// request without borrowing numbers from another one.
    usage_idx: ?i64 = null,
    live: bool = false,
    live_idx: ?i64 = null,
    live_type: ?i64 = null,
    /// Newest row in `steps`, whether active or finished.
    newest_idx: ?i64 = null,
    /// The active row is older than a finished step; only keep it live while
    /// its streamed text still grows (see the residue guard in snapshot()).
    live_behind: bool = false,
    status: ?i64 = null,
    chars: ?i64 = null,
    cpt: f64 = 1.4,
    fn init(a: A) DbResult {
        return .{ .speeds = std.StringArrayHashMap(Speed).init(a) };
    }
};
fn stepUsage(raw: []const u8) ?[4]?i64 {
    const u = c.bytes(raw, 9) orelse return null;
    const i = c.number(u, 2);
    const o = c.number(u, 3);
    const w = c.number(u, 4);
    const r = c.number(u, 5);
    if (i == null and o == null and w == null and r == null) return null;
    return .{ i, r, o, w };
}
fn fileUri(a: A, path: []const u8, query: []const u8) ![:0]const u8 {
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice(if (std.mem.startsWith(u8, path, "/")) "file://" else "file:///");
    for (path) |ch| {
        const byte: u8 = if (builtin.os.tag == .windows and ch == '\\') '/' else ch;
        switch (byte) {
            '%' => try out.appendSlice("%25"),
            '?' => try out.appendSlice("%3F"),
            '#' => try out.appendSlice("%23"),
            else => try out.append(byte),
        }
    }
    try out.append('?');
    try out.appendSlice(query);
    return out.toOwnedSliceSentinel(0);
}
fn tryOpenDb(a: A, target: [:0]const u8, flags: c_int, err_out: *c_int) ?*anyopaque {
    err_out.* = 0;
    var db: ?*anyopaque = null;
    if (sqlite3_open_v2(target, &db, flags, null) != 0) {
        if (db != null) {
            err_out.* = sqlite3_errcode(db);
            _ = sqlite3_close(db);
        }
        return null;
    }
    _ = sqlite3_busy_timeout(db, 100);
    var sanity = Query.init(a, db, "PRAGMA query_only=ON") catch {
        err_out.* = sqlite3_errcode(db);
        _ = sqlite3_close(db);
        return null;
    };
    _ = sanity.next() catch {
        err_out.* = sqlite3_errcode(db);
        sanity.deinit();
        _ = sqlite3_close(db);
        return null;
    };
    sanity.deinit();
    var tables = Query.init(a, db, "SELECT name FROM sqlite_master LIMIT 1") catch {
        err_out.* = sqlite3_errcode(db);
        _ = sqlite3_close(db);
        return null;
    };
    _ = tables.next() catch {
        err_out.* = sqlite3_errcode(db);
        tables.deinit();
        _ = sqlite3_close(db);
        return null;
    };
    tables.deinit();
    return db;
}
fn isWalHeader(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    var hdr: [20]u8 = undefined;
    const len = file.readAll(&hdr) catch return false;
    return len == hdr.len and (hdr[18] == 2 or hdr[19] == 2);
}
const OpenOutcome = struct { db: ?*anyopaque = null, state: DbState = .ok };
fn openReadOnlyDb(a: A, path: []const u8) !OpenOutcome {
    var err: c_int = 0;
    // Prefer plain mode=ro so in-flight WAL updates remain visible.
    if (tryOpenDb(a, try a.dupeZ(u8, path), 1, &err)) |db| return .{ .db = db };
    // Never bypass an active SQLITE_BUSY (5) / SQLITE_LOCKED (6) lock with immutable=1.
    const primary = err & 0xff;
    if (primary == 5 or primary == 6) return .{ .state = .locked };
    // Closed WAL databases with no active -wal/-shm reject mode=ro because
    // SQLite cannot create -shm read-only; immutable=1 is safe when -wal is absent/empty.
    const wal_sig = c.sig(try c.fmt(a, "{s}-wal", .{path}));
    if ((wal_sig.exists and wal_sig.size > 0) or !isWalHeader(path)) return .{ .state = .unreadable };
    const db = tryOpenDb(a, try fileUri(a, path, "immutable=1"), 0x41, &err);
    return .{ .db = db, .state = if (db != null) .ok else .unreadable };
}
fn classifySqliteErr(db: ?*anyopaque, lock_error: *bool, query_error: *bool) void {
    const primary = sqlite3_errcode(db) & 0xff;
    if (primary == 5 or primary == 6) {
        lock_error.* = true;
    } else {
        query_error.* = true;
    }
}
fn readDb(a: A, path: []const u8, summary_only: bool) !DbResult {
    var out = DbResult.init(a);
    if (!c.sig(path).exists) {
        out.state = .missing;
        return out;
    }
    const opened = try openReadOnlyDb(a, path);
    const db = opened.db orelse {
        out.state = opened.state;
        return out;
    };
    defer _ = sqlite3_close(db);
    out.readable = true;
    var lock_error = false;
    var query_error = false;
    var corrupt_rows = false;
    var has_gen_table = false;
    var has_steps_table = false;
    var other_table_count: usize = 0;
    if (Query.init(a, db, "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")) |tq| {
        defer tq.deinit();
        while (true) {
            const has_row = tq.next() catch {
                classifySqliteErr(db, &lock_error, &query_error);
                break;
            };
            if (!has_row) break;
            const tname = tq.blob(0);
            if (c.eq(tname, "gen_metadata")) {
                has_gen_table = true;
            } else if (c.eq(tname, "steps")) {
                has_steps_table = true;
            } else {
                other_table_count += 1;
            }
        }
    } else |_| {
        classifySqliteErr(db, &lock_error, &query_error);
    }
    if (has_gen_table) {
        if (Query.init(a, db, if (summary_only) "SELECT idx,data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx DESC LIMIT 40" else "SELECT idx,data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx DESC")) |q| {
            defer q.deinit();
            var gen_rows: usize = 0;
            var gen_parsed: usize = 0;
            while (true) {
                const has_row = q.next() catch {
                    classifySqliteErr(db, &lock_error, &query_error);
                    break;
                };
                if (!has_row) break;
                gen_rows += 1;
                var rec = generation(q.integer(0) orelse continue, q.blob(1)) orelse continue;
                gen_parsed += 1;
                if (out.count < 12) {
                    rec.model = try a.dupe(u8, rec.model);
                    out.history[out.count] = rec;
                    out.count += 1;
                    if (out.latest == null) out.latest = rec;
                }
                if (rec.model.len > 0 and rec.speed != null and (rec.output orelse 0) > 0) {
                    const key = c.modelKey(rec.model);
                    const entry = try out.speeds.getOrPut(key);
                    if (!entry.found_existing) {
                        entry.key_ptr.* = try a.dupe(u8, key);
                        entry.value_ptr.* = .{};
                    }
                    entry.value_ptr.tokens += @floatFromInt(rec.output.?);
                    entry.value_ptr.seconds += @as(f64, @floatFromInt(rec.output.?)) / rec.speed.?;
                    entry.value_ptr.samples += 1;
                }
            }
            // Rows that exist but cannot be decoded are damage, not an empty
            // conversation: reporting `empty` would hide a broken database.
            // Partially readable history stays usable, only a fully undecodable
            // table is called corrupt.
            if (gen_rows > 0 and gen_parsed == 0) corrupt_rows = true;
        } else |_| {
            classifySqliteErr(db, &lock_error, &query_error);
        }
    }
    var metadata: ?[]const u8 = null;
    var order: []const u8 = "rowid";
    var payload: ?[]const u8 = null;
    var has_data = false;
    var has_idx = false;
    var has_status = false;
    var has_type = false;
    if (has_steps_table) {
        if (Query.init(a, db, "PRAGMA table_info(steps)")) |cols| {
            defer cols.deinit();
            while (true) {
                const has_row = cols.next() catch {
                    classifySqliteErr(db, &lock_error, &query_error);
                    break;
                };
                if (!has_row) break;
                const name = cols.blob(1);
                if (c.eq(name, "metadata")) metadata = "metadata";
                if (c.eq(name, "data")) has_data = true;
                if (c.eq(name, "idx")) {
                    order = "idx";
                    has_idx = true;
                }
                if (c.eq(name, "step_idx") and !has_idx) order = "step_idx";
                if (c.eq(name, "step_payload")) payload = "step_payload";
                if (c.eq(name, "status")) has_status = true;
                if (c.eq(name, "step_type")) has_type = true;
            }
        } else |_| {
            classifySqliteErr(db, &lock_error, &query_error);
        }
        if (metadata == null and has_data) metadata = "data";
        if (payload == null) payload = metadata;
        if (metadata == null and payload == null) query_error = true;
    } else if (!has_gen_table and other_table_count > 0) {
        query_error = true;
    }
    if (metadata) |col| {
        const sql = try c.fmt(a, "SELECT {s},{s} FROM steps WHERE {s} IS NOT NULL ORDER BY {s} DESC LIMIT 40", .{ order, col, col, order });
        if (Query.init(a, db, sql)) |q| {
            defer q.deinit();
            while (true) {
                const has_row = q.next() catch {
                    classifySqliteErr(db, &lock_error, &query_error);
                    break;
                };
                if (!has_row) break;
                if (stepUsage(q.blob(1))) |u| {
                    if (u[0] != null or u[1] != null or u[3] != null) {
                        out.usage = u;
                        out.usage_idx = q.integer(0);
                        break;
                    }
                    if (out.usage == null) {
                        out.usage = u;
                        out.usage_idx = q.integer(0);
                    }
                }
            }
        } else |_| {
            classifySqliteErr(db, &lock_error, &query_error);
        }
    }
    if (payload != null and has_status) {
        const sql = try c.fmt(a, "SELECT {s},status,{s},{s} FROM steps ORDER BY {s} DESC LIMIT 8", .{ order, payload.?, if (has_type) "step_type" else "NULL", order });
        if (Query.init(a, db, sql)) |q| {
            defer q.deinit();
            while (true) {
                const has_row = q.next() catch {
                    classifySqliteErr(db, &lock_error, &query_error);
                    break;
                };
                if (!has_row) break;
                const row_idx = q.integer(0);
                if (out.newest_idx == null) out.newest_idx = row_idx;
                const status = q.integer(1) orelse 0;
                if (status != 1 and status != 2 and status != 8) continue;
                // A finished step can sit above a step that is still streaming;
                // report the active row instead of hiding it behind the newest.
                // A leftover active row from an old round is filtered out later
                // by the growth check in snapshot().
                out.live = true;
                out.live_idx = row_idx;
                out.status = status;
                out.live_type = q.integer(3);
                out.chars = c.chars(q.blob(2));
                out.live_behind = out.newest_idx != null and row_idx != null and out.newest_idx.? > row_idx.?;
                break;
            }
        } else |_| {
            classifySqliteErr(db, &lock_error, &query_error);
        }
    }
    if (out.live and metadata != null and payload != null) {
        const sql = try c.fmt(a, "SELECT {s},{s} FROM steps WHERE {s} IS NOT NULL ORDER BY {s} DESC LIMIT 24", .{ payload.?, metadata.?, metadata.?, order });
        if (Query.init(a, db, sql)) |q| {
            defer q.deinit();
            var chars: f64 = 0;
            var tokens: f64 = 0;
            while (true) {
                const has_row = q.next() catch {
                    classifySqliteErr(db, &lock_error, &query_error);
                    break;
                };
                if (!has_row) break;
                const u = stepUsage(q.blob(1)) orelse continue;
                const out_tok = u[2] orelse continue;
                if (out_tok <= 0) continue;
                const count = c.chars(q.blob(0)) orelse continue;
                if (count <= 0) continue;
                chars += @floatFromInt(count);
                tokens += @floatFromInt(out_tok);
            }
            if (chars > 0 and tokens > 0) out.cpt = std.math.clamp(chars / tokens, 0.4, 6);
        } else |_| {
            classifySqliteErr(db, &lock_error, &query_error);
        }
    }
    if (lock_error) {
        out.state = .locked;
    } else if (query_error) {
        out.state = .unreadable;
    } else if (corrupt_rows) {
        out.state = .corrupt;
    } else if (out.count == 0 and out.usage == null and !out.live) {
        // Opened and queried fine, but this conversation has no usable rows yet
        // (e.g. the turn has not produced a finished step). That is not a failure.
        out.state = .empty;
    }
    return out;
}
pub const Config = struct { root: []const u8, data: []const u8, quota: []const u8, settings: []const u8 };
const StopScope = struct {
    /// The Stop still describes the live row on screen, so suppress it.
    covers_live: bool = true,
    /// The Stop still describes the current round, so it may paint a chip.
    current: bool = true,
};
const LiveSlot = struct {
    id: [36]u8 = @splat(0),
    step: ?i64 = null,
    samples: [5]struct { at: f64, chars: i64 } = undefined,
    sample_count: usize = 0,
    growth_at: f64 = 0,
    growth_chars: ?i64 = null,
    growth_seen: bool = false,
    /// Timestamp of the Stop hook last accounted for, the step index that was
    /// live when it arrived, and the streamed length at that moment. A newer
    /// index — or text that grew afterwards — is a new stream, not leftover.
    stop_at: ?f64 = null,
    stop_step: ?i64 = null,
    stop_chars: ?i64 = null,
    /// The active row the baseline belongs to. A different active row cannot be
    /// the one the Stop ended, so it is a new stream even if it is shorter.
    stop_row: ?i64 = null,
    last_used: f64 = 0,
};

const DbCacheSlot = struct {
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.c_allocator),
    id: [36]u8 = @splat(0),
    db_sig: c.Sig = .{},
    wal_sig: c.Sig = .{},
    db: ?DbResult = null,
    summary_only: bool = false,
    last_used: u64 = 0,
};

const TranscriptCacheSlot = struct {
    transcript: Transcript = Transcript.init(),
    last_used: u64 = 0,
};

// One primary conversation plus the notch's eight additional probes.
const cached_conversations = 9;

pub const Runtime = struct {
    // Brief queries omit transcript statistics and bound database history reads.
    summary_only: bool = false,
    include_shared: bool = true,
    transcripts: [cached_conversations]TranscriptCacheSlot = [_]TranscriptCacheSlot{.{}} ** cached_conversations,
    transcript_clock: u64 = 0,
    // Bounded multi-slot LRU DB cache so probing multiple conversations per poll
    // does not evict unchanged inactive/completed conversations.
    db_cache: [cached_conversations]DbCacheSlot = [_]DbCacheSlot{.{}} ** cached_conversations,
    db_clock: u64 = 0,
    // Cached top candidate conversations from directory scan, refreshed on dir
    // mtime change or low-frequency fallback interval.
    recent_cache: [24]Recent = undefined,
    recent_cache_count: usize = 0,
    recent_dir_sig: c.Sig = .{},
    recent_scan_at: f64 = 0,
    recent_cache_valid: bool = false,
    live_slots: [cached_conversations]LiveSlot = [_]LiveSlot{.{}} ** cached_conversations,
    settings: settings_mod.Settings = .{},
    settings_sig: c.Sig = .{},
    settings_loaded: bool = false,
    pub fn deinit(self: *Runtime) void {
        for (&self.transcripts) |*slot| {
            slot.transcript.deinit();
        }
        for (&self.db_cache) |*slot| {
            slot.arena.deinit();
        }
    }
    fn transcriptFor(self: *Runtime, path: []const u8) *Transcript {
        self.transcript_clock +%= 1;
        var free_idx: ?usize = null;
        var oldest_idx: usize = 0;
        for (&self.transcripts, 0..) |*slot, idx| {
            if (c.eq(slot.transcript.path, path)) {
                slot.last_used = self.transcript_clock;
                return &slot.transcript;
            }
            if (slot.transcript.path.len == 0 and free_idx == null) free_idx = idx;
            if (slot.last_used < self.transcripts[oldest_idx].last_used) oldest_idx = idx;
        }
        const slot = &self.transcripts[free_idx orelse oldest_idx];
        slot.last_used = self.transcript_clock;
        // update() resets the parser when a slot is reused for a different path.
        return &slot.transcript;
    }
    /// Hot reload: the config is re-read only when the file signature moves, so
    /// a 1 Hz poll costs one stat, not a parse. Saving the file takes effect on
    /// the next poll.
    pub fn settingsFor(self: *Runtime, path: []const u8, a: A) settings_mod.Settings {
        const sig = c.sig(path);
        if (self.settings_loaded and std.meta.eql(sig, self.settings_sig)) return self.settings;
        self.settings_loaded = true;
        self.settings_sig = sig;
        self.settings = if (sig.exists) settings_mod.fromJson(c.readJson(a, path)) else .{};
        return self.settings;
    }
    fn findLiveSlot(self: *const Runtime, id: []const u8) ?*const LiveSlot {
        for (&self.live_slots) |*slot| {
            if (slot.id[0] != 0 and c.eq(&slot.id, id)) return slot;
        }
        return null;
    }
    fn getOrAllocLiveSlot(self: *Runtime, id: []const u8, now: f64) *LiveSlot {
        var free_idx: ?usize = null;
        var oldest_idx: usize = 0;
        for (&self.live_slots, 0..) |*slot, idx| {
            if (slot.id[0] != 0 and c.eq(&slot.id, id)) {
                slot.last_used = now;
                return slot;
            }
            if (slot.id[0] == 0 and free_idx == null) free_idx = idx;
            if (slot.last_used < self.live_slots[oldest_idx].last_used) oldest_idx = idx;
        }
        const chosen = free_idx orelse oldest_idx;
        self.live_slots[chosen] = .{ .last_used = now };
        if (id.len == 36) @memcpy(&self.live_slots[chosen].id, id);
        return &self.live_slots[chosen];
    }
    fn charsIdleSec(self: *const Runtime, id: []const u8, now: f64) ?f64 {
        const slot = self.findLiveSlot(id) orelse return null;
        if (!slot.growth_seen) return null;
        return @max(0, now - slot.growth_at);
    }
    /// A Stop event only speaks for the round it ended. Remember the step that
    /// was live when it arrived; anything newer — a fresh step index, a live
    /// row above that step, or database writes well after the event — is a new
    /// round, even when no PreInvocation was delivered for it.
    fn stopScope(self: *Runtime, id: []const u8, db: *const DbResult, hook_at: ?f64, last_user: ?f64, now: f64) StopScope {
        const at = hook_at orelse return .{};
        const slot = self.getOrAllocLiveSlot(id, now);
        if (slot.stop_at == null or slot.stop_at.? != at) {
            slot.stop_at = at;
            slot.stop_step = slot.step;
            slot.stop_chars = if (db.live) db.chars else null;
            slot.stop_row = if (db.live) db.live_idx else null;
        }
        // The Stop can land while nothing is active; adopt the first row seen
        // afterwards as the baseline row.
        if (slot.stop_row == null and db.live) {
            slot.stop_row = db.live_idx;
            slot.stop_chars = db.chars;
        }
        // Only the *active* row decides whether a new round started. A finished
        // step above it ended before the Stop and must not be mistaken for new
        // activity (that is what resurrected the stream).
        const newer_live = if (!db.live) false else if (slot.stop_step) |stopped|
            // Same process watched this step before the Stop: a higher index is
            // a new round. The stopped step itself has ended, even if a late
            // write lands afterwards.
            (db.live_idx orelse stopped) > stopped
        else blk: {
            // Cold start: no step history, but the baseline remembers which row
            // it belongs to. A different active row is a new stream even when it
            // is shorter than the stopped one — that is exactly what the index
            // comparison does on the warm path.
            if (slot.stop_row) |row| {
                if (db.live_idx) |idx| {
                    if (idx != row) break :blk true;
                }
            }
            if (last_user) |user_at| {
                // Same row: the transcript knows when the user last wrote
                // something. A Stop with no later USER_INPUT means no new round,
                // so an active row is leftover — this also covers the final
                // flush AGY writes a few seconds after the Stop.
                break :blk user_at > at;
            }
            // No usable log evidence: only text that grew after we first looked
            // at the row proves a new stream. A leftover never grows by itself.
            break :blk slot.stop_chars != null and (db.chars orelse 0) > slot.stop_chars.?;
        };
        return .{ .covers_live = !newer_live, .current = !newer_live };
    }
    fn database(self: *Runtime, id: []const u8, path: []const u8, a: A) !DbResult {
        const sig = c.sig(path);
        const wal = c.sig(try c.fmt(a, "{s}-wal", .{path}));
        self.db_clock +%= 1;

        var match_idx: ?usize = null;
        var free_idx: ?usize = null;
        var oldest_idx: usize = 0;
        for (&self.db_cache, 0..) |*slot, idx| {
            if (slot.id[0] != 0 and c.eq(&slot.id, id)) {
                match_idx = idx;
                // Never serve an active live step from cache: streaming state and
                // completion transitions must re-read SQLite on every poll. A
                // transient failure is not cached either, or one locked moment
                // would stick until the file changed again.
                if (slot.db != null and slot.summary_only == self.summary_only and std.meta.eql(sig, slot.db_sig) and std.meta.eql(wal, slot.wal_sig) and slot.db.?.readable and !slot.db.?.live and (slot.db.?.state == .ok or slot.db.?.state == .empty)) {
                    slot.last_used = self.db_clock;
                    return slot.db.?;
                }
                break;
            }
            if (slot.id[0] == 0 and free_idx == null) free_idx = idx;
            if (slot.last_used < self.db_cache[oldest_idx].last_used) oldest_idx = idx;
        }

        const chosen = match_idx orelse free_idx orelse oldest_idx;
        const slot = &self.db_cache[chosen];
        _ = slot.arena.reset(.free_all);
        slot.db = null;
        slot.id = @splat(0);
        var result = try readDb(slot.arena.allocator(), path, self.summary_only);
        const max_mtime_ns = @max(if (sig.exists) sig.mtime else 0, if (wal.exists) wal.mtime else 0);
        result.latest_mtime_sec = if (max_mtime_ns > 0) @as(f64, @floatFromInt(max_mtime_ns)) / 1e9 else null;
        if (id.len == 36) @memcpy(&slot.id, id);
        slot.db_sig = sig;
        slot.wal_sig = wal;
        slot.db = result;
        slot.summary_only = self.summary_only;
        slot.last_used = self.db_clock;
        return result;
    }
    fn rate(self: *Runtime, id: []const u8, db: DbResult, now: f64) ?f64 {
        if (!db.live and self.findLiveSlot(id) == null) return null;
        const slot = self.getOrAllocLiveSlot(id, now);
        if (!db.live or db.chars == null or db.live_idx == null) {
            slot.sample_count = 0;
            slot.growth_seen = false;
            slot.growth_chars = null;
            return null;
        }
        const step_changed = slot.step != db.live_idx;
        if (step_changed or (slot.sample_count > 0 and slot.samples[slot.sample_count - 1].chars > db.chars.?)) slot.sample_count = 0;
        slot.step = db.live_idx;
        // Track the last time the streamed text actually grew. A live row that
        // stops growing is the difference between "slow" and "stuck".
        if (step_changed or !slot.growth_seen or slot.growth_chars == null or db.chars.? > slot.growth_chars.?) {
            slot.growth_at = now;
            slot.growth_chars = db.chars.?;
            slot.growth_seen = true;
        }
        if (slot.sample_count == 5) {
            std.mem.copyForwards(@TypeOf(slot.samples[0]), slot.samples[0..4], slot.samples[1..]);
            slot.sample_count -= 1;
        }
        slot.samples[slot.sample_count] = .{ .at = now, .chars = db.chars.? };
        slot.sample_count += 1;
        while (slot.sample_count > 2 and now - slot.samples[0].at > 4) {
            std.mem.copyForwards(@TypeOf(slot.samples[0]), slot.samples[0 .. slot.sample_count - 1], slot.samples[1..slot.sample_count]);
            slot.sample_count -= 1;
        }
        if (slot.sample_count < 2) return null;
        const elapsed = now - slot.samples[0].at;
        return if (elapsed > 0.05) @as(f64, @floatFromInt(db.chars.? - slot.samples[0].chars)) / elapsed else null;
    }
};
fn timeValue(a: A, ts: ?f64) !V {
    const value = ts orelse return .null;
    if (!std.math.isFinite(value) or value < 0 or value > 253402300799) return .null;
    const us: i64 = @intFromFloat(@round(value * 1e6));
    const whole = @divFloor(us, 1000000);
    const fraction = @mod(us, 1000000);
    const base = c.iso(a, whole) catch return .null;
    return if (fraction == 0) c.s(base) else c.s(try c.fmt(a, "{s}.{d:0>6}+00:00", .{ base[0 .. base.len - 6], @as(u32, @intCast(fraction)) }));
}
fn span(end: ?f64, start: ?f64) ?f64 {
    if (end == null or start == null) return null;
    return @max(0, end.? - start.?);
}
const Recent = struct { id: [36]u8, at: i128 };
fn peerRoot(a: A, root: []const u8) !?[]const u8 {
    const base = std.fs.path.basename(root);
    const parent = std.fs.path.dirname(root) orelse return null;
    if (c.eq(base, "antigravity")) return try c.join(a, &.{ parent, "antigravity-cli" });
    if (c.eq(base, "antigravity-cli")) return try c.join(a, &.{ parent, "antigravity" });
    return null;
}
const PeerDataInfo = struct {
    primary_kind: []const u8,
    peer_path: []const u8,
    peer_kind: []const u8,
};
fn peerDataInfo(a: A, data: []const u8) !?PeerDataInfo {
    if (!c.eq(std.fs.path.basename(data), "agy-desktop-status")) return null;
    const plugin_data = std.fs.path.dirname(data) orelse return null;
    if (!c.eq(std.fs.path.basename(plugin_data), "plugin_data")) return null;
    const root_dir = std.fs.path.dirname(plugin_data) orelse return null;
    const parent = std.fs.path.dirname(root_dir) orelse return null;
    const base = std.fs.path.basename(root_dir);
    if (c.eq(base, "antigravity")) {
        return .{
            .primary_kind = "desktop",
            .peer_path = try c.join(a, &.{ parent, "antigravity-cli", "plugin_data", "agy-desktop-status" }),
            .peer_kind = "cli",
        };
    }
    if (c.eq(base, "antigravity-cli")) {
        return .{
            .primary_kind = "cli",
            .peer_path = try c.join(a, &.{ parent, "antigravity", "plugin_data", "agy-desktop-status" }),
            .peer_kind = "desktop",
        };
    }
    return null;
}
fn sessionClientKind(meta: V, fallback: []const u8) []const u8 {
    const own = c.str(c.get(meta, "clientKind"));
    if (own.len > 0) return own;
    return fallback;
}
fn withDefaultClientKind(a: A, entry: V, default_kind: []const u8) !V {
    if (entry != .object) return entry;
    if (c.str(c.get(entry, "clientKind")).len > 0 or default_kind.len == 0) return entry;
    var copy = c.object(a);
    for (entry.object.keys(), entry.object.values()) |k, v| {
        try c.put(a, &copy, k, v);
    }
    try c.put(a, &copy, "clientKind", c.s(default_kind));
    return copy;
}
fn loadMergedHooks(a: A, cfg: Config) !V {
    const primary = c.readJson(a, try c.join(a, &.{ cfg.data, "active_session.json" }));
    const info = (try peerDataInfo(a, cfg.data)) orelse return primary;
    const peer = c.readJson(a, try c.join(a, &.{ info.peer_path, "active_session.json" }));
    if (peer != .object) return primary;

    var sessions = c.object(a);
    const primary_sessions = c.get(primary, "sessions");
    if (primary_sessions == .object) {
        const primary_default = if (c.str(c.get(primary, "clientKind")).len > 0) c.str(c.get(primary, "clientKind")) else info.primary_kind;
        for (primary_sessions.object.keys(), primary_sessions.object.values()) |sid, val| {
            try c.put(a, &sessions, sid, try withDefaultClientKind(a, val, primary_default));
        }
    }
    const peer_sessions = c.get(peer, "sessions");
    if (peer_sessions == .object) {
        const peer_default = if (c.str(c.get(peer, "clientKind")).len > 0) c.str(c.get(peer, "clientKind")) else info.peer_kind;
        for (peer_sessions.object.keys(), peer_sessions.object.values()) |sid, val| {
            const existing = c.get(sessions, sid);
            const peer_at = c.str(c.get(val, "updatedAt"));
            const existing_at = c.str(c.get(existing, "updatedAt"));
            if (existing != .object or std.mem.order(u8, peer_at, existing_at) == .gt) {
                try c.put(a, &sessions, sid, try withDefaultClientKind(a, val, peer_default));
            }
        }
    }

    const primary_active = c.str(c.get(primary, "activeConversationId"));
    const peer_active = c.str(c.get(peer, "activeConversationId"));
    const primary_updated = c.str(c.get(primary, "updatedAt"));
    const peer_updated = c.str(c.get(peer, "updatedAt"));
    const primary_ts = c.timestamp(primary_updated) orelse -1;
    const peer_ts = c.timestamp(peer_updated) orelse -1;
    const use_peer = c.validId(peer_active) and (!c.validId(primary_active) or peer_ts > primary_ts);

    var merged = c.object(a);
    try c.put(a, &merged, "activeConversationId", c.s(if (use_peer) peer_active else primary_active));
    try c.put(a, &merged, "updatedAt", c.s(if (use_peer) peer_updated else primary_updated));
    try c.put(a, &merged, "sessions", sessions);
    const chosen_kind = if (use_peer)
        (if (c.str(c.get(peer, "clientKind")).len > 0) c.str(c.get(peer, "clientKind")) else info.peer_kind)
    else
        (if (c.str(c.get(primary, "clientKind")).len > 0) c.str(c.get(primary, "clientKind")) else info.primary_kind);
    try c.put(a, &merged, "clientKind", c.s(chosen_kind));
    return merged;
}
fn transcriptPath(a: A, root: []const u8, peer_root: ?[]const u8, meta: V, id: []const u8) ![]const u8 {
    const path = c.str(c.get(meta, "transcriptPath"));
    if (path.len > 0 and c.sig(path).exists) return path;
    const primary = try c.join(a, &.{ root, "brain", id, ".system_generated", "logs", "transcript.jsonl" });
    if (c.sig(primary).exists) return primary;
    if (peer_root) |pr| {
        const peer = try c.join(a, &.{ pr, "brain", id, ".system_generated", "logs", "transcript.jsonl" });
        if (c.sig(peer).exists) return peer;
    }
    return primary;
}
fn sortRecent(items: []Recent) void {
    std.mem.sort(Recent, items, {}, struct {
        fn less(_: void, x: Recent, y: Recent) bool {
            return x.at > y.at;
        }
    }.less);
}
fn statDbAt(dir: std.fs.Dir, id: []const u8) ?i128 {
    var db_name: [48]u8 = undefined;
    const db_file = std.fmt.bufPrint(&db_name, "{s}.db", .{id}) catch return null;
    const st = dir.statFile(db_file) catch return null;
    var wal_name: [64]u8 = undefined;
    const wal = dir.statFile(std.fmt.bufPrint(&wal_name, "{s}.db-wal", .{id}) catch "") catch null;
    return @max(st.mtime, if (wal) |w| w.mtime else 0);
}
fn recent(a: A, runtime: *Runtime, root: []const u8, peer_root: ?[]const u8, hooks: V, now: f64) !V {
    const primary_conv = try c.join(a, &.{ root, "conversations" });
    const dirpath = blk: {
        if (c.sig(primary_conv).exists) break :blk primary_conv;
        if (peer_root) |pr| {
            const peer_conv = try c.join(a, &.{ pr, "conversations" });
            if (c.sig(peer_conv).exists) break :blk peer_conv;
        }
        break :blk primary_conv;
    };
    const dir_sig = c.sig(dirpath);
    const need_full_scan = !runtime.recent_cache_valid or !std.meta.eql(dir_sig, runtime.recent_dir_sig) or (now - runtime.recent_scan_at) >= 10.0 or now < runtime.recent_scan_at;

    if (need_full_scan) {
        var scanned: [25]Recent = undefined;
        var scanned_count: usize = 0;
        if (std.fs.cwd().openDir(dirpath, .{ .iterate = true })) |d| {
            var dir = d;
            defer dir.close();
            var it = dir.iterate();
            while (try it.next()) |entry| {
                if (entry.name.len != 39 or !std.mem.endsWith(u8, entry.name, ".db") or !c.validId(entry.name[0..36])) continue;
                const st = dir.statFile(entry.name) catch continue;
                var wal_name: [128]u8 = undefined;
                const wal = dir.statFile(try std.fmt.bufPrint(&wal_name, "{s}-wal", .{entry.name})) catch null;
                const at = @max(st.mtime, if (wal) |w| w.mtime else 0);
                if (scanned_count == 24 and at <= scanned[scanned_count - 1].at) continue;
                var item: Recent = .{ .id = undefined, .at = at };
                @memcpy(&item.id, entry.name[0..36]);
                scanned[scanned_count] = item;
                scanned_count += 1;
                sortRecent(scanned[0..scanned_count]);
                scanned_count = @min(scanned_count, 24);
            }
        } else |_| {}
        @memcpy(runtime.recent_cache[0..scanned_count], scanned[0..scanned_count]);
        runtime.recent_cache_count = scanned_count;
        runtime.recent_dir_sig = dir_sig;
        runtime.recent_scan_at = now;
        runtime.recent_cache_valid = true;
    } else if (dir_sig.exists) {
        if (std.fs.cwd().openDir(dirpath, .{})) |d| {
            var dir = d;
            defer dir.close();
            var kept: usize = 0;
            for (runtime.recent_cache[0..runtime.recent_cache_count]) |item| {
                if (statDbAt(dir, &item.id)) |at| {
                    runtime.recent_cache[kept] = .{ .id = item.id, .at = at };
                    kept += 1;
                }
            }
            runtime.recent_cache_count = kept;
            sortRecent(runtime.recent_cache[0..kept]);
            // Also refresh mtime for any active/hook-tracked sessions that might not be in the top-24 cache yet.
            const sessions_obj_refresh = c.get(hooks, "sessions");
            if (sessions_obj_refresh == .object) {
                for (sessions_obj_refresh.object.keys()) |sid| {
                    if (!c.validId(sid)) continue;
                    var in_cache = false;
                    for (runtime.recent_cache[0..runtime.recent_cache_count]) |item| {
                        if (c.eq(&item.id, sid)) {
                            in_cache = true;
                            break;
                        }
                    }
                    if (in_cache) continue;
                    if (statDbAt(dir, sid)) |at| {
                        if (runtime.recent_cache_count < 24) {
                            var item: Recent = .{ .id = undefined, .at = at };
                            @memcpy(&item.id, sid[0..36]);
                            runtime.recent_cache[runtime.recent_cache_count] = item;
                            runtime.recent_cache_count += 1;
                        } else if (at > runtime.recent_cache[23].at) {
                            @memcpy(&runtime.recent_cache[23].id, sid[0..36]);
                            runtime.recent_cache[23].at = at;
                        }
                        sortRecent(runtime.recent_cache[0..runtime.recent_cache_count]);
                    }
                }
            }
            sortRecent(runtime.recent_cache[0..runtime.recent_cache_count]);
        } else |_| {}
    }

    var items: [16]Recent = undefined;
    var count: usize = @min(runtime.recent_cache_count, 15);
    @memcpy(items[0..count], runtime.recent_cache[0..count]);
    const sessions_obj = c.get(hooks, "sessions");
    if (sessions_obj == .object) {
        for (sessions_obj.object.keys(), sessions_obj.object.values()) |sid, val| {
            if (!c.validId(sid)) continue;
            var exists = false;
            for (items[0..count]) |item| {
                if (c.eq(&item.id, sid)) {
                    exists = true;
                    break;
                }
            }
            if (exists) continue;
            const ts = c.timestamp(c.str(c.get(val, "updatedAt"))) orelse continue;
            if (ts < 0 or ts > 253402300799) continue;
            const at: i128 = @intFromFloat(ts * 1e9);
            if (count == 15 and at <= items[count - 1].at) continue;
            var item: Recent = .{ .id = undefined, .at = at };
            @memcpy(&item.id, sid[0..36]);
            items[count] = item;
            count += 1;
            sortRecent(items[0..count]);
            count = @min(count, 15);
        }
    }
    const active = c.str(c.get(hooks, "activeConversationId"));
    var found = false;
    for (items[0..count]) |item| {
        if (c.eq(&item.id, active)) found = true;
    }
    if (!found and c.validId(active)) {
        std.mem.copyBackwards(Recent, items[1..@min(count + 1, 15)], items[0..@min(count, 14)]);
        @memcpy(&items[0].id, active);
        items[0].at = 0;
        count = @min(count + 1, 15);
    }
    var out = c.arr(a);
    for (items[0..count]) |item| {
        const id = try a.dupe(u8, &item.id);
        const meta = c.get(c.get(hooks, "sessions"), id);
        var row = c.object(a);
        try c.put(a, &row, "conversationId", c.s(id));
        try c.put(a, &row, "shortId", c.s(id[0..8]));
        try c.put(a, &row, "modelName", c.s(c.str(c.get(meta, "modelName"))));
        try c.put(a, &row, "workspace", c.s(std.fs.path.basename(c.str(c.get(meta, "cwd")))));
        try c.put(a, &row, "updatedAt", if (item.at == 0) c.get(hooks, "updatedAt") else try timeValue(a, @as(f64, @floatFromInt(item.at)) / 1e9));
        try c.put(a, &row, "isActive", c.b(c.eq(id, active)));
        try c.put(a, &row, "transcriptPath", c.s(try transcriptPath(a, root, peer_root, meta, id)));
        try c.put(a, &row, "lastEvent", c.s(c.str(c.get(meta, "lastEvent"))));
        try c.put(a, &row, "terminalEnv", c.get(meta, "terminalEnv"));
        try c.put(a, &row, "clientKind", c.s(sessionClientKind(meta, "")));
        try c.add(&out, row);
    }
    return out;
}
fn contains(raw: []const u8, key: []const u8) bool {
    return std.mem.indexOf(u8, raw, key) != null;
}
pub fn quota(a: A, path: []const u8, now: i64) !V {
    const raw = c.readJson(a, path);
    const buckets = c.get(raw, "buckets");
    const observed_raw = c.num(c.get(raw, "observed_at")) orelse return .null;
    if (buckets != .array or observed_raw < 0 or observed_raw > 253402300799) return .null;
    const observed: i64 = @intFromFloat(observed_raw);
    const Bucket = struct { frac: f64, key: []const u8, reset: ?i64 };
    var slots: [3][3]?Bucket = @splat(@splat(null));
    for (buckets.array.items) |item| {
        const key = c.str(c.get(item, "key"));
        const low = try std.ascii.allocLowerString(a, key);
        const pool: usize = if (contains(low, "argon")) 1 else if (contains(low, "gemini") or contains(low, "hydrogen") or contains(low, "flash")) 0 else if (contains(low, "3p") or contains(low, "claude") or contains(low, "gpt") or contains(low, "anthropic")) 2 else continue;
        const window: usize = if (contains(low, "5h")) 0 else if (contains(low, "weekly")) 1 else 2;
        const frac = std.math.clamp(c.num(c.get(item, "remaining_fraction")) orelse continue, 0, 1);
        if (slots[pool][window]) |old| {
            if (frac >= old.frac - 1e-9) continue;
        }
        const reset_raw = c.num(c.get(item, "reset_at"));
        slots[pool][window] = .{ .frac = frac, .key = key, .reset = if (reset_raw != null and reset_raw.? >= 0 and reset_raw.? <= 253402300799) @intFromFloat(reset_raw.?) else null };
    }
    var rows = c.arr(a);
    const pools = [_][]const u8{ "gemini", "argon", "claude" };
    const windows = [_][]const u8{ "5h", "weekly", "other" };
    for (slots, 0..) |group, p| {
        for (group, 0..) |slot, w| {
            if (slot) |item| {
                var reset = item.reset;
                var rolled: i64 = 0;
                if (reset != null and w < 2 and reset.? <= now) {
                    const period: i64 = if (w == 0) 18000 else 604800;
                    rolled = @min(10000, @divFloor(now - reset.?, period) + 1);
                    reset.? += rolled * period;
                }
                var row = c.object(a);
                try c.put(a, &row, "pool", c.s(pools[p]));
                try c.put(a, &row, "window", c.s(windows[w]));
                try c.put(a, &row, "bucket", c.s(item.key));
                try c.put(a, &row, "remainingPct", c.rounded(item.frac * 100, 10));
                try c.put(a, &row, "resetAt", try c.isoValue(a, reset));
                try c.put(a, &row, "resetAtEpoch", c.opt(reset));
                try c.put(a, &row, "resetInSec", if (reset) |x| c.n(x - now) else .null);
                try c.put(a, &row, "approx", c.b(rolled > 0));
                try c.add(&rows, row);
            }
        }
    }
    if (rows.array.items.len == 0) return .null;
    var out = c.object(a);
    const age = @max(0, now - observed);
    const source = c.str(c.get(raw, "source"));
    try c.put(a, &out, "source", c.s(if (source.len == 0) "agy-statusline" else source));
    try c.put(a, &out, "observedAt", try c.isoValue(a, observed));
    try c.put(a, &out, "observedAgeSec", c.n(age));
    try c.put(a, &out, "stale", c.b(age > 21600));
    try c.put(a, &out, "windows", rows);
    return out;
}
fn dbStateName(state: DbState) []const u8 {
    return switch (state) {
        .ok => "ok",
        .empty => "empty",
        .missing => "missing",
        .locked => "locked",
        .unreadable => "unreadable",
        .corrupt => "corrupt",
    };
}
fn transcriptStateName(state: TranscriptState) []const u8 {
    return switch (state) {
        .ok => "ok",
        .missing => "missing",
        .failed => "error",
    };
}
fn quotaStateName(state: QuotaState) []const u8 {
    return switch (state) {
        .ok => "ok",
        .stale => "stale",
        .missing => "missing",
        .unreadable => "unreadable",
        .disabled => "disabled",
    };
}
fn note(a: A, list: *V, code: []const u8, label: []const u8, text: []const u8) !void {
    var item = c.object(a);
    try c.put(a, &item, "code", c.s(code));
    try c.put(a, &item, "label", c.s(label));
    try c.put(a, &item, "text", c.s(text));
    try c.add(list, item);
}
/// Which evidence the numbers on screen actually came from, and — when a source
/// is unavailable — a stable code plus a sentence. "No data" and "could not
/// read" must never look the same in the panel.
fn sourcesValue(a: A, db: DbResult, transcript_state: TranscriptState, hook_connected: bool, quota_state: QuotaState) !V {
    var out = c.object(a);
    try c.put(a, &out, "db", c.s(dbStateName(db.state)));
    try c.put(a, &out, "transcript", c.s(transcriptStateName(transcript_state)));
    try c.put(a, &out, "hooks", c.s(if (hook_connected) "ok" else "missing"));
    try c.put(a, &out, "quota", c.s(quotaStateName(quota_state)));
    var notes = c.arr(a);
    // Only report what actually explains a missing number. A brand-new
    // conversation with no rows yet is normal and stays silent.
    switch (db.state) {
        .locked => try note(a, &notes, "db_locked", "数据库被占用", "会话数据库正被其他进程占用（例如同时开着另一个窗口），本轮数值暂未刷新；面板会自动重试。"),
        .unreadable => try note(a, &notes, "db_unreadable", "数据库异常", "会话数据库无法以只读方式打开，可能是文件异常或被独占；本轮数值暂未刷新。"),
        .corrupt => try note(a, &notes, "db_corrupt", "数据库记录损坏", "会话数据库里的生成记录无法解析（可能写入中断或版本不一致），本轮数值暂未刷新；面板会自动重试。"),
        .missing => if (transcript_state == .ok and db.count == 0) try note(a, &notes, "db_missing", "数据库缺失", "对话日志存在，但对应的会话数据库不存在或尚未就绪，部分数值可能缺失。"),
        else => {},
    }
    if (transcript_state == .failed) try note(a, &notes, "transcript_error", "日志读取失败", "对话日志读取失败（可能单行过大或文件损坏），会话累计值可能不完整。");
    if (quota_state == .unreadable) try note(a, &notes, "quota_unreadable", "额度文件损坏", "额度快照文件（quota.json）无法解析，额度重置时间暂不可用。");
    try c.put(a, &out, "degraded", c.b(notes.array.items.len > 0));
    try c.put(a, &out, "notes", notes);
    return out;
}

pub fn snapshot(a: A, runtime: *Runtime, cfg: Config, requested: []const u8) !V {
    const now: f64 = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000;
    const settings = runtime.settingsFor(cfg.settings, a);
    if (!settings.enabled) {
        var off = c.object(a);
        try c.put(a, &off, "config", try settings_mod.toValue(a, settings));
        try c.put(a, &off, "found", c.b(false));
        try c.put(a, &off, "disabled", c.b(true));
        try c.put(a, &off, "conversationId", c.s(""));
        try c.put(a, &off, "message", c.s("面板已在 config.json 中被关闭（enabled: false），改回 true 后自动恢复。"));
        try c.put(a, &off, "generatedAt", try timeValue(a, now));
        return off;
    }
    const hooks = try loadMergedHooks(a, cfg);
    const peer_root = try peerRoot(a, cfg.root);
    const active = c.str(c.get(hooks, "activeConversationId"));
    var id = std.mem.trim(u8, requested, " \t\r\n");
    const include_shared = !runtime.summary_only or runtime.include_shared or id.len == 0 or c.eq(id, "auto");
    const conversations = if (include_shared) try recent(a, runtime, cfg.root, peer_root, hooks, now) else c.arr(a);
    if (id.len == 0 or c.eq(id, "auto")) id = active;
    if (id.len == 0 and conversations.array.items.len > 0) id = c.str(c.get(conversations.array.items[0], "conversationId"));
    var out = c.object(a);
    if (include_shared) try c.put(a, &out, "config", try settings_mod.toValue(a, settings));
    try c.put(a, &out, "found", c.b(false));
    try c.put(a, &out, "conversationId", c.s(if (c.validId(id)) id else ""));
    if (include_shared) try c.put(a, &out, "recentConversations", conversations);
    try c.put(a, &out, "hookConnected", c.b(active.len > 0));
    var quota_state: QuotaState = .disabled;
    var quota_value: V = .null;
    if (include_shared and settings.quota) {
        quota_value = try quota(a, cfg.quota, @intFromFloat(now));
        quota_state = if (quota_value != .object)
            (if (c.sig(cfg.quota).exists) .unreadable else .missing)
        else if (c.get(quota_value, "stale") == .bool and c.get(quota_value, "stale").bool)
            .stale
        else
            .ok;
    }
    if (include_shared) try c.put(a, &out, "quota", quota_value);
    try c.put(a, &out, "generatedAt", try timeValue(a, now));
    var live = c.object(a);
    try c.put(a, &live, "active", c.b(false));
    try c.put(a, &out, "live", live);
    if (!c.validId(id)) {
        try c.put(a, &out, "message", c.s("No local Antigravity Desktop conversation found yet."));
        if (quota_state == .unreadable) {
            try c.put(a, &out, "sources", try sourcesValue(a, DbResult.init(a), .missing, active.len > 0, quota_state));
        }
        return out;
    }
    const meta = c.get(c.get(hooks, "sessions"), id);
    try c.put(a, &out, "terminalEnv", c.get(meta, "terminalEnv"));
    try c.put(a, &out, "clientKind", c.s(sessionClientKind(meta, c.str(c.get(hooks, "clientKind")))));
    const dbpath = blk: {
        const primary_db = try c.join(a, &.{ cfg.root, "conversations", try c.fmt(a, "{s}.db", .{id}) });
        if (c.sig(primary_db).exists) break :blk primary_db;
        if (peer_root) |pr| {
            const peer_db = try c.join(a, &.{ pr, "conversations", try c.fmt(a, "{s}.db", .{id}) });
            if (c.sig(peer_db).exists) break :blk peer_db;
        }
        break :blk primary_db;
    };
    const db = try runtime.database(id, dbpath, a);
    const transcript_path = try transcriptPath(a, cfg.root, peer_root, meta, id);
    try c.put(a, &out, "transcriptPath", c.s(transcript_path));
    var transcript_state: TranscriptState = .ok;
    const tracker = runtime.transcriptFor(transcript_path);
    const has_log = blk: {
        // In brief mode (used by the notch bar), skip full transcript parsing
        // when the Desktop DB is readable; fall back to the transcript for
        // CLI sessions that do not write a Desktop .db file.
        if (runtime.summary_only and db.readable) break :blk false;
        if (tracker.update(transcript_path)) |_| {
            break :blk true;
        } else |err| {
            transcript_state = if (err == error.FileNotFound) .missing else .failed;
            break :blk false;
        }
    };
    if (has_log and tracker.corrupt_lines > 0) transcript_state = .failed;
    var model: []const u8 = if (db.latest) |r| r.model else "";
    if (model.len == 0) model = c.str(c.get(meta, "modelName"));
    if (model.len == 0 and has_log) model = tracker.latest_model;
    var input: ?i64 = null;
    var cached: ?i64 = null;
    var written: ?i64 = null;
    var output: ?i64 = if (db.latest) |r| r.output else null;
    var source: []const u8 = "none";
    if (db.usage) |steps_usage| {
        if (steps_usage[0] != null or steps_usage[1] != null or steps_usage[3] != null) {
            var u = steps_usage;
            // One request can be split across sources: SQLite knows the input
            // but not the cache reads, the log knows both. Complete the missing
            // fields from the *same* step index; never borrow another request's
            // numbers, and keep "unknown" (null) distinct from a real zero.
            if (has_log) {
                if (db.usage_idx) |idx| {
                    if (tracker.usageForStep(idx)) |logged| {
                        for (0..3) |k| {
                            if (u[k] == null) u[k] = logged[k];
                        }
                    }
                }
            }
            input = u[0];
            cached = u[1];
            written = u[3];
            source = "steps";
        }
    }
    if (c.eq(source, "none")) {
        if (db.latest) |r| {
            if (r.input != null or r.cached != null or r.written != null) {
                input = r.input;
                cached = r.cached;
                written = r.written;
                source = "gen_metadata";
            }
        }
    }
    if (c.eq(source, "none") and has_log) {
        if (tracker.latest) |vals| {
            if (vals[0] != null or vals[1] != null) {
                input = vals[0];
                cached = vals[1];
                source = "transcript";
            }
            if (!db.readable and output == null) output = vals[2];
        }
    }
    const total: ?i64 = if (input != null or cached != null or written != null) (input orelse 0) +| (cached orelse 0) +| (written orelse 0) else null;
    const context: ?i64 = if ((total orelse 0) > 0) total else null;
    const lower = try std.ascii.allocLowerString(a, model);
    const capacity: ?i64 = if (contains(lower, "gemini") or contains(lower, "hydrogen") or contains(lower, "argon") or contains(lower, "flash")) 1048576 else if (contains(lower, "claude") or contains(lower, "sonnet") or contains(lower, "opus") or contains(lower, "haiku")) (if (contains(lower, "1m")) @as(i64, 1000000) else @as(i64, 200000)) else null;
    const denom: f64 = @floatFromInt((input orelse 0) +| (cached orelse 0));
    const hit: ?f64 = if (input != null and cached != null and denom > 0 and ((written orelse 0) == 0 or cached.? > 0)) 100 * @as(f64, @floatFromInt(cached.?)) / denom else null;
    const target_model_key: []const u8 = if (model.len > 0) c.modelKey(model) else "";
    var steady_out: f64 = 0;
    var steady_sec: f64 = 0;
    var short_out: f64 = 0;
    var short_sec: f64 = 0;
    var speed_model: []const u8 = "";
    for (db.history[0..db.count]) |rec| {
        const rec_model_key: []const u8 = if (rec.model.len > 0) c.modelKey(rec.model) else "";
        if (!c.eq(rec_model_key, target_model_key)) continue;
        if (rec.speed != null and (rec.output orelse 0) > 0 and (rec.duration orelse 0) >= 0.1) {
            // Keep the model name next to the average: after a switch, the
            // samples are the *previous* model's, and the panel must say so
            // instead of calling them the current model's speed.
            if (rec.model.len > 0) speed_model = rec.model;
            if (rec.duration.? >= 0.3) {
                steady_out += @floatFromInt(rec.output.?);
                steady_sec += rec.duration.?;
            } else {
                short_out += @floatFromInt(rec.output.?);
                short_sec += rec.duration.?;
            }
        }
    }
    const speed: ?f64 = if (steady_sec >= 0.3 and steady_out > 0)
        steady_out / steady_sec
    else if (short_sec >= 0.1 and short_out > 0)
        short_out / short_sec
    else
        null;
    const dur = if (db.latest) |r| r.duration else null;
    const ttft = if (db.latest) |r| r.ttft else null;
    const latest_speed = if (db.latest) |r| r.speed else null;
    var workspace = c.str(c.get(meta, "cwd"));
    const paths = c.get(meta, "workspacePaths");
    if (paths == .array and paths.array.items.len > 0) workspace = c.str(paths.array.items[0]);
    // A database that failed to open or query is not evidence of anything;
    // "no active step" must not be inferred from it. Decode damage in the
    // generation table is reported as `corrupt`, but the step table still
    // answers the live question and any usage it holds is kept.
    const db_usable = db.readable and (db.state == .ok or db.state == .empty or db.state == .corrupt);
    const log_usable = has_log and transcript_state == .ok and tracker.generations > 0;
    try c.put(a, &out, "found", c.b(db_usable or has_log));
    if (!db_usable and !has_log) {
        try c.put(a, &out, "message", c.s("会话数据库暂时无法读取（或记录损坏），本轮数值暂未刷新；面板会自动重试。"));
    }
    try c.put(a, &out, "shortId", c.s(id[0..8]));
    try c.put(a, &out, "isActiveSession", c.b(c.eq(id, active)));
    try c.put(a, &out, "modelName", c.s(model));
    try c.put(a, &out, "workspaceName", c.s(std.fs.path.basename(workspace)));
    try c.put(a, &out, "lastGenSpeed", c.rounded(latest_speed, 10));
    try c.put(a, &out, "lastAvgSpeed", c.rounded(speed, 10));
    try c.put(a, &out, "lastAvgSpeedModel", c.s(if (speed != null) speed_model else ""));
    try c.put(a, &out, "turnModel", c.s(c.str(c.get(meta, "modelName"))));
    try c.put(a, &out, "lowSpeedWarning", c.b(if (latest_speed orelse speed) |x| x < settings.low_speed else false));
    try c.put(a, &out, "lastGenDurationSec", c.rounded(dur, 100));
    try c.put(a, &out, "lastGenTtftSec", c.rounded(ttft, 100));
    try c.put(a, &out, "turnDurationSec", c.rounded(if (has_log) span(tracker.last, tracker.user) else null, 100));
    try c.put(a, &out, "sessionDurationSec", c.rounded(if (has_log) span(tracker.last, tracker.first) else null, 100));
    try c.put(a, &out, "turnCount", if (has_log) c.n(tracker.turns) else .null);
    try c.put(a, &out, "stepCount", if (has_log) c.n(tracker.steps) else .null);
    try c.put(a, &out, "contextUsed", c.opt(context));
    try c.put(a, &out, "contextTotal", c.opt(capacity));
    try c.put(a, &out, "contextPct", c.rounded(if (context != null and capacity != null) @min(100, 100 * @as(f64, @floatFromInt(context.?)) / @as(f64, @floatFromInt(capacity.?))) else null, 10));
    try c.put(a, &out, "cacheHitPct", c.rounded(hit, 10));
    try c.put(a, &out, "cacheReadTokens", c.opt(cached));
    try c.put(a, &out, "cacheWriteTokens", c.opt(written));
    try c.put(a, &out, "inputTokens", c.opt(input));
    try c.put(a, &out, "outputTokens", c.opt(output));
    try c.put(a, &out, "usageSource", c.s(source));
    try c.put(a, &out, "sessionUsage", if (has_log) try tracker.usage.value(a) else .null);
    var latest: V = .null;
    if (has_log) {
        if (tracker.latest) |vals| {
            latest = c.object(a);
            try c.put(a, &latest, "inputTokens", c.opt(vals[0]));
            try c.put(a, &latest, "cacheReadTokens", c.opt(vals[1]));
            try c.put(a, &latest, "outputTokens", c.opt(vals[2]));
            try c.put(a, &latest, "totalTokens", if (vals[0] != null and vals[1] != null and vals[2] != null) c.n(vals[0].? +| vals[1].? +| vals[2].?) else .null);
            const inp = if (vals[0] != null and vals[1] != null) vals[0].? +| vals[1].? else 0;
            try c.put(a, &latest, "cacheHitPct", if (inp > 0) c.f(100 * @as(f64, @floatFromInt(vals[1].?)) / @as(f64, @floatFromInt(inp))) else .null);
        }
    }
    try c.put(a, &out, "latestUsage", latest);
    var models = c.arr(a);
    var points = c.arr(a);
    if (has_log and settings.models) {
        for (tracker.models.keys(), tracker.models.values()) |name, usage| {
            var row = try usage.value(a);
            const ms = db.speeds.get(name) orelse Speed{};
            try c.put(a, &row, "model", c.s(name));
            try c.put(a, &row, "avgSpeedTokS", c.rounded(if (ms.seconds > 0) ms.tokens / ms.seconds else null, 10));
            try c.put(a, &row, "speedSamples", c.n(ms.samples));
            try c.add(&models, row);
        }
    }
    if (has_log and settings.context) {
        for (tracker.points[0..tracker.point_count]) |point| {
            var row = c.object(a);
            try c.put(a, &row, "request", c.n(point.request));
            try c.put(a, &row, "stepIdx", c.opt(point.idx));
            try c.put(a, &row, "at", try timeValue(a, point.at));
            try c.put(a, &row, "model", c.s(point.model));
            try c.put(a, &row, "contextUsed", c.opt(point.context));
            try c.put(a, &row, "compaction", c.b(point.compact));
            try c.add(&points, row);
        }
    }
    try c.put(a, &out, "modelUsage", models);
    try c.put(a, &out, "contextHistory", points);
    try c.put(a, &out, "compactionCount", if (has_log) c.n(tracker.compactions) else .null);
    try c.put(a, &out, "lastActivityAt", if (has_log) try timeValue(a, tracker.last) else .null);
    var history = c.arr(a);
    if (settings.history) {
        for (db.history[0..db.count]) |rec| {
            var row = c.object(a);
            try c.put(a, &row, "idx", c.n(rec.idx));
            try c.put(a, &row, "speedTokS", c.rounded(rec.speed, 10));
            try c.put(a, &row, "outputTokens", c.opt(rec.output));
            try c.put(a, &row, "durationSec", c.rounded(rec.duration, 100));
            try c.put(a, &row, "ttftSec", c.rounded(rec.ttft, 100));
            try c.put(a, &row, "model", c.s(rec.model));
            try c.add(&history, row);
        }
    }
    try c.put(a, &out, "history", history);
    const hook_event = c.str(c.get(meta, "lastEvent"));
    const hook_at = c.timestamp(c.str(c.get(meta, "updatedAt")));
    const hook_age_sec: ?f64 = if (hook_at) |at| now - at else null;
    const stopped_recently = c.eq(hook_event, "Stop") and hook_age_sec != null and hook_age_sec.? >= -5 and hook_age_sec.? <= settings.limits.stop_ttl_sec;
    const is_stop = hook_at != null and c.eq(hook_event, "Stop");
    // What expires after `stop_ttl_sec` is the chip, not the verdict: if the
    // database and its active row did not change since the Stop, the row is
    // still finished and must not come back as a live stream.
    const last_user = if (has_log) tracker.user else null;
    const stop_scope = if (is_stop) runtime.stopScope(id, &db, hook_at, last_user, now) else StopScope{};
    const stop_suppressed = is_stop and stop_scope.covers_live;
    // Sample growth for every live row, including a stopped or behind row: both
    // the residue guard and the post-Stop growth escape need to know whether the
    // text moved, and not sampling here would deadlock that decision.
    var rate_db = db;
    rate_db.live = db.live and (db.chars orelse 0) > 0;
    const rate = runtime.rate(id, rate_db, now);
    const chars_idle_sec = runtime.charsIdleSec(id, now);
    // A leftover active row from an old round hides behind a finished step. It
    // stays live while its text grows, then drops out instead of being sold as
    // a new stream.
    const stale_behind = db.live and db.live_behind and (chars_idle_sec == null or chars_idle_sec.? >= settings.limits.stall_sec);
    const effective_db_live = db.live and !stop_suppressed and !stale_behind;
    const hook_model = c.str(c.get(meta, "modelName"));
    const evidence: session.Input = .{
        .now = now,
        .hook_event = hook_event,
        .hook_age_sec = hook_age_sec,
        .hook_connected = active.len > 0,
        .stop_current = !stopped_recently or stop_scope.current,
        .live = effective_db_live,
        .live_chars = db.chars,
        .live_status = db.status,
        .chars_idle_sec = chars_idle_sec,
        // The hook reports the model chosen for this turn; the last
        // completed generation reports the previous one. Comparing them is
        // what makes "switch → cache recompute" explainable.
        .model = if (hook_model.len > 0) hook_model else model,
        .prev_model = if (db.latest) |rec| rec.model else "",
        .termination = c.str(c.get(meta, "terminationReason")),
        .evidence_trusted = db_usable or log_usable,
    };
    const session_out = session.evaluate(evidence, settings.limits);
    const live_active = effective_db_live and (db.chars orelse 0) > 0 and (session_out.code == .streaming or session_out.code == .stalled);
    if (live_active) {
        try c.put(a, &live, "active", c.b(true));
        try c.put(a, &live, "stepIdx", c.opt(db.live_idx));
        try c.put(a, &live, "stepType", c.opt(db.live_type));
        try c.put(a, &live, "status", c.opt(db.status));
        try c.put(a, &live, "outputChars", c.opt(db.chars));
        try c.put(a, &live, "charsPerSec", c.rounded(rate, 10));
        try c.put(a, &live, "charsPerToken", c.rounded(db.cpt, 100));
        try c.put(a, &live, "estTokPerSec", c.rounded(if (rate) |r| r / db.cpt else null, 10));
        try c.put(a, &live, "elapsedSec", c.rounded(if (has_log) span(now, tracker.user) else null, 10));
        try c.put(a, &live, "observedAt", try timeValue(a, now));
    }
    try c.put(a, &out, "live", live);
    if (settings.session or runtime.summary_only) {
        try c.put(a, &out, "session", try session.toValue(a, evidence, session_out, settings.debug));
    }
    try c.put(a, &out, "sources", try sourcesValue(a, db, transcript_state, active.len > 0, quota_state));
    return out;
}

test "transcript cache retains nine parsers and evicts the least recently used" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    var runtime: Runtime = .{};
    defer runtime.deinit();
    var paths: [10][]const u8 = undefined;
    for (&paths, 0..) |*path, i| {
        const name = try c.fmt(a, "{d}.jsonl", .{i});
        try tmp.dir.writeFile(.{ .sub_path = name, .data = "{\"type\":\"USER_INPUT\"}\n" });
        path.* = try c.join(a, &.{ root, name });
    }
    for (paths[0..9]) |path| {
        try runtime.transcriptFor(path).update(path);
    }
    for (paths[0..9]) |path| {
        const tracker = runtime.transcriptFor(path);
        try std.testing.expectEqual(@as(i64, 1), tracker.steps);
        try tracker.update(path);
        try std.testing.expectEqual(@as(i64, 1), tracker.steps);
    }
    const first = runtime.transcriptFor(paths[0]);
    const second = runtime.transcriptFor(paths[1]);
    // Touch the first slot again so the second is the oldest.
    _ = runtime.transcriptFor(paths[0]);
    // Slots 2..8 were touched after slot 1 in the loop above; make slot 1 oldest.
    for (paths[2..9]) |path| _ = runtime.transcriptFor(path);
    const evicted = runtime.transcriptFor(paths[9]);
    try std.testing.expect(evicted == second);
    try evicted.update(paths[9]);
    try std.testing.expectEqualStrings(paths[9], evicted.path);
    try std.testing.expectEqual(@as(i64, 1), first.steps);
}

test "capped transcript window rolls instead of rescanning on every append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const path = try c.join(a, &.{ root, "big.jsonl" });
    var tr = Transcript.init();
    defer tr.deinit();
    // Two chunks instead of the production 1 GiB cap keeps the test cheap while
    // exercising exactly the same rolling-window math.
    tr.chunk_cap = 2;
    const padding = "x" ** 3000;
    var row = std.ArrayList(u8).init(a);
    try row.writer().print("{{\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"input_tokens\":10,\"cache_read_tokens\":0,\"output_tokens\":1,\"content\":\"{s}\"}}\n", .{padding});
    {
        var file = try tmp.dir.createFile("big.jsonl", .{});
        for (0..200) |_| try file.writeAll(row.items);
        file.close();
    }
    try tr.update(path);
    try std.testing.expectEqual(@as(usize, 2), tr.chunk_hashes.items.len);
    try std.testing.expect(tr.verified_from > 0);
    try std.testing.expectEqual(tr.offset, tr.trackedBytes());
    try std.testing.expectEqual(@as(i64, 200), tr.steps);
    const reloads_before = tr.reloads;
    // Appends past the cap must slide the window; a full re-scan per poll would
    // make a 1 GiB log unusable.
    var steps: i64 = 200;
    for (0..40) |_| {
        var file = try tmp.dir.openFile("big.jsonl", .{ .mode = .write_only });
        try file.seekFromEnd(0);
        try file.writeAll(row.items);
        file.close();
        try tr.update(path);
        steps += 1;
        try std.testing.expectEqual(steps, tr.steps);
        try std.testing.expectEqual(tr.offset, tr.trackedBytes());
    }
    try std.testing.expectEqual(reloads_before, tr.reloads);
    try std.testing.expectEqual(@as(usize, 2), tr.chunk_hashes.items.len);
    try std.testing.expectEqual(tr.offset - 2 * chunk_size - tr.cur_chunk_len, tr.verified_from);
}
