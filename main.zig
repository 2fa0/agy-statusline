const std = @import("std");
const Allocator = std.mem.Allocator;
extern "c" fn sqlite3_open_v2([*:0]const u8, *?*anyopaque, c_int, ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close(?*anyopaque) c_int;
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
fn metadataSpeed(data: []const u8) ?f64 {
    const chat = bytes(data, 1) orelse return null;
    const usage = bytes(chat, 4) orelse return null;
    const duration = bytes(chat, 12) orelse return null;
    const nanos = number(duration, 2);
    if (nanos >= 1_000_000_000) return null;
    const seconds = @as(f64, @floatFromInt(number(duration, 1))) + @as(f64, @floatFromInt(nanos)) / 1e9;
    const output = number(usage, 3);
    if (seconds < 0.1 or output == 0) return null;
    const speed = @as(f64, @floatFromInt(output)) / seconds;
    return if (speed > 0 and speed < 1000) speed else null;
}
fn lastSpeed(allocator: Allocator, id: []const u8) ?f64 {
    if (id.len != 36) return null;
    for (id) |ch| if (!std.ascii.isHex(ch) and ch != '-') { return null; };
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch
        std.process.getEnvVarOwned(allocator, "USERPROFILE") catch return null;
    const path = std.fmt.allocPrintZ(allocator, "{s}/.gemini/antigravity-cli/conversations/{s}.db", .{ home, id }) catch return null;
    var db: ?*anyopaque = null;
    if (sqlite3_open_v2(path, &db, 1, null) != 0) { if (db != null) _ = sqlite3_close(db); return null; }
    defer _ = sqlite3_close(db);
    var stmt: ?*anyopaque = null;
    if (sqlite3_prepare_v2(db, "SELECT data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx DESC LIMIT 1", -1, &stmt, null) != 0) return null;
    defer _ = sqlite3_finalize(stmt);
    if (sqlite3_step(stmt) != 100) return null;
    const ptr = sqlite3_column_blob(stmt, 0) orelse return null;
    const len = sqlite3_column_bytes(stmt, 0);
    if (len <= 0) return null;
    return metadataSpeed(ptr[0..@intCast(len)]);
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
    const input = std.io.getStdIn().reader().readAllAlloc(a, 1024 * 1024) catch "";
    const state = std.json.parseFromSlice(State, a, input, .{ .ignore_unknown_fields = true }) catch null;
    const cw = if (state) |s| s.value.context_window else ContextWindow{};
    const speed = if (state) |s| lastSpeed(a, s.value.conversation_id) else null;
    const quota = if (state) |s| summarizeQuota(s.value.quota) else QuotaSummary{};
    writeQuotaSnapshot(a, if (state) |s| s.value.quota else null);
    const width = if (state) |s| @min(s.value.terminal_width orelse 0, 1000) else 0;
    const color = if (speed != null and speed.? < 50) "\x1b[43;30m" else "\x1b[44;97m";
    const metrics = try renderMetrics(a, cw, speed, color);
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

test "formatting and speed" {
    const a = std.testing.allocator;
    const text = try formatTokens(a, 1_234_567); defer a.free(text);
    try std.testing.expectEqualStrings("1,234K", text);
    const data = [_]u8{0x0a,0x08,0x22,0x02,0x18,0x64,0x62,0x02,0x08,0x02};
    try std.testing.expectEqual(@as(?f64, 50), metadataSpeed(&data));
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
    try std.testing.expectEqual(@as(usize, 102), visibleLen(line));
}
