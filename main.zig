const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Single source of truth: the repository root VERSION file.
const version = @embedFile("VERSION");
extern "c" fn sqlite3_open_v2([*:0]const u8, *?*anyopaque, c_int, ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(?*anyopaque) c_int;
extern "c" fn sqlite3_errcode(?*anyopaque) c_int;
extern "c" fn sqlite3_prepare_v2(?*anyopaque, [*:0]const u8, c_int, *?*anyopaque, ?*?[*:0]const u8) c_int;
extern "c" fn sqlite3_step(?*anyopaque) c_int;
extern "c" fn sqlite3_column_blob(?*anyopaque, c_int) ?[*]const u8;
extern "c" fn sqlite3_column_bytes(?*anyopaque, c_int) c_int;
extern "c" fn sqlite3_finalize(?*anyopaque) c_int;

const Usage = struct { input_tokens: ?i64 = null, cache_read_input_tokens: ?i64 = null, cache_creation_input_tokens: ?i64 = null };
const QuotaBucket = struct { remaining_fraction: ?f64 = null, reset_in_seconds: ?i64 = null, disabled: ?bool = null };
const QuotaWindow = struct { h5: ?f64 = null, weekly: ?f64 = null, other: ?f64 = null };
const QuotaSummary = struct { gemini: QuotaWindow = .{}, argon: QuotaWindow = .{}, claude: QuotaWindow = .{} };
const ContextWindow = struct {
    total_input_tokens: ?i64 = null,
    context_window_size: ?i64 = null,
    current_usage: ?Usage = null,
};
const State = struct {
    terminal_width: ?usize = null,
    conversation_id: []const u8 = "",
    context_window: ContextWindow = .{},
    quota: ?std.json.ArrayHashMap(QuotaBucket) = null,
};

fn varint(data: []const u8, pos: *usize) ?u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    for (0..10) |_| {
        if (pos.* >= data.len) return null;
        const b = data[pos.*]; pos.* += 1;
        if (shift == 63 and b > 1) return null;
        value |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return value;
        if (shift == 63) return null;
        shift += 7;
    }
    return null;
}
const Field = union(enum) { number: u64, bytes: []const u8 };
fn field(data: []const u8, wanted: u64) ?Field {
    var pos: usize = 0;
    var result: ?Field = null;
    while (pos < data.len) {
        const key = varint(data, &pos) orelse return null;
        if (key >> 3 == 0) return null;
        const f: Field = switch (key & 7) {
            0 => .{ .number = varint(data, &pos) orelse return null },
            2 => blk: {
                const size = varint(data, &pos) orelse return null;
                if (size > data.len - pos) return null;
                const end = pos + @as(usize, @intCast(size));
                const v = data[pos..end]; pos = end;
                break :blk .{ .bytes = v };
            },
            1, 5 => blk: {
                const size: usize = if (key & 7 == 1) 8 else 4;
                if (size > data.len - pos) return null;
                pos += size; break :blk .{ .number = 0 };
            },
            else => return null,
        };
        if (key >> 3 == wanted) result = f;
    }
    return result;
}
fn bytes(data: []const u8, id: u64) ?[]const u8 { const v = field(data, id) orelse return null; return if (v == .bytes) v.bytes else null; }
fn number(data: []const u8, id: u64) u64 { const v = field(data, id) orelse return 0; return if (v == .number) v.number else 0; }
const SpeedSample = struct { output: u64, seconds: f64 };
const SpeedAccumulator = struct {
    steady_output: f64 = 0,
    steady_seconds: f64 = 0,
    short_output: f64 = 0,
    short_seconds: f64 = 0,

    fn add(self: *SpeedAccumulator, sample: SpeedSample) void {
        if (sample.seconds >= 0.3) {
            self.steady_output += @floatFromInt(sample.output);
            self.steady_seconds += sample.seconds;
        } else {
            self.short_output += @floatFromInt(sample.output);
            self.short_seconds += sample.seconds;
        }
    }

    fn finish(self: SpeedAccumulator) ?f64 {
        if (self.steady_seconds >= 0.3 and self.steady_output > 0) {
            return self.steady_output / self.steady_seconds;
        }
        if (self.short_seconds >= 0.1 and self.short_output > 0) {
            return self.short_output / self.short_seconds;
        }
        return null;
    }
};
fn metadataSample(data: []const u8) ?SpeedSample {
    const chat = bytes(data, 1) orelse return null;
    const usage = bytes(chat, 4) orelse return null;
    const duration = bytes(chat, 12) orelse return null;
    const nanos = number(duration, 2);
    if (nanos >= 1_000_000_000) return null;
    const seconds = @as(f64, @floatFromInt(number(duration, 1))) + @as(f64, @floatFromInt(nanos)) / 1e9;
    const output = number(usage, 3);
    if (seconds < 0.1 or output == 0) return null;
    const speed = @as(f64, @floatFromInt(output)) / seconds;
    if (speed <= 0 or speed >= 1000) return null;
    return .{ .output = output, .seconds = seconds };
}
fn metadataSpeed(data: []const u8) ?f64 {
    const sample = metadataSample(data) orelse return null;
    return @as(f64, @floatFromInt(sample.output)) / sample.seconds;
}
fn fileUri(allocator: Allocator, path: []const u8, query: []const u8) ![:0]const u8 {
    var out = std.ArrayList(u8).init(allocator);
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
fn isWalHeader(path: []const u8) bool {
    const file = std.fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();
    var hdr: [20]u8 = undefined;
    const len = file.readAll(&hdr) catch return false;
    return len == hdr.len and (hdr[18] == 2 or hdr[19] == 2);
}
fn querySpeed(target: [:0]const u8, flags: c_int, err_out: *c_int, speed_out: *?f64) bool {
    speed_out.* = null;
    err_out.* = 0;
    var db: ?*anyopaque = null;
    if (sqlite3_open_v2(target, &db, flags, null) != 0) {
        if (db != null) {
            err_out.* = sqlite3_errcode(db);
            _ = sqlite3_close(db);
        }
        return false;
    }
    defer _ = sqlite3_close(db);
    var stmt: ?*anyopaque = null;
    if (sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx DESC LIMIT 12", -1, &stmt, null) != 0) {
        err_out.* = sqlite3_errcode(db);
        return false;
    }
    defer _ = sqlite3_finalize(stmt);
    var acc: SpeedAccumulator = .{};
    while (true) {
        const rc = sqlite3_step(stmt);
        if (rc == 101) break;
        if (rc != 100) {
            err_out.* = sqlite3_errcode(db);
            return false;
        }
        const ptr = sqlite3_column_blob(stmt, 0) orelse continue;
        const len = sqlite3_column_bytes(stmt, 0);
        if (len > 0) {
            if (metadataSample(ptr[0..@intCast(len)])) |sample| {
                acc.add(sample);
            }
        }
    }
    speed_out.* = acc.finish();
    return true;
}
fn lastSpeed(allocator: Allocator, id: []const u8) ?f64 {
    if (id.len != 36) return null;
    for (id) |ch| if (!std.ascii.isHex(ch) and ch != '-') { return null; };
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return null;
    const path = std.fmt.allocPrint(allocator, "{s}/.gemini/antigravity-cli/conversations/{s}.db", .{ home, id }) catch return null;
    const path_z = allocator.dupeZ(u8, path) catch return null;
    var err: c_int = 0;
    var speed: ?f64 = null;
    if (querySpeed(path_z, 1, &err, &speed)) return speed;
    // Closed WAL databases with no active -wal/-shm reject mode=ro because
    // SQLite cannot create -shm read-only; immutable=1 is safe when -wal is absent/empty.
    const primary = err & 0xff;
    if (primary == 5 or primary == 6 or !isWalHeader(path)) return null;
    const wal_path = std.fmt.allocPrint(allocator, "{s}-wal", .{path}) catch return null;
    if (std.fs.cwd().statFile(wal_path)) |st| {
        if (st.size > 0) return null;
    } else |_| {}
    const uri = fileUri(allocator, path, "immutable=1") catch return null;
    _ = querySpeed(uri, 0x41, &err, &speed);
    return speed;
}
// Transcript totals use logged input + cache reads + output, including completed
// CHECKPOINT requests. Cache writes are not exposed consistently in this log.
const TranscriptEntry = struct {
    type: []const u8 = "",
    status: []const u8 = "",
    input_tokens: std.json.Value = .null,
    cache_read_tokens: std.json.Value = .null,
    output_tokens: std.json.Value = .null,
};

fn loggedTokens(value: std.json.Value) ?i64 {
    return switch (value) {
        .integer => |n| if (n >= 0 and n <= 9_007_199_254_740_991) n else null,
        else => null,
    };
}
const SessionStats = struct {
    requests: usize = 0,
    recorded: usize = 0,
    input: i64 = 0,
    cached: i64 = 0,
    output: i64 = 0,
    compactions: usize = 0,

    fn ingest(self: *SessionStats, entry: TranscriptEntry) void {
        if (!std.mem.eql(u8, entry.status, "DONE")) return;
        const checkpoint = std.mem.eql(u8, entry.type, "CHECKPOINT");
        if (!checkpoint and !std.mem.eql(u8, entry.type, "PLANNER_RESPONSE")) return;
        if (checkpoint) self.compactions += 1;
        self.requests += 1;
        const input = loggedTokens(entry.input_tokens) orelse return;
        const cached = loggedTokens(entry.cache_read_tokens) orelse return;
        const output = loggedTokens(entry.output_tokens) orelse return;
        self.recorded += 1;
        self.input +|= input;
        self.cached +|= cached;
        self.output +|= output;
    }
};

const SessionCache = struct {
    version: u32 = 1,
    inode: std.fs.File.INode = 0,
    size: u64 = 0,
    mtime: i128 = 0,
    offset: u64 = 0,
    boundary_hash: u64 = 0,
    stats: SessionStats = .{},
};

fn transcriptBoundaryHash(file: std.fs.File, offset: u64) !u64 {
    // Sample both ends to catch truncate-and-regrow between refreshes.
    var sample: [256]u8 = undefined;
    const len: usize = @intCast(@min(offset, sample.len));
    if (try file.preadAll(sample[0..len], 0) != len) return error.EndOfStream;
    var hash = std.hash.Wyhash.init(0);
    hash.update(sample[0..len]);
    if (try file.preadAll(sample[0..len], offset - len) != len) return error.EndOfStream;
    hash.update(sample[0..len]);
    return hash.final();
}

fn appendSessionStats(reader: anytype, cache: *SessionCache) !void {
    var line = std.ArrayList(u8).init(std.heap.page_allocator);
    defer line.deinit();
    while (true) {
        // Leave an incomplete final line for the next refresh.
        reader.readUntilDelimiterArrayList(&line, '\n', 16 * 1024 * 1024) catch |err| {
            if (err == error.EndOfStream) return;
            return err;
        };
        cache.offset += line.items.len + 1;
        const parsed = std.json.parseFromSlice(TranscriptEntry, std.heap.page_allocator, line.items, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        cache.stats.ingest(parsed.value);
    }
}

fn updateSessionStats(file: std.fs.File, previous: ?SessionCache) !SessionCache {
    const st = try file.stat();
    var cache: SessionCache = .{};
    if (previous) |old| {
        if (old.version == 1 and old.inode == st.inode and old.offset <= old.size and
            old.size <= st.size and (old.mtime == st.mtime or old.size < st.size) and
            old.boundary_hash == try transcriptBoundaryHash(file, old.offset)) cache = old;
    }
    if (cache.inode == st.inode and cache.size == st.size and cache.mtime == st.mtime) return cache;
    try file.seekTo(cache.offset);
    var limited = std.io.limitedReader(file.reader(), st.size - cache.offset);
    var buffered = std.io.bufferedReader(limited.reader());
    try appendSessionStats(buffered.reader(), &cache);
    cache.inode = st.inode;
    cache.size = st.size;
    cache.mtime = st.mtime;
    cache.boundary_hash = try transcriptBoundaryHash(file, cache.offset);
    return cache;
}

fn sessionStats(allocator: Allocator, id: []const u8) ?SessionStats {
    if (id.len != 36) return null;
    for (id) |ch| if (!std.ascii.isHex(ch) and ch != '-') { return null; };
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return null;
    const path = std.fmt.allocPrint(allocator, "{s}/.gemini/antigravity-cli/brain/{s}/.system_generated/logs/transcript.jsonl", .{home, id}) catch return null;
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const cache_path = std.fmt.allocPrint(allocator, "{s}/.gemini/agy-statusline/sessions/{s}.json", .{home, id}) catch return null;
    const raw = std.fs.cwd().readFileAlloc(allocator, cache_path, 4096) catch null;
    const previous = if (raw) |data| std.json.parseFromSlice(SessionCache, allocator, data, .{}) catch null else null;
    const cache = updateSessionStats(file, if (previous) |p| p.value else null) catch return null;
    if (previous == null or !std.meta.eql(previous.?.value, cache)) {
        // A failed cache write must not hide otherwise readable statistics.
        var out = std.ArrayList(u8).init(allocator);
        std.json.stringify(cache, .{}, out.writer()) catch return cache.stats;
        var dest = std.fs.cwd().atomicFile(cache_path, .{ .make_path = true }) catch return cache.stats;
        defer dest.deinit();
        dest.file.writeAll(out.items) catch return cache.stats;
        dest.finish() catch return cache.stats;
    }
    return cache.stats;
}

fn appendSessionMetrics(allocator: Allocator, metrics: []const u8, stats: ?SessionStats, width: usize) ![]const u8 {
    const reset = "\x1b[0m\n";
    const prefix = metrics[0 .. metrics.len - reset.len];
    const cp = if (stats) |s| try std.fmt.allocPrint(allocator, " | Compact: {d}", .{s.compactions}) else " | Compact: --";
    const compact = try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{prefix, cp, reset});
    if (width > 0 and visibleLen(compact) > width) return metrics;
    const s = stats orelse return compact;
    if (s.recorded == 0) return compact;
    const total = s.input +| s.cached +| s.output;
    const coverage = if (s.recorded < s.requests) try std.fmt.allocPrint(allocator, " ({d}/{d})", .{s.recorded, s.requests}) else "";
    const input = @as(f64, @floatFromInt(s.input)) + @as(f64, @floatFromInt(s.cached));
    const cache = if (input > 0) try std.fmt.allocPrint(allocator, "{d:.1}%", .{100 * @as(f64, @floatFromInt(s.cached)) / input}) else "--";
    const full = try std.fmt.allocPrint(allocator, "{s}{s} | Log: {s} tok{s} | S.Cache: {s}{s}", .{prefix, cp, try formatTokens(allocator, total), coverage, cache, reset});
    return if (width > 0 and visibleLen(full) <= width) full else compact;
}

fn formatTokens(allocator: Allocator, value: i64) ![]const u8 {
    const n = if (value >= 1000) @divTrunc(value, 1000) else value;
    const raw = try std.fmt.allocPrint(allocator, "{d}", .{n});
    var out = std.ArrayList(u8).init(allocator);
    for (raw, 0..) |ch, i| {
        if (i > 0 and (raw.len - i) % 3 == 0) try out.append(',');
        try out.append(ch);
    }
    if (value >= 1000) try out.append('K');
    return out.toOwnedSlice();
}
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn updateMin(slot: *?f64, val: f64) void {
    slot.* = if (slot.*) |cur| @min(cur, val) else val;
}

fn recordWindow(w: *QuotaWindow, key: []const u8, val: f64) void {
    if (containsIgnoreCase(key, "5h")) {
        updateMin(&w.h5, val);
    } else if (containsIgnoreCase(key, "weekly")) {
        updateMin(&w.weekly, val);
    } else {
        updateMin(&w.other, val);
    }
}

fn hasWindow(w: QuotaWindow) bool {
    return w.h5 != null or w.weekly != null or w.other != null;
}

fn summarizeQuota(quota: ?std.json.ArrayHashMap(QuotaBucket)) QuotaSummary {
    var summary: QuotaSummary = .{};
    const q = quota orelse return summary;
    var it = q.map.iterator();
    while (it.next()) |entry| {
        const frac = entry.value_ptr.remaining_fraction orelse continue;
        const clamped = @max(0.0, @min(1.0, frac));
        const key = entry.key_ptr.*;
        if (containsIgnoreCase(key, "argon")) {
            recordWindow(&summary.argon, key, clamped);
        } else if (containsIgnoreCase(key, "gemini") or containsIgnoreCase(key, "hydrogen") or containsIgnoreCase(key, "flash")) {
            recordWindow(&summary.gemini, key, clamped);
        } else if (containsIgnoreCase(key, "3p") or containsIgnoreCase(key, "claude") or containsIgnoreCase(key, "gpt") or containsIgnoreCase(key, "anthropic")) {
            recordWindow(&summary.claude, key, clamped);
        }
    }
    return summary;
}

fn visibleLen(s: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and s[i] != 'm') : (i += 1) {}
            if (i < s.len) i += 1;
            continue;
        }
        if (s[i] != '\n' and (s[i] & 0xC0) != 0x80) count += 1;
        i += 1;
    }
    return count;
}

