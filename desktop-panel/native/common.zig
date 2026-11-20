const std = @import("std");
pub const A = std.mem.Allocator;
pub const V = std.json.Value;
pub fn eq(left: []const u8, right: []const u8) bool {
    return std.mem.eql(u8, left, right);
}
pub fn get(v: V, key: []const u8) V {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
pub fn str(v: V) []const u8 {
    return if (v == .string) v.string else "";
}
pub fn int(v: V) ?i64 {
    return if (v == .integer) v.integer else null;
}
pub fn num(v: V) ?f64 {
    return switch (v) {
        .integer => |val| @floatFromInt(val),
        .float => |val| if (std.math.isFinite(val)) val else null,
        else => null,
    };
}
pub fn tokens(v: V) ?i64 {
    const val = int(v) orelse return null;
    return if (val >= 0 and val <= 9_007_199_254_740_991) val else null;
}
pub fn s(v: []const u8) V {
    return .{ .string = v };
}
pub fn n(v: anytype) V {
    return .{ .integer = @intCast(v) };
}
pub fn b(v: bool) V {
    return .{ .bool = v };
}
pub fn f(v: f64) V {
    return if (std.math.isFinite(v)) .{ .float = v } else .null;
}
pub fn opt(v: ?i64) V {
    return if (v) |x| n(x) else .null;
}
pub fn rounded(v: ?f64, places: f64) V {
    return if (v) |x| f(@round(x * places) / places) else .null;
}
pub fn arr(a: A) V {
    return .{ .array = std.ArrayList(V).init(a) };
}
pub fn put(_: A, v: *V, k: []const u8, value: V) !void {
    try v.object.put(k, value);
}
pub fn add(v: *V, value: V) !void {
    try v.array.append(value);
}
pub fn object(a: A) V {
    return .{ .object = std.json.ObjectMap.init(a) };
}
pub fn parse(a: A, raw: []const u8) !V {
    return (try std.json.parseFromSlice(V, a, raw, .{ .allocate = .alloc_always, .ignore_unknown_fields = true })).value;
}
pub fn readJson(a: A, path: []const u8) V {
    const raw = std.fs.cwd().readFileAlloc(a, path, 2 * 1024 * 1024) catch return .null;
    return parse(a, raw) catch .null;
}
pub fn json(a: A, value: anytype) ![]const u8 {
    return std.json.stringifyAlloc(a, value, .{});
}
pub fn env(a: A, name: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(a, name) catch null;
}
pub fn home(a: A) ![]const u8 {
    return env(a, "HOME") orelse env(a, "USERPROFILE") orelse error.NoHomeDirectory;
}
pub fn join(a: A, parts: []const []const u8) ![]const u8 {
    return std.fs.path.join(a, parts);
}
pub fn fmt(a: A, comptime format: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(a, format, args);
}
pub fn validId(id: []const u8) bool {
    if (id.len != 36) return false;
    for (id) |ch| if (!std.ascii.isHex(ch) and ch != '-') return false;
    return true;
}
pub fn modelKey(name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) return "未知模型";
    inline for (.{ "-minimal", "-low", "-medium", "-high", "-max" }) |suffix| {
        if (std.mem.endsWith(u8, trimmed, suffix)) return trimmed[0 .. trimmed.len - suffix.len];
    }
    return trimmed;
}
pub const Sig = struct { inode: std.fs.File.INode = 0, size: u64 = 0, mtime: i128 = 0, ctime: i128 = 0, exists: bool = false };
pub fn sig(path: []const u8) Sig {
    const st = std.fs.cwd().statFile(path) catch return .{};
    return .{ .inode = st.inode, .size = st.size, .mtime = st.mtime, .ctime = st.ctime, .exists = true };
}
pub fn iso(a: A, seconds: i64) ![]const u8 {
    if (seconds < 0 or seconds > 253402300799) return error.InvalidTimestamp;
    const ep = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const yd = ep.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = ep.getDaySeconds();
    return fmt(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00", .{ yd.year, @intFromEnum(md.month), @as(u8, md.day_index) + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute() });
}
pub fn isoValue(a: A, seconds: ?i64) !V {
    return if (seconds) |x| s(iso(a, x) catch return .null) else .null;
}
pub fn timestamp(raw: []const u8) ?f64 {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len < 19) return null;
    if (text[4] != '-' or text[7] != '-' or (text[10] != 'T' and text[10] != ' ') or text[13] != ':' or text[16] != ':') return null;
    const year = std.fmt.parseInt(u16, text[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, text[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, text[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, text[17..19], 10) catch return null;
    if (year < 1970 or month < 1 or month > 12 or day < 1 or hour > 23 or minute > 59 or second > 59) return null;
    const ep = std.time.epoch;
    const mon: ep.Month = @enumFromInt(month);
    if (day > ep.getDaysInMonth(if (ep.isLeapYear(year)) .leap else .not_leap, mon)) return null;
    var days: i64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) days += ep.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += ep.getDaysInMonth(if (ep.isLeapYear(year)) .leap else .not_leap, @enumFromInt(m));
    days += day - 1;
    var result: f64 = @floatFromInt(days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second);
    var pos: usize = 19;
    if (pos < text.len and text[pos] == '.') {
        const start = pos;
        pos += 1;
        while (pos < text.len and std.ascii.isDigit(text[pos])) : (pos += 1) {}
        result += std.fmt.parseFloat(f64, text[start..pos]) catch return null;
    }
    if (pos < text.len and (text[pos] == '+' or text[pos] == '-')) {
        if (text.len - pos != 6 or text[pos + 3] != ':') return null;
        const h = std.fmt.parseInt(u8, text[pos + 1 .. pos + 3], 10) catch return null;
        const min = std.fmt.parseInt(u8, text[pos + 4 .. pos + 6], 10) catch return null;
        if (h > 23 or min > 59) return null;
        const offset: f64 = @floatFromInt(@as(i64, h) * 3600 + @as(i64, min) * 60);
        result += if (text[pos] == '+') -offset else offset;
    } else if (pos != text.len and !eq(text[pos..], "Z")) return null;
    return result;
}
pub const Field = union(enum) { number: u64, bytes: []const u8 };
fn varint(data: []const u8, pos: *usize) ?u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    for (0..10) |_| {
        if (pos.* >= data.len) return null;
        const byte = data[pos.*];
        pos.* += 1;
        if (shift == 63 and byte > 1) return null;
        value |= @as(u64, byte & 127) << shift;
        if (byte & 128 == 0) return value;
        if (shift == 63) return null;
        shift += 7;
    }
    return null;
}
pub fn field(data: []const u8, wanted: u64) ?Field {
    var pos: usize = 0;
    var result: ?Field = null;
    while (pos < data.len) {
        const key = varint(data, &pos) orelse break;
        if (key >> 3 == 0) break;
        const value: Field = switch (key & 7) {
            0 => .{ .number = varint(data, &pos) orelse break },
            2 => blk: {
                const size = varint(data, &pos) orelse break;
                if (size > data.len - pos) break;
                const chunk = data[pos..][0..@intCast(size)];
                pos += @intCast(size);
                break :blk .{ .bytes = chunk };
            },
            1, 5 => blk: {
                const size: usize = if (key & 7 == 1) 8 else 4;
                if (size > data.len - pos) break;
                pos += size;
                break :blk .{ .number = 0 };
            },
            else => break,
        };
        if (key >> 3 == wanted) result = value;
    }
    return result;
}
pub fn bytes(data: []const u8, key: u64) ?[]const u8 {
    const x = field(data, key) orelse return null;
    return if (x == .bytes) x.bytes else null;
}
pub fn number(data: []const u8, key: u64) ?i64 {
    const x = field(data, key) orelse return null;
    return if (x == .number and x.number <= std.math.maxInt(i64)) @intCast(x.number) else null;
}
pub fn duration(data: ?[]const u8) ?f64 {
    const raw = data orelse return null;
    if (raw.len == 0) return null;
    const sec = number(raw, 1) orelse 0;
    const nano = number(raw, 2) orelse 0;
    if (nano >= 1_000_000_000) return null;
    return @as(f64, @floatFromInt(sec)) + @as(f64, @floatFromInt(nano)) / 1e9;
}
pub fn chars(data: []const u8) ?i64 {
    const msg = bytes(data, 20) orelse return null;
    const text = bytes(msg, 1) orelse return null;
    var count: i64 = 0;
    var pos: usize = 0;
    while (pos < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch {
            pos += 1;
            continue;
        };
        if (pos + len <= text.len) {
            _ = std.unicode.utf8Decode(text[pos..][0..len]) catch {
                pos += 1;
                continue;
            };
            count += 1;
            pos += len;
        } else break;
    }
    return count;
}
