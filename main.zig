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
const State = struct { terminal_width: ?usize = null, conversation_id: []const u8 = "", context_window: struct { current_usage: ?Usage = null } = .{} };

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
fn render(allocator: Allocator, usage: ?Usage, speed: ?f64) ![]const u8 {
    const speed_text = if (speed) |s| try std.fmt.allocPrint(allocator, "Last avg speed: {d:.0} token/s", .{s}) else "Last avg speed: --";
    const color = if (speed != null and speed.? < 50) "\x1b[43;30m" else "\x1b[44;97m";
    if (usage) |u| {
        if (u.input_tokens != null and u.cache_read_input_tokens != null and u.cache_creation_input_tokens != null) {
            const input = u.input_tokens.?; const read = u.cache_read_input_tokens.?;
            if (input >= 0 and read >= 0 and u.cache_creation_input_tokens.? == 0) {
                const total = @as(f64, @floatFromInt(input)) + @as(f64, @floatFromInt(read));
                if (total > 0) return std.fmt.allocPrint(allocator, "{s}Cache hit: {d:.1}% | Cache read: {s} | {s}\x1b[0m\n", .{color, 100 * @as(f64, @floatFromInt(read)) / total, try formatTokens(allocator, read), speed_text});
            }
        }
    }
    return std.fmt.allocPrint(allocator, "{s}Cache hit: -- | {s}\x1b[0m\n", .{color, speed_text});
}
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator); defer arena.deinit();
    const a = arena.allocator();
    const input = std.io.getStdIn().reader().readAllAlloc(a, 1024 * 1024) catch "";
    const state = std.json.parseFromSlice(State, a, input, .{ .ignore_unknown_fields = true }) catch null;
    const u = if (state) |s| s.value.context_window.current_usage else null;
    const speed = if (state) |s| lastSpeed(a, s.value.conversation_id) else null;
    const line = try render(a, u, speed);
    const width = if (state) |s| @min(s.value.terminal_width orelse 0, 1000) else 0;
    const visible_len = line.len - "\x1b[44;97m".len - "\x1b[0m\n".len;
    const padding = width -| visible_len;
    const writer = std.io.getStdOut().writer();
    try writer.writeAll(line[0 .. line.len - "\x1b[0m\n".len]);
    try writer.writeByteNTimes(' ', padding);
    try writer.writeAll("\x1b[0m\n");
}

test "formatting and speed" {
    const a = std.testing.allocator;
    const text = try formatTokens(a, 1_234_567); defer a.free(text);
    try std.testing.expectEqualStrings("1,234K", text);
    const data = [_]u8{0x0a,0x08,0x22,0x02,0x18,0x64,0x62,0x02,0x08,0x02};
    try std.testing.expectEqual(@as(?f64, 50), metadataSpeed(&data));
    try std.testing.expectEqual(@as(?f64, null), metadataSpeed(&.{0x0a,0xff}));
    const line = try render(a, .{ .input_tokens = 200, .cache_read_input_tokens = 800, .cache_creation_input_tokens = 0 }, 12.6); defer a.free(line);
    try std.testing.expectEqualStrings("\x1b[43;30mCache hit: 80.0% | Cache read: 800 | Last avg speed: 13 token/s\x1b[0m\n", line);
}