fn appendGroup(out: *std.ArrayList(u8), badge_color: []const u8, label: []const u8, w: QuotaWindow) !void {
    if (!hasWindow(w)) return;
    const writer = out.writer();
    if (w.h5 != null and w.weekly != null) {
        try writer.print("{s} {s} {d:.0}% · {d:.0}% ", .{ badge_color, label, w.h5.? * 100.0, w.weekly.? * 100.0 });
    } else if (w.h5 orelse w.weekly orelse w.other) |v| {
        try writer.print("{s} {s} {d:.0}% ", .{ badge_color, label, v * 100.0 });
    }
}

fn renderContext(allocator: Allocator, cw: ContextWindow) ![]const u8 {
    const total = cw.context_window_size orelse return "Ctx: --";
    if (total <= 0) return "Ctx: --";
    var used: ?i64 = null;
    if (cw.current_usage) |u| {
        if (u.input_tokens != null and u.cache_read_input_tokens != null and u.cache_creation_input_tokens != null) {
            const in_t = u.input_tokens.?;
            const read_t = u.cache_read_input_tokens.?;
            const create_t = u.cache_creation_input_tokens.?;
            if (in_t >= 0 and read_t >= 0 and create_t >= 0) {
                used = in_t +| read_t +| create_t;
            }
        }
    }
    if (used == null) {
        if (cw.total_input_tokens) |t| {
            if (t >= 0) used = t;
        }
    }
    const u_val = used orelse return "Ctx: --";
    return std.fmt.allocPrint(allocator, "Ctx: {s}/{s}", .{ try formatTokens(allocator, u_val), try formatTokens(allocator, total) });
}

