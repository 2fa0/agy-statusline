const std = @import("std");
const builtin = @import("builtin");
const c = @import("native/common.zig");
const telemetry = @import("native/telemetry.zig");
const A = c.A;
const V = c.V;
const html_bundle = @embedFile("dist/index.html");
const bridge = @embedFile("ui/src/preload.js");
/// Generated from the repository root VERSION file by build.sh.
const version = @embedFile("VERSION");

fn config(a: A, root_override: ?[]const u8, data_override: ?[]const u8) !telemetry.Config {
    const user_home = try c.home(a);
    var root = root_override orelse c.env(a, "AGY_DESKTOP_DATA_DIR") orelse "";
    if (root.len == 0) {
        if (c.env(a, "ANTIGRAVITY_EXECUTABLE_DATA_DIR")) |raw| {
            var dir = raw;
            while (std.fs.path.dirname(dir)) |parent| {
                if (c.eq(std.fs.path.basename(dir), "sidecar_data")) {
                    root = parent;
                    break;
                }
                dir = parent;
            }
        }
    }
    if (root.len == 0) root = try c.join(a, &.{ user_home, ".gemini", "antigravity" });
    return .{
        .root = root,
        .data = data_override orelse c.env(a, "PLUGIN_DATA") orelse try c.join(a, &.{ root, "plugin_data", "agy-desktop-status" }),
        .quota = c.env(a, "AGY_STATUSLINE_QUOTA_FILE") orelse try c.join(a, &.{ user_home, ".gemini", "agy-statusline", "quota.json" }),
    };
}
fn hook(a: A, cfg: telemetry.Config) !void {
    const input = std.io.getStdIn().reader().readAllAlloc(a, 1024 * 1024) catch "";
    const item = c.parse(a, input) catch .null;
    const stop = c.eq(c.str(c.get(item, "hookEventName")), "Stop");
    // Hook errors must never block the agent's lifecycle.
    updateHook(a, cfg, item) catch {};
    try std.io.getStdOut().writeAll(if (stop) "{\"decision\":\"allow\"}" else "{}");
}
fn updateHook(a: A, cfg: telemetry.Config, item: V) !void {
    const id = std.mem.trim(u8, c.str(c.get(item, "conversationId")), " \t\r\n");
    if (!c.validId(id)) return;
    const path = try c.join(a, &.{ cfg.data, "active_session.json" });
    const old = c.readJson(a, path);
    var sessions = c.get(old, "sessions");
    if (sessions != .object) sessions = c.object(a);
    const prev = c.get(sessions, id);
    var next = c.object(a);
    const now = c.s(try c.iso(a, std.time.timestamp()));
    try c.put(a, &next, "conversationId", c.s(id));
    try c.put(a, &next, "updatedAt", now);
    inline for (.{ "modelName", "transcriptPath", "workspacePaths", "cwd", "terminationReason" }) |key| {
        var value = c.get(item, key);
        if (value == .null or (value == .string and value.string.len == 0) or (value == .array and value.array.items.len == 0)) value = c.get(prev, key);
        if (value == .null) value = if (c.eq(key, "workspacePaths")) c.arr(a) else c.s("");
        try c.put(a, &next, key, value);
    }
    inline for (.{ "invocationNum", "executionNum" }) |key| {
        const value = if (item == .object and item.object.contains(key)) c.get(item, key) else c.get(prev, key);
        try c.put(a, &next, key, value);
    }
    const event = c.str(c.get(item, "hookEventName"));
    try c.put(a, &next, "lastEvent", if (event.len > 0) c.s(event) else c.get(prev, "lastEvent"));
    try c.put(a, &sessions, try a.dupe(u8, id), next);
    while (sessions.object.count() > 30) {
        var oldest: ?[]const u8 = null;
        var oldest_at: []const u8 = "";
        for (sessions.object.keys(), sessions.object.values()) |key, value| {
            if (c.eq(key, id)) continue;
            const at = c.str(c.get(value, "updatedAt"));
            if (oldest == null or std.mem.order(u8, at, oldest_at) == .lt) {
                oldest = key;
                oldest_at = at;
            }
        }
        if (oldest) |key| {
            _ = sessions.object.orderedRemove(key);
        } else break;
    }
    var state = c.object(a);
    try c.put(a, &state, "activeConversationId", c.s(id));
    try c.put(a, &state, "updatedAt", now);
    try c.put(a, &state, "sessions", sessions);
    var dest = try std.fs.cwd().atomicFile(path, .{ .make_path = true });
    defer dest.deinit();
    try dest.file.writeAll(try c.json(a, state));
    try dest.finish();
}
fn percentDecode(a: A, input: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    var pos: usize = 0;
    while (pos < input.len) : (pos += 1) {
        if (input[pos] == '%') {
            if (pos + 2 >= input.len) return error.InvalidQuery;
            try out.append(try std.fmt.parseInt(u8, input[pos + 1 .. pos + 3], 16));
            pos += 2;
        } else try out.append(if (input[pos] == '+') ' ' else input[pos]);
    }
    return out.items;
}
fn parameter(a: A, target: []const u8, key: []const u8) !?[]const u8 {
    const start = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    var parts = std.mem.splitScalar(u8, target[start + 1 ..], '&');
    while (parts.next()) |part| {
        const split = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (c.eq(part[0..split], key)) return try percentDecode(a, part[split + 1 ..]);
    }
    return null;
}
fn respond(req: *std.http.Server.Request, body: []const u8, status: std.http.Status, content_type: []const u8) !void {
    try req.respond(body, .{ .status = status, .keep_alive = false, .extra_headers = &.{
        .{ .name = "Content-Type", .value = content_type }, .{ .name = "Cache-Control", .value = "no-store" }, .{ .name = "X-Content-Type-Options", .value = "nosniff" },
    } });
}
fn handle(a: A, req: *std.http.Server.Request, rt: *telemetry.Runtime, cfg: telemetry.Config, token: ?[]const u8, html: []const u8) !void {
    const target = req.head.target;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    if (req.head.method != .GET and req.head.method != .HEAD) return respond(req, "{\"error\":\"method not allowed\"}", .method_not_allowed, "application/json");
    if (c.eq(path, "/")) {
        // The host authenticates and proxies the HTML request. Its token is then
        // carried by the frontend bridge; it is never serialized into our HTML.
        return respond(req, html, .ok, "text/html; charset=utf-8");
    }
    if (c.eq(path, "/preload.js")) return respond(req, bridge, .ok, "application/javascript; charset=utf-8");
    if (!c.eq(path, "/api/status")) return respond(req, "{\"error\":\"not found\"}", .not_found, "application/json");
    if (token) |expected| {
        var supplied: ?[]const u8 = parameter(a, target, "token") catch return respond(req, "{\"error\":\"invalid query\"}", .bad_request, "application/json");
        var headers = req.iterateHeaders();
        while (headers.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "x-sidecar-token")) supplied = h.value;
        }
        if (expected.len > 0 and (supplied == null or !c.eq(expected, supplied.?))) return respond(req, "{\"error\":\"unauthorized\"}", .unauthorized, "application/json");
    }
    const id = (parameter(a, target, "conversationId") catch return respond(req, "{\"error\":\"invalid query\"}", .bad_request, "application/json")) orelse "auto";
    const value = telemetry.snapshot(a, rt, cfg, id) catch return respond(req, "{\"error\":\"telemetry unavailable\"}", .internal_server_error, "application/json");
    return respond(req, try c.json(a, value), .ok, "application/json; charset=utf-8");
}
fn socketTimeout(stream: std.net.Stream) void {
    if (builtin.os.tag == .windows) {
        const ms: u32 = 3000;
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&ms)) catch {};
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&ms)) catch {};
    } else {
        const tv: std.posix.timeval = .{ .sec = 3, .usec = 0 };
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }
}
fn serve(a: A, cfg: telemetry.Config, port_arg: ?u16) !void {
    if (builtin.os.tag != .windows) {
        // Prevent client disconnects during HTTP writes from killing the sidecar.
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.empty_sigset,
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
    }
    const port = port_arg orelse try std.fmt.parseInt(u16, c.env(a, "ANTIGRAVITY_SIDECAR_WEB_PORT") orelse return error.MissingSidecarPort, 10);
    const token = c.env(a, "ANTIGRAVITY_SIDECAR_UI_TOKEN");
    var html: []const u8 = html_bundle;
    if (c.env(a, "AGY_DESKTOP_STATUS_HTML")) |path| html = try std.fs.cwd().readFileAlloc(a, path, 2 * 1024 * 1024);
    if (std.mem.indexOf(u8, html, "/preload.js") == null) {
        const head = std.mem.indexOf(u8, html, "</head>") orelse 0;
        html = try c.fmt(a, "{s}<script src=\"/preload.js\"></script>{s}", .{ html[0..head], html[head..] });
    }
    var server = try (try std.net.Address.parseIp4("127.0.0.1", port)).listen(.{ .reuse_address = true });
    defer server.deinit();
    var runtime: telemetry.Runtime = .{};
    defer runtime.deinit();
    std.debug.print("AGY Status listening on 127.0.0.1:{d}\n", .{server.listen_address.getPort()});
    while (true) {
        const conn = server.accept() catch continue;
        defer conn.stream.close();
        socketTimeout(conn.stream);
        var buffer: [16384]u8 = undefined;
        var http = std.http.Server.init(conn, &buffer);
        var req = http.receiveHead() catch continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        handle(arena.allocator(), &req, &runtime, cfg, token, html) catch {};
    }
}
fn jsonLines(cfg: telemetry.Config) !void {
    var runtime: telemetry.Runtime = .{};
    defer runtime.deinit();
    var buffered = std.io.bufferedReader(std.io.getStdIn().reader());
    var line = std.ArrayList(u8).init(std.heap.c_allocator);
    defer line.deinit();
    while (true) {
        buffered.reader().readUntilDelimiterArrayList(&line, '\n', 1024 * 1024) catch |err| {
            if (err == error.EndOfStream) break;
            return err;
        };
        if (std.mem.trim(u8, line.items, " \t\r").len == 0) continue;
        var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const req = c.parse(a, line.items) catch .null;
        if (c.eq(c.str(c.get(req, "op")), "close")) break;
        const snap = telemetry.snapshot(a, &runtime, cfg, c.str(c.get(req, "conversationId"))) catch blk: {
            var failed = c.object(a);
            try c.put(a, &failed, "error", c.s("telemetry unavailable"));
            break :blk failed;
        };
        try std.io.getStdOut().writeAll(try c.json(a, snap));
        try std.io.getStdOut().writeAll("\n");
    }
}
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    // Keep this ahead of everything else: installers probe it to detect a
    // Gatekeeper denial (SIGKILL, no stdout) before trusting the binary.
    for (args[1..]) |arg| {
        if (c.eq(arg, "--version") or c.eq(arg, "-V")) {
            try std.io.getStdOut().writeAll("agy-desktop-backend " ++ version ++ "\n");
            return;
        }
    }
    var mode: enum { http, status, hook, lines } = .http;
    var root: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var id: []const u8 = "auto";
    var port: ?u16 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (c.eq(arg, "hook")) {
            mode = .hook;
            continue;
        }
        if (c.eq(arg, "status")) {
            mode = .status;
            continue;
        }
        if (c.eq(arg, "--serve")) {
            mode = .lines;
            continue;
        }
        if (c.eq(arg, "serve")) continue;
        if (i + 1 >= args.len) return error.InvalidArguments;
        i += 1;
        if (c.eq(arg, "--desktop-root")) root = args[i] else if (c.eq(arg, "--data-dir")) data = args[i] else if (c.eq(arg, "--conversation-id")) {
            id = args[i];
            if (mode == .http) mode = .status;
        } else if (c.eq(arg, "--port")) port = try std.fmt.parseInt(u16, args[i], 10) else return error.InvalidArguments;
    }
    const cfg = try config(a, root, data);
    switch (mode) {
        .hook => try hook(a, cfg),
        .http => try serve(a, cfg, port),
        .lines => try jsonLines(cfg),
        .status => {
            var runtime: telemetry.Runtime = .{};
            defer runtime.deinit();
            try std.io.getStdOut().writeAll(try c.json(a, try telemetry.snapshot(a, &runtime, cfg, id)));
            try std.io.getStdOut().writeAll("\n");
        },
    }
}
