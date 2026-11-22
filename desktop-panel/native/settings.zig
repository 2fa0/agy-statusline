const std = @import("std");
const c = @import("common.zig");
const A = c.A;
const V = c.V;
const session = @import("session.zig");

pub const Layout = enum { compact, detailed };

/// User-facing settings, hot-reloaded.
///
/// Everything here is a value type on purpose: the resolved struct is cached
/// against the file signature so a 1 Hz poll costs one `stat` instead of a
/// re-parse, and nothing has to be freed between reloads.
pub const Settings = struct {
    enabled: bool = true,
    layout: Layout = .compact,
    /// 0 keeps the panel's own adaptive default.
    poll_sec: u32 = 0,
    low_speed: f64 = 50,
    limits: session.Limits = .{},
    debug: bool = false,
    session: bool = true,
    quota: bool = true,
    history: bool = true,
    models: bool = true,
    context: bool = true,
};

fn boolean(v: V, fallback: bool) bool {
    return switch (v) {
        .bool => |value| value,
        else => fallback,
    };
}

fn number(v: V, fallback: f64) f64 {
    const raw = c.num(v) orelse return fallback;
    return if (std.math.isFinite(raw)) raw else fallback;
}

fn clamp(raw: f64, low: f64, high: f64) f64 {
    return std.math.clamp(raw, low, high);
}

pub fn fromJson(raw: V) Settings {
    var out: Settings = .{};
    if (raw != .object) return out;
    out.enabled = boolean(c.get(raw, "enabled"), out.enabled);
    out.layout = if (c.eq(c.str(c.get(raw, "layout")), "detailed")) .detailed else .compact;
    const poll = number(c.get(raw, "pollSec"), 0);
    out.poll_sec = if (poll <= 0) 0 else @as(u32, @intFromFloat(clamp(@round(poll), 1, 60)));
    out.low_speed = clamp(number(c.get(raw, "lowSpeedWarnTokS"), out.low_speed), 1, 10000);
    out.debug = boolean(c.get(raw, "debug"), out.debug);

    const thresholds = c.get(raw, "thresholds");
    out.limits.wait_sec = clamp(number(c.get(thresholds, "waitSec"), out.limits.wait_sec), 1, 3600);
    out.limits.stall_sec = clamp(number(c.get(thresholds, "stallSec"), out.limits.stall_sec), 1, 3600);
    out.limits.tool_grace_sec = clamp(number(c.get(thresholds, "toolGraceSec"), out.limits.tool_grace_sec), 1, 3600);

    const modules = c.get(raw, "modules");
    out.session = boolean(c.get(modules, "session"), out.session);
    out.quota = boolean(c.get(modules, "quota"), out.quota);
    out.history = boolean(c.get(modules, "history"), out.history);
    out.models = boolean(c.get(modules, "models"), out.models);
    out.context = boolean(c.get(modules, "context"), out.context);
    return out;
}

/// Echoed in every snapshot so the UI can honour module switches and the
/// layout without a second request or a restart.
pub fn toValue(a: A, settings: Settings) !V {
    var out = c.object(a);
    try c.put(a, &out, "enabled", c.b(settings.enabled));
    try c.put(a, &out, "layout", c.s(if (settings.layout == .detailed) "detailed" else "compact"));
    try c.put(a, &out, "pollSec", c.n(settings.poll_sec));
    try c.put(a, &out, "lowSpeedWarnTokS", c.f(settings.low_speed));
    try c.put(a, &out, "waitSec", c.f(settings.limits.wait_sec));
    try c.put(a, &out, "stallSec", c.f(settings.limits.stall_sec));
    var modules = c.object(a);
    try c.put(a, &modules, "session", c.b(settings.session));
    try c.put(a, &modules, "quota", c.b(settings.quota));
    try c.put(a, &modules, "history", c.b(settings.history));
    try c.put(a, &modules, "models", c.b(settings.models));
    try c.put(a, &modules, "context", c.b(settings.context));
    try c.put(a, &out, "modules", modules);
    return out;
}

/// Path of the hot-reloaded config file next to the rest of the tool's state.
pub fn defaultPath(a: A) ![]const u8 {
    const home = try c.home(a);
    return c.join(a, &.{ home, ".gemini", "agy-statusline", "config.json" });
}