fn renderMetrics(allocator: Allocator, cw: ContextWindow, speed: ?f64, color: []const u8) ![]const u8 {
    const speed_text = if (speed) |s| try std.fmt.allocPrint(allocator, "Last avg speed: {d:.0} token/s", .{s}) else "Last avg speed: --";
    const ctx_text = try renderContext(allocator, cw);
    if (cw.current_usage) |u| {
        if (u.input_tokens != null and u.cache_read_input_tokens != null and u.cache_creation_input_tokens != null) {
            const input = u.input_tokens.?; const read = u.cache_read_input_tokens.?;
            if (input >= 0 and read >= 0 and u.cache_creation_input_tokens.? == 0) {
                const total = @as(f64, @floatFromInt(input)) + @as(f64, @floatFromInt(read));
                if (total > 0) return std.fmt.allocPrint(allocator, "{s}Cache hit: {d:.1}% | Cache read: {s} | {s} | {s}\x1b[0m\n", .{color, 100 * @as(f64, @floatFromInt(read)) / total, try formatTokens(allocator, read), ctx_text, speed_text});
            }
        }
    }
    return std.fmt.allocPrint(allocator, "{s}Cache hit: -- | {s} | {s}\x1b[0m\n", .{color, ctx_text, speed_text});
}

// Persist the last quota snapshot so other surfaces (the Desktop sidebar panel)
// can render absolute reset times instead of the relative "resets in 2d 4h"
// wording. Purely local, read-only with respect to AGY state.
const QuotaCacheBucket = struct { key: []const u8, remaining_fraction: f64, reset_at: ?i64 = null };
const QuotaCache = struct {
    schema: u32 = 1,
    source: []const u8 = "agy-statusline",
    observed_at: i64,
    buckets: []const QuotaCacheBucket,
};

