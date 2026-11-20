const std = @import("std");
const c = @import("common.zig");
const A = c.A;
const V = c.V;
extern "c" fn sqlite3_open_v2([*:0]const u8, *?*anyopaque, c_int, ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(?*anyopaque) c_int;
extern "c" fn sqlite3_busy_timeout(?*anyopaque, c_int) c_int;
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
const Point = struct { request: i64, idx: ?i64, at: ?f64, model: []const u8, context: ?i64, compact: bool };
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
const Transcript = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8 = "",
    identity: c.Sig = .{},
    offset: u64 = 0,
    boundary: u64 = 0,
    first: ?f64 = null,
    last: ?f64 = null,
    user: ?f64 = null,
    steps: i64 = 0,
    turns: i64 = 0,
    compactions: i64 = 0,
    usage: Usage = .{},
    models: std.StringArrayHashMap(Usage),
    points: [120]Point = undefined,
    point_count: usize = 0,
    latest: ?[3]?i64 = null,
    fn init() Transcript {
        return .{ .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator), .models = std.StringArrayHashMap(Usage).init(std.heap.c_allocator) };
    }
    fn deinit(self: *Transcript) void {
        self.models.deinit();
        self.arena.deinit();
    }
    fn reset(self: *Transcript) void {
        self.deinit();
        self.* = init();
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
        if (compact) self.compactions += 1 else self.latest = vals;
        if (self.point_count == self.points.len) {
            std.mem.copyForwards(Point, self.points[0 .. self.points.len - 1], self.points[1..]);
            self.point_count -= 1;
        }
        self.points[self.point_count] = .{ .request = self.usage.requests, .idx = c.int(item.step_index), .at = at, .model = entry.key_ptr.*, .context = if (!compact and vals[0] != null and vals[1] != null) vals[0].? +| vals[1].? else null, .compact = compact };
        self.point_count += 1;
    }
    fn hashBoundary(file: std.fs.File, offset: u64) !u64 {
        var buf: [256]u8 = undefined;
        const len: usize = @intCast(@min(offset, buf.len));
        var h = std.hash.Wyhash.init(0);
        if (try file.preadAll(buf[0..len], 0) != len) return error.EndOfStream;
        h.update(buf[0..len]);
        if (try file.preadAll(buf[0..len], offset - len) != len) return error.EndOfStream;
        h.update(buf[0..len]);
        return h.final();
    }
    fn update(self: *Transcript, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const st = try file.stat();
        const replaced = !c.eq(self.path, path) or self.identity.inode != st.inode or st.size < self.offset;
        const changed = st.mtime != self.identity.mtime or st.ctime != self.identity.ctime or st.size != self.identity.size;
        if (replaced or (changed and (st.size <= self.identity.size or try hashBoundary(file, self.offset) != self.boundary))) {
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
            const item = std.json.parseFromSlice(TranscriptRow, line_arena.allocator(), line.items, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch {
                self.offset += line.items.len + 1;
                _ = line_arena.reset(.free_all);
                continue;
            };
            try self.ingest(item.value);
            self.offset += line.items.len + 1;
            _ = line_arena.reset(.free_all);
        }
        self.boundary = try hashBoundary(file, self.offset);
        self.identity = .{ .inode = st.inode, .size = st.size, .mtime = st.mtime, .ctime = st.ctime, .exists = true };
    }
};
const Gen = struct {
    idx: i64,
    input: ?i64 = null,
    cached: ?i64 = null,
    written: ?i64 = null,
    output: ?i64 = null,
    exec: ?f64 = null,
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
    out.exec = c.duration(c.bytes(chat, 11));
    out.duration = c.duration(c.bytes(chat, 12));
    for ([_]?f64{ out.duration, out.exec }) |dur| {
        if (dur) |d| {
            if (d >= 0.1 and (out.output orelse 0) > 0) {
                const speed = @as(f64, @floatFromInt(out.output.?)) / d;
                if (speed > 0 and speed < 1000) {
                    out.speed = speed;
                    break;
                }
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
const DbResult = struct {
    readable: bool = false,
    latest: ?Gen = null,
    history: [12]Gen = undefined,
    count: usize = 0,
    speeds: std.StringArrayHashMap(Speed),
    usage: ?[4]i64 = null,
    live: bool = false,
    live_idx: ?i64 = null,
    live_type: ?i64 = null,
    status: ?i64 = null,
    chars: ?i64 = null,
    cpt: f64 = 1.4,
    fn init(a: A) DbResult {
        return .{ .speeds = std.StringArrayHashMap(Speed).init(a) };
    }
};
fn stepUsage(raw: []const u8) ?[4]i64 {
    const u = c.bytes(raw, 9) orelse return null;
    const i = c.number(u, 2);
    const o = c.number(u, 3);
    const w = c.number(u, 4);
    const r = c.number(u, 5);
    if (i == null and o == null and w == null and r == null) return null;
    return .{ i orelse 0, r orelse 0, o orelse 0, w orelse 0 };
}
fn readDb(a: A, path: []const u8) !DbResult {
    var out = DbResult.init(a);
    if (!c.sig(path).exists) return out;
    var db: ?*anyopaque = null;
    const z = try a.dupeZ(u8, path);
    // READONLY, never immutable: in-flight WAL updates must remain visible.
    if (sqlite3_open_v2(z, &db, 1, null) != 0) {
        if (db != null) _ = sqlite3_close(db);
        return out;
    }
    defer _ = sqlite3_close(db);
    _ = sqlite3_busy_timeout(db, 100);
    var sanity = Query.init(a, db, "PRAGMA query_only=ON") catch return out;
    _ = sanity.next() catch {
        sanity.deinit();
        return out;
    };
    sanity.deinit();
    var tables = Query.init(a, db, "SELECT name FROM sqlite_master LIMIT 1") catch return out;
    _ = tables.next() catch {
        tables.deinit();
        return out;
    };
    tables.deinit();
    out.readable = true;
    if (Query.init(a, db, "SELECT idx,data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx DESC")) |q| {
        defer q.deinit();
        while (q.next() catch false) {
            var rec = generation(q.integer(0) orelse continue, q.blob(1)) orelse continue;
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
    } else |_| {}
    var cols = Query.init(a, db, "PRAGMA table_info(steps)") catch return out;
    defer cols.deinit();
    var metadata: ?[]const u8 = null;
    var order: []const u8 = "rowid";
    var payload: ?[]const u8 = null;
    var has_data = false;
    var has_idx = false;
    var has_status = false;
    var has_type = false;
    while (cols.next() catch false) {
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
    if (metadata == null and has_data) metadata = "data";
    if (payload == null) payload = metadata;
    if (metadata) |col| {
        const sql = try c.fmt(a, "SELECT {s} FROM steps WHERE {s} IS NOT NULL ORDER BY {s} DESC LIMIT 40", .{ col, col, order });
        if (Query.init(a, db, sql)) |q| {
            defer q.deinit();
            while (q.next() catch false) {
                if (stepUsage(q.blob(0))) |u| {
                    out.usage = u;
                    break;
                }
            }
        } else |_| {}
    }
    if (payload != null and has_status) {
        const sql = try c.fmt(a, "SELECT {s},status,{s},{s} FROM steps ORDER BY {s} DESC LIMIT 1", .{ order, payload.?, if (has_type) "step_type" else "NULL", order });
        if (Query.init(a, db, sql)) |q| {
            defer q.deinit();
            if (q.next() catch false) {
                const status = q.integer(1) orelse 0;
                if (status == 1 or status == 2 or status == 8) {
                    out.live = true;
                    out.live_idx = q.integer(0);
                    out.status = status;
                    out.live_type = q.integer(3);
                    out.chars = c.chars(q.blob(2));
                }
            }
        } else |_| {}
    }
    if (out.live and metadata != null and payload != null) {
        const sql = try c.fmt(a, "SELECT {s},{s} FROM steps WHERE {s} IS NOT NULL ORDER BY {s} DESC LIMIT 24", .{ payload.?, metadata.?, metadata.?, order });
        if (Query.init(a, db, sql)) |q| {
            defer q.deinit();
            var chars: f64 = 0;
            var tokens: f64 = 0;
            while (q.next() catch false) {
                const u = stepUsage(q.blob(1)) orelse continue;
                if (u[2] <= 0) continue;
                const count = c.chars(q.blob(0)) orelse continue;
                if (count <= 0) continue;
                chars += @floatFromInt(count);
                tokens += @floatFromInt(u[2]);
            }
            if (chars > 0 and tokens > 0) out.cpt = std.math.clamp(chars / tokens, 0.4, 6);
        } else |_| {}
    }
    return out;
}

pub const Config = struct { root: []const u8, data: []const u8, quota: []const u8 };
pub const Runtime = struct {
    transcript: Transcript = Transcript.init(),
    db_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.c_allocator),
    db_id: [36]u8 = @splat(0),
    db_sig: c.Sig = .{},
    wal_sig: c.Sig = .{},
    db: ?DbResult = null,
    live_id: [36]u8 = @splat(0),
    live_step: ?i64 = null,
    samples: [5]struct { at: f64, chars: i64 } = undefined,
    sample_count: usize = 0,
    pub fn deinit(self: *Runtime) void {
        self.transcript.deinit();
        self.db_arena.deinit();
    }
    fn database(self: *Runtime, id: []const u8, path: []const u8, a: A) !DbResult {
        const sig = c.sig(path);
        const wal = c.sig(try c.fmt(a, "{s}-wal", .{path}));
        if (self.db != null and c.eq(&self.db_id, id) and std.meta.eql(sig, self.db_sig) and std.meta.eql(wal, self.wal_sig) and self.db.?.readable) return self.db.?;
        _ = self.db_arena.reset(.free_all);
        self.db = null;
        const result = try readDb(self.db_arena.allocator(), path);
        @memcpy(&self.db_id, id);
        self.db_sig = sig;
        self.wal_sig = wal;
        self.db = result;
        return result;
    }
    fn rate(self: *Runtime, id: []const u8, db: DbResult, now: f64) ?f64 {
        if (!db.live or db.chars == null or db.live_idx == null) {
            self.sample_count = 0;
            return null;
        }
        if (!c.eq(&self.live_id, id) or self.live_step != db.live_idx or (self.sample_count > 0 and self.samples[self.sample_count - 1].chars > db.chars.?)) self.sample_count = 0;
        @memcpy(&self.live_id, id);
        self.live_step = db.live_idx;
        if (self.sample_count == 5) {
            std.mem.copyForwards(@TypeOf(self.samples[0]), self.samples[0..4], self.samples[1..]);
            self.sample_count -= 1;
        }
        self.samples[self.sample_count] = .{ .at = now, .chars = db.chars.? };
        self.sample_count += 1;
        while (self.sample_count > 2 and now - self.samples[0].at > 4) {
            std.mem.copyForwards(@TypeOf(self.samples[0]), self.samples[0 .. self.sample_count - 1], self.samples[1..self.sample_count]);
            self.sample_count -= 1;
        }
        if (self.sample_count < 2) return null;
        const elapsed = now - self.samples[0].at;
        return if (elapsed > 0.05) @as(f64, @floatFromInt(db.chars.? - self.samples[0].chars)) / elapsed else null;
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
fn recent(a: A, root: []const u8, hooks: V) !V {
    const dirpath = try c.join(a, &.{ root, "conversations" });
    var items: [16]Recent = undefined;
    var count: usize = 0;
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
            if (count == 15 and at <= items[count - 1].at) continue;
            var item: Recent = .{ .id = undefined, .at = at };
            @memcpy(&item.id, entry.name[0..36]);
            items[count] = item;
            count += 1;
            std.mem.sort(Recent, items[0..count], {}, struct {
                fn less(_: void, x: Recent, y: Recent) bool {
                    return x.at > y.at;
                }
            }.less);
            count = @min(count, 15);
        }
    } else |_| {}
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
pub fn snapshot(a: A, runtime: *Runtime, cfg: Config, requested: []const u8) !V {
    const now: f64 = @as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000;
    const hooks = c.readJson(a, try c.join(a, &.{ cfg.data, "active_session.json" }));
    const active = c.str(c.get(hooks, "activeConversationId"));
    const conversations = try recent(a, cfg.root, hooks);
    var id = std.mem.trim(u8, requested, " \t\r\n");
    if (id.len == 0 or c.eq(id, "auto")) id = active;
    if (id.len == 0 and conversations.array.items.len > 0) id = c.str(c.get(conversations.array.items[0], "conversationId"));
    var out = c.object(a);
    try c.put(a, &out, "found", c.b(false));
    try c.put(a, &out, "conversationId", c.s(if (c.validId(id)) id else ""));
    try c.put(a, &out, "recentConversations", conversations);
    try c.put(a, &out, "hookConnected", c.b(active.len > 0));
    try c.put(a, &out, "quota", try quota(a, cfg.quota, @intFromFloat(now)));
    try c.put(a, &out, "generatedAt", try timeValue(a, now));
    var live = c.object(a);
    try c.put(a, &live, "active", c.b(false));
    try c.put(a, &out, "live", live);
    if (!c.validId(id)) {
        try c.put(a, &out, "message", c.s("No local Antigravity Desktop conversation found yet."));
        return out;
    }
    const meta = c.get(c.get(hooks, "sessions"), id);
    const dbpath = try c.join(a, &.{ cfg.root, "conversations", try c.fmt(a, "{s}.db", .{id}) });
    const db = try runtime.database(id, dbpath, a);
    var transcript_path = c.str(c.get(meta, "transcriptPath"));
    if (transcript_path.len == 0 or !c.sig(transcript_path).exists) transcript_path = try c.join(a, &.{ cfg.root, "brain", id, ".system_generated", "logs", "transcript.jsonl" });
    const has_log = blk: {
        runtime.transcript.update(transcript_path) catch break :blk false;
        break :blk true;
    };
    const tracker = &runtime.transcript;
    var model: []const u8 = if (db.latest) |r| r.model else "";
    if (model.len == 0) model = c.str(c.get(meta, "modelName"));
    var input: ?i64 = null;
    var cached: ?i64 = null;
    var written: ?i64 = null;
    var output: ?i64 = if (db.latest) |r| r.output else null;
    var source: []const u8 = "none";
    if (db.usage) |u| {
        input = u[0];
        cached = u[1];
        written = u[3];
        if (output == null and u[2] > 0) output = u[2];
        source = "steps";
    } else if (db.latest) |r| {
        if (r.input != null or r.cached != null) {
            input = r.input;
            cached = r.cached;
            written = r.written;
            source = "gen_metadata";
        }
    }
    const total: ?i64 = if (input != null or cached != null or written != null) (input orelse 0) +| (cached orelse 0) +| (written orelse 0) else null;
    const context: ?i64 = if ((total orelse 0) > 0) total else null;
    const lower = try std.ascii.allocLowerString(a, model);
    const capacity: ?i64 = if (contains(lower, "gemini") or contains(lower, "hydrogen") or contains(lower, "argon") or contains(lower, "flash")) 1048576 else if (contains(lower, "claude") or contains(lower, "sonnet") or contains(lower, "opus") or contains(lower, "haiku")) (if (contains(lower, "1m")) @as(i64, 1000000) else @as(i64, 200000)) else null;
    const denom: f64 = @floatFromInt((input orelse 0) +| (cached orelse 0));
    const hit: ?f64 = if (input != null and cached != null and denom > 0 and ((written orelse 0) == 0 or cached.? > 0)) 100 * @as(f64, @floatFromInt(cached.?)) / denom else null;
    const speed = if (db.latest) |r| r.speed else null;
    const dur = if (db.latest) |r| r.exec orelse r.duration else null;
    var workspace = c.str(c.get(meta, "cwd"));
    const paths = c.get(meta, "workspacePaths");
    if (paths == .array and paths.array.items.len > 0) workspace = c.str(paths.array.items[0]);
    try c.put(a, &out, "found", c.b(db.readable or has_log));
    try c.put(a, &out, "shortId", c.s(id[0..8]));
    try c.put(a, &out, "isActiveSession", c.b(c.eq(id, active)));
    try c.put(a, &out, "modelName", c.s(model));
    try c.put(a, &out, "workspaceName", c.s(std.fs.path.basename(workspace)));
    try c.put(a, &out, "lastAvgSpeed", c.rounded(speed, 10));
    try c.put(a, &out, "lowSpeedWarning", c.b(if (speed) |x| x < 50 else false));
    try c.put(a, &out, "lastGenDurationSec", c.rounded(dur, 100));
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
    if (has_log) {
        for (tracker.models.keys(), tracker.models.values()) |name, usage| {
            var row = try usage.value(a);
            const ms = db.speeds.get(name) orelse Speed{};
            try c.put(a, &row, "model", c.s(name));
            try c.put(a, &row, "avgSpeedTokS", c.rounded(if (ms.seconds > 0) ms.tokens / ms.seconds else null, 10));
            try c.put(a, &row, "speedSamples", c.n(ms.samples));
            try c.add(&models, row);
        }
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
    for (db.history[0..db.count]) |rec| {
        var row = c.object(a);
        try c.put(a, &row, "idx", c.n(rec.idx));
        try c.put(a, &row, "speedTokS", c.rounded(rec.speed, 10));
        try c.put(a, &row, "outputTokens", c.opt(rec.output));
        try c.put(a, &row, "durationSec", c.rounded(rec.exec orelse rec.duration, 100));
        try c.put(a, &row, "model", c.s(if (rec.model.len > 0) rec.model else model));
        try c.add(&history, row);
    }
    try c.put(a, &out, "history", history);
    const rate = runtime.rate(id, db, now);
    if (db.live) {
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
    return out;
}