fn quotaCachePath(allocator: Allocator) ?[]const u8 {
    if (std.process.getEnvVarOwned(allocator, "AGY_STATUSLINE_QUOTA_FILE")) |path| {
        if (path.len > 0) return path;
    } else |_| {}
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return null;
    if (home.len == 0) return null;
    return std.fmt.allocPrint(allocator, "{s}/.gemini/agy-statusline/quota.json", .{home}) catch null;
}

fn writeQuotaSnapshot(allocator: Allocator, quota: ?std.json.ArrayHashMap(QuotaBucket)) void {
    const quota_map = quota orelse return;
    const now = std.time.timestamp();
    var buckets = std.ArrayList(QuotaCacheBucket).init(allocator);
    var it = quota_map.map.iterator();
    while (it.next()) |entry| {
        const frac = entry.value_ptr.remaining_fraction orelse continue;
        if (std.math.isNan(frac)) continue;
        var reset_at: ?i64 = null;
        if (entry.value_ptr.reset_in_seconds) |seconds| {
            // Guard against absurd values so a corrupt payload cannot move a reset
            // window years into the future.
            if (seconds > 0 and seconds < 400 * 24 * 3600) reset_at = now + seconds;
        }
        buckets.append(.{
            .key = entry.key_ptr.*,
            .remaining_fraction = @max(0.0, @min(1.0, frac)),
            .reset_at = reset_at,
        }) catch return;
    }
    if (buckets.items.len == 0) return;

    var out = std.ArrayList(u8).init(allocator);
    std.json.stringify(QuotaCache{ .observed_at = now, .buckets = buckets.items }, .{ .emit_null_optional_fields = false }, out.writer()) catch return;

    const path = quotaCachePath(allocator) orelse return;
    var file = std.fs.cwd().atomicFile(path, .{ .make_path = true }) catch return;
    defer file.deinit();
    file.file.writeAll(out.items) catch return;
    file.finish() catch return;
}

fn renderQuotaLine(allocator: Allocator, quota: QuotaSummary, base_color: []const u8) !?[]const u8 {
    if (!hasWindow(quota.gemini) and !hasWindow(quota.argon) and !hasWindow(quota.claude)) return null;
    var out = std.ArrayList(u8).init(allocator);
    try appendGroup(&out, "\x1b[46;30m", "Gemini", quota.gemini);
    try appendGroup(&out, "\x1b[106;30m", "Argon", quota.argon);
    try appendGroup(&out, "\x1b[48;5;208;30m", "Claude", quota.claude);
    try out.appendSlice(base_color);
    try out.appendSlice("\x1b[0m\n");
    return try out.toOwnedSlice();
}

fn render(allocator: Allocator, cw: ContextWindow, speed: ?f64, quota: QuotaSummary) ![]const u8 {
    const color = if (speed != null and speed.? < 50) "\x1b[43;30m" else "\x1b[44;97m";
    const metrics = try renderMetrics(allocator, cw, speed, color);
    const quota_line = try renderQuotaLine(allocator, quota, color) orelse return metrics;
    return std.fmt.allocPrint(allocator, "{s} | {s}", .{ metrics[0 .. metrics.len - "\x1b[0m\n".len], quota_line });
}

fn writePaddedLine(writer: anytype, line: []const u8, width: usize) !void {
    const padding = width -| visibleLen(line);
    try writer.writeAll(line[0 .. line.len - "\x1b[0m\n".len]);
    try writer.writeByteNTimes(' ', padding);
    try writer.writeAll("\x1b[0m\n");
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator); defer arena.deinit();
    const a = arena.allocator();
    // Present so installers and `--doctor` can probe that the binary executes at
    // all (a Gatekeeper denial shows up as SIGKILL before any stdout).
    for (try std.process.argsAlloc(a)) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            try std.io.getStdOut().writeAll("agy-statusline " ++ version ++ "\n");
            return;
        }
    }
    const input = std.io.getStdIn().reader().readAllAlloc(a, 1024 * 1024) catch "";
    const state = std.json.parseFromSlice(State, a, input, .{ .ignore_unknown_fields = true }) catch null;
    if (state) |s| startCliNotch(a, s.value.conversation_id);
    const cw = if (state) |s| s.value.context_window else ContextWindow{};
    const speed = if (state) |s| lastSpeed(a, s.value.conversation_id) else null;
    const quota = if (state) |s| summarizeQuota(s.value.quota) else QuotaSummary{};
    writeQuotaSnapshot(a, if (state) |s| s.value.quota else null);
    const width = if (state) |s| @min(s.value.terminal_width orelse 0, 1000) else 0;
    const color = if (speed != null and speed.? < 50) "\x1b[43;30m" else "\x1b[44;97m";
    const metrics = try appendSessionMetrics(a, try renderMetrics(a, cw, speed, color), if (state) |s| sessionStats(a, s.value.conversation_id) else null, width);
    const quota_line = try renderQuotaLine(a, quota, color);
    const writer = std.io.getStdOut().writer();
    if (quota_line) |ql| {
        const single = try std.fmt.allocPrint(a, "{s} | {s}", .{ metrics[0 .. metrics.len - "\x1b[0m\n".len], ql });
        if (width > 0 and visibleLen(single) > width) {
            try writePaddedLine(writer, metrics, width);
            try writePaddedLine(writer, ql, width);
            return;
        }
        try writePaddedLine(writer, single, width);
    } else {
        try writePaddedLine(writer, metrics, width);
    }
}

fn startCliNotch(a: Allocator, id: []const u8) void {
    if (comptime builtin.os.tag != .macos) return;
    const common = @import("desktop-panel/native/common.zig");
    if (!common.validId(id) or common.env(a, "AGY_NO_NOTCH") != null) return;
    const exe = std.fs.selfExePathAlloc(a) catch return;
    const root = common.env(a, "AGY_CLI_DIR") orelse (std.fs.path.dirname(exe) orelse return);
    const backend = common.join(a, &.{ root, "sidecars", "status", "agy-desktop-backend" }) catch return;
    std.fs.cwd().access(backend, .{}) catch return;
    var child = std.process.Child.init(&.{ backend, "cli-status", "--desktop-root", root, "--conversation-id", id }, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    // The short-lived statusline must never wait for menu bar startup.
    _ = child.spawn() catch {};
}

test "formatting and speed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const text = try formatTokens(a, 1_234_567); defer a.free(text);
    try std.testing.expectEqualStrings("1,234K", text);
    const data = [_]u8{0x0a,0x08,0x22,0x02,0x18,0x64,0x62,0x02,0x08,0x02};
    try std.testing.expectEqual(@as(?f64, 50), metadataSpeed(&data));
    // Unrealistic burst (>=1000 tok/s) is filtered out.
    const burst = [_]u8{0x0a,0x0d,0x22,0x03,0x18,0xe8,0x07,0x62,0x06,0x08,0x00,0x10,0x80,0x94,0xeb,0xdc,0x03};
    // output=1000, seconds=0.5 (500_000_000 ns) -> 2000 tok/s -> null
    try std.testing.expectEqual(@as(?f64, null), metadataSpeed(&burst));
    // Prefer steady (>=0.3s) samples over short (0.1s..0.3s) burst samples, falling back only when no steady sample exists.
    var acc_steady: SpeedAccumulator = .{};
    acc_steady.add(.{ .output = 160, .seconds = 0.2 }); // 800 tok/s short burst
    acc_steady.add(.{ .output = 200, .seconds = 1.0 }); // 200 tok/s steady
    try std.testing.expectApproxEqAbs(@as(f64, 200), acc_steady.finish().?, 1e-6);
    var acc_short: SpeedAccumulator = .{};
    acc_short.add(.{ .output = 100, .seconds = 0.2 }); // 500 tok/s short fallback
    try std.testing.expectApproxEqAbs(@as(f64, 500), acc_short.finish().?, 1e-6);
    try std.testing.expectEqual(@as(?f64, null), (SpeedAccumulator{}).finish());
    try std.testing.expectEqual(@as(?f64, null), metadataSpeed(&.{0x0a,0xff}));
    const line = try render(a, .{ .context_window_size = 1_048_576, .current_usage = .{ .input_tokens = 200, .cache_read_input_tokens = 800, .cache_creation_input_tokens = 0 } }, 12.6, .{}); defer a.free(line);
    try std.testing.expectEqualStrings("\x1b[43;30mCache hit: 80.0% | Cache read: 800 | Ctx: 1K/1,048K | Last avg speed: 13 token/s\x1b[0m\n", line);
}

test "quota summary and rendering" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const json =
        \\{"terminal_width":110,"quota":{"gemini-weekly":{"remaining_fraction":0.9875},"gemini-5h":{"remaining_fraction":0.9815},"gemini-argon-wtu-weekly":{"remaining_fraction":1},"3p-5h":{"remaining_fraction":1},"3p-weekly":{"remaining_fraction":0.85}}}
    ;
    const state = try std.json.parseFromSlice(State, a, json, .{ .ignore_unknown_fields = true });
    const quota = summarizeQuota(state.value.quota);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9815), quota.gemini.h5.?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9875), quota.gemini.weekly.?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), quota.argon.weekly.?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), quota.claude.h5.?, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 0.85), quota.claude.weekly.?, 1e-6);
    const line = try render(a, .{}, 60, quota);
    try std.testing.expectEqualStrings("\x1b[44;97mCache hit: -- | Ctx: -- | Last avg speed: 60 token/s | \x1b[46;30m Gemini 98% · 99% \x1b[106;30m Argon 100% \x1b[48;5;208;30m Claude 100% · 85% \x1b[44;97m\x1b[0m\n", line);
    try std.testing.expectEqual(@as(usize, 104), visibleLen(line));
}


test "transcript totals and width-aware session metrics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const log =
        \\{"type":"PLANNER_RESPONSE","status":"DONE","input_tokens":100,"cache_read_tokens":900,"output_tokens":100}
        \\{"type":"PLANNER_RESPONSE","status":"DONE","input_tokens":900,"cache_read_tokens":100,"output_tokens":100}
        \\{"type":"CHECKPOINT","status":"DONE"}
        \\{"type":"PLANNER_RESPONSE","status":"GENERATING","input_tokens":999}
        \\{"type":"PLANNER_RESPONSE","status":"DONE","input_tokens":"invalid","cache_read_tokens":0,"output_tokens":5}
        \\{broken
    ;
    var stream = std.io.fixedBufferStream(log);
    var cache: SessionCache = .{};
    try appendSessionStats(stream.reader(), &cache);
    const stats = cache.stats;
    try std.testing.expectEqual(@as(usize, 1), stats.compactions);
    try std.testing.expectEqual(@as(usize, 4), stats.requests);
    try std.testing.expectEqual(@as(usize, 2), stats.recorded);
    const base = try renderMetrics(a, .{}, null, "");
    const wide = try appendSessionMetrics(a, base, stats, 300);
    try std.testing.expect(std.mem.indexOf(u8, wide, "Compact: 1 | Log: 2K tok (2/4) | S.Cache: 50.0%") != null);
    const narrow = try appendSessionMetrics(a, base, stats, 70);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "Compact: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, narrow, "Log:") == null);
    const missing = try appendSessionMetrics(a, base, null, 300);
    try std.testing.expect(std.mem.indexOf(u8, missing, "Compact: --") != null);
    const context = try renderMetrics(a, .{ .total_input_tokens = 123000, .context_window_size = 256000 }, null, "");
    for ([_]?SessionStats{ stats, null }) |s| {
        const small = try appendSessionMetrics(a, context, s, 60);
        try std.testing.expect(visibleLen(small) <= 60);
        try std.testing.expectEqualStrings(context, small);
    }
}

test "session cache follows appends, partial lines, truncation and replacement" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("transcript.jsonl", .{ .read = true });
    defer file.close();
    const reply = "{\"type\":\"PLANNER_RESPONSE\",\"status\":\"DONE\",\"input_tokens\":100,\"cache_read_tokens\":900,\"output_tokens\":100}\n";
    const checkpoint = "{\"type\":\"CHECKPOINT\",\"status\":\"DONE\"}\n";
    try file.writeAll(reply);
    const first = try updateSessionStats(file, null);
    try std.testing.expectEqual(@as(usize, 1), first.stats.requests);
    try std.testing.expectEqual(@as(i64, 900), first.stats.cached);
    try std.testing.expectEqualDeep(first, try updateSessionStats(file, first));

    try file.seekFromEnd(0);
    try file.writeAll(checkpoint[0..10]);
    const partial = try updateSessionStats(file, first);
    try std.testing.expectEqual(first.offset, partial.offset);
    try std.testing.expectEqualDeep(first.stats, partial.stats);
    try file.seekFromEnd(0);
    try file.writeAll(checkpoint[10..]);
    const appended = try updateSessionStats(file, partial);
    try std.testing.expectEqual(@as(usize, 2), appended.stats.requests);
    try std.testing.expectEqual(@as(usize, 1), appended.stats.compactions);
    try std.testing.expectEqualDeep(appended, try updateSessionStats(file, appended));

    try file.setEndPos(0);
    try file.seekTo(0);
    try file.writeAll(checkpoint);
    const truncated = try updateSessionStats(file, appended);
    try std.testing.expectEqual(@as(usize, 1), truncated.stats.requests);
    try std.testing.expectEqual(@as(usize, 0), truncated.stats.recorded);

    const replacement = try tmp.dir.createFile("replacement.jsonl", .{ .read = true });
    defer replacement.close();
    try replacement.writeAll(reply);
    try tmp.dir.rename("replacement.jsonl", "transcript.jsonl");
    const replaced = try updateSessionStats(replacement, truncated);
    try std.testing.expectEqual(@as(usize, 1), replaced.stats.recorded);
    try std.testing.expectEqual(@as(usize, 0), replaced.stats.compactions);

    // Truncation may be followed by enough writes to exceed the old size.
    try replacement.setEndPos(0);
    try replacement.seekTo(0);
    for (0..4) |_| try replacement.writeAll(checkpoint);
    const regrown = try updateSessionStats(replacement, replaced);
    try std.testing.expectEqual(@as(usize, 4), regrown.stats.compactions);
    try std.testing.expectEqual(@as(usize, 0), regrown.stats.recorded);
}
