const std = @import("std");
const c = @import("common.zig");
const A = c.A;
const V = c.V;

/// Four-state session indicator.
///
/// The states are deliberately few and the reasons are explicit: a chip that
/// only changes colour tells the user nothing when a turn hangs. Every state
/// therefore carries a stable `Code` plus a human sentence explaining what the
/// process is actually doing right now.
pub const State = enum { idle, running, waiting, failed };

pub const Code = enum {
    idle,
    hook_missing,
    preparing,
    streaming,
    tool_step,
    first_token_wait,
    model_switch_prefill,
    stalled,
    terminated_error,
    user_cancelled,
    evidence_missing,
};

pub const Limits = struct {
    /// A first byte that has not arrived by now is worth explaining, not just
    /// showing as a spinner.
    wait_sec: f64 = 20,
    /// Streaming that stopped growing for this long is reported as stalled
    /// instead of silently redrawing the same number.
    stall_sec: f64 = 25,
    /// How long a terminating turn keeps its error/cancel chip.
    stop_ttl_sec: f64 = 180,
    /// PostInvocation without a following PreInvocation usually means local
    /// tool work; after this window the turn is treated as finished.
    tool_grace_sec: f64 = 120,
    /// A PreInvocation older than this is history, not a live wait.
    hook_ttl_sec: f64 = 900,
};

pub const Input = struct {
    now: f64,
    hook_event: []const u8 = "",
    hook_age_sec: ?f64 = null,
    hook_connected: bool = false,
    live: bool = false,
    live_status: ?i64 = null,
    /// Seconds since the streamed character count last increased.
    chars_idle_sec: ?f64 = null,
    model: []const u8 = "",
    prev_model: []const u8 = "",
    termination: []const u8 = "",
    /// Whether "there is no active step" is a trustworthy observation. A locked
    /// or unreadable database must not be read as "the model has not started".
    evidence_trusted: bool = true,
};

pub const Outcome = struct {
    state: State = .idle,
    code: Code = .idle,
    wait_sec: ?f64 = null,
};

/// User cancellations are not failures. Agents cancel turns constantly, and a
/// red light after every cancel trains people to ignore the light entirely.
pub fn isUserCancel(raw: []const u8) bool {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0) return false;
    var buf: [64]u8 = undefined;
    const len = @min(text.len, buf.len);
    for (text[0..len], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const lower = buf[0..len];
    if (c.eq(lower, "canceled") or c.eq(lower, "cancelled") or c.eq(lower, "aborted")) return true;
    if (std.mem.indexOf(u8, lower, "cancel") != null) return true;
    if (std.mem.indexOf(u8, lower, "abort") != null) return true;
    if (std.mem.indexOf(u8, lower, "interrupt") != null) return true;
    return false;
}

/// Normal Stop termination reasons reported by hooks when a turn finishes
/// cleanly (e.g. `NO_TOOL_CALL`), which must not be surfaced as failures.
pub fn isNormalTermination(raw: []const u8) bool {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len == 0 or text.len > 64) return false;
    var buf: [64]u8 = undefined;
    for (text, 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    const lower = buf[0..text.len];
    const normals = [_][]const u8{
        "no_tool_call",
        "end_turn",
        "stop",
        "completed",
        "complete",
        "done",
        "success",
        "normal",
        "finished",
        "no_error",
    };
    for (normals) |item| {
        if (c.eq(lower, item)) return true;
    }
    return false;
}

pub fn evaluate(input: Input, limits: Limits) Outcome {
    // Allow tiny negative clock skew / sub-millisecond write races without
    // treating corrupted far-future timestamps as "just happened".
    const age = if (input.hook_age_sec) |value| (if (std.math.isFinite(value) and value >= -5) @max(0, value) else null) else null;
    const recent_stop = c.eq(input.hook_event, "Stop") and age != null and age.? <= limits.stop_ttl_sec;
    if (recent_stop and input.termination.len > 0) {
        if (isUserCancel(input.termination)) return .{ .state = .idle, .code = .user_cancelled, .wait_sec = age };
        if (isNormalTermination(input.termination)) return .{ .state = .idle, .code = .idle };
        return .{ .state = .failed, .code = .terminated_error, .wait_sec = age };
    }
    if (input.live) {
        if (input.chars_idle_sec) |idle| {
            if (idle >= limits.stall_sec) return .{ .state = .waiting, .code = .stalled, .wait_sec = idle };
        }
        return .{ .state = .running, .code = .streaming, .wait_sec = input.chars_idle_sec };
    }
    if (c.eq(input.hook_event, "PreInvocation") and age != null and age.? <= limits.hook_ttl_sec) {
        const elapsed = age.?;
        const switched = input.model.len > 0 and input.prev_model.len > 0 and
            !c.eq(c.modelKey(input.model), c.modelKey(input.prev_model));
        // A model switch mid-conversation invalidates the KV cache, so the wait
        // before the first byte is expected to be long. Say so instead of
        // letting the user conclude the agent is broken.
        if (switched) return .{ .state = if (elapsed >= limits.wait_sec) .waiting else .running, .code = .model_switch_prefill, .wait_sec = elapsed };
        if (elapsed >= limits.wait_sec) {
            if (input.evidence_trusted) return .{ .state = .waiting, .code = .first_token_wait, .wait_sec = elapsed };
            // Without a readable conversation database we cannot tell a slow
            // first token from a turn that simply ended. Say that instead of
            // guessing in either direction.
            if (elapsed >= limits.tool_grace_sec) return .{ .state = .idle, .code = .evidence_missing, .wait_sec = elapsed };
        }
        return .{ .state = .running, .code = .preparing, .wait_sec = elapsed };
    }
    if (c.eq(input.hook_event, "PostInvocation") and age != null and age.? <= limits.tool_grace_sec) {
        return .{ .state = .running, .code = .tool_step, .wait_sec = age };
    }
    if (!input.hook_connected) return .{ .state = .idle, .code = .hook_missing };
    return .{ .state = .idle, .code = .idle };
}

pub fn stateName(state: State) []const u8 {
    return switch (state) {
        .idle => "idle",
        .running => "running",
        .waiting => "waiting",
        .failed => "error",
    };
}

pub fn codeName(code: Code) []const u8 {
    return switch (code) {
        .idle => "idle",
        .hook_missing => "hook_missing",
        .preparing => "preparing",
        .streaming => "streaming",
        .tool_step => "tool_step",
        .first_token_wait => "first_token_wait",
        .model_switch_prefill => "model_switch_prefill",
        .stalled => "stalled",
        .terminated_error => "terminated_error",
        .user_cancelled => "user_cancelled",
        .evidence_missing => "evidence_missing",
    };
}

pub fn shortLabel(out: Outcome) []const u8 {
    return switch (out.code) {
        .idle => "就绪",
        .hook_missing => "无 Hook",
        .preparing => "准备中",
        .streaming => "生成中",
        .tool_step => "工具执行",
        .first_token_wait => "首字等待",
        .model_switch_prefill => "切换模型",
        .stalled => "输出停滞",
        .terminated_error => "执行异常",
        .user_cancelled => "已取消",
        .evidence_missing => "无法确认",
    };
}

/// `34s`, `1m20s`, `2h05m` — compact enough for a chip.
pub fn durationText(a: A, seconds: ?f64) ![]const u8 {
    const raw = seconds orelse return "";
    if (!std.math.isFinite(raw) or raw < 0) return "";
    if (raw > 1e9) return "很久";
    const total: i64 = @intFromFloat(@floor(raw));
    if (total < 60) return try c.fmt(a, "{d}s", .{total});
    const minutes: u64 = @intCast(@divFloor(total, 60));
    const secs: u64 = @intCast(@mod(total, 60));
    if (minutes < 60) {
        if (secs == 0) return try c.fmt(a, "{d}m", .{minutes});
        return try c.fmt(a, "{d}m{d:0>2}s", .{ minutes, secs });
    }
    return try c.fmt(a, "{d}h{d:0>2}m", .{ minutes / 60, minutes % 60 });
}

/// Byte-bounded but never splits a UTF-8 sequence: a half character would make
/// the whole snapshot fail to serialise.
fn truncate(raw: []const u8, limit: usize) []const u8 {
    const text = std.mem.trim(u8, raw, " \t\r\n");
    if (text.len <= limit) return text;
    var end = limit;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    return text[0..end];
}

/// The sentence behind the chip. Kept next to the state machine so a new code
/// cannot ship without an explanation.
fn explain(a: A, input: Input, out: Outcome) ![]const u8 {
    const wait = try durationText(a, out.wait_sec);
    return switch (out.code) {
        .idle => "会话空闲，等待下一条输入。",
        .hook_missing => "尚未收到 Hook 事件，正在展示最近一次会话；新开一轮后会自动跟上。",
        .preparing => try c.fmt(a, "本轮已触发，模型尚未开始输出（{s}）。", .{if (wait.len > 0) wait else "刚刚"}),
        .streaming => "模型正在流式输出，速度与字数为实时估算。",
        .tool_step => try c.fmt(a, "本步调用的工具正在本地执行（{s}），结果返回后继续。", .{if (wait.len > 0) wait else "刚开始"}),
        .first_token_wait => try c.fmt(a, "已等待模型首字 {s}：长上下文预填充或服务端排队时常见，连接仍然有效。", .{wait}),
        .model_switch_prefill => try c.fmt(a, "模型已切换为 {s}（上一步为 {s}），首字前需要重算上下文缓存，等待时间变长属正常现象；下次可在压缩后再切换模型。", .{
            truncate(input.model, 60),
            truncate(input.prev_model, 60),
        }),
        .stalled => try c.fmt(a, "流式输出已 {s} 没有新增内容，可能是网络卡顿、服务端排队或本步即将结束。", .{wait}),
        .terminated_error => if (input.termination.len > 0)
            try c.fmt(a, "本轮异常结束（{s}），不计入执行中。", .{truncate(input.termination, 80)})
        else
            "本轮异常结束，不计入执行中。",
        .user_cancelled => "你主动取消了本轮生成，这不是错误。",
        .evidence_missing => try c.fmt(a, "本轮事件已过去 {s}，但会话数据库暂不可读，无法确认是否仍在生成。", .{wait}),
    };
}

pub fn toValue(a: A, input: Input, out: Outcome, show_evidence: bool) !V {
    var value = c.object(a);
    try c.put(a, &value, "state", c.s(stateName(out.state)));
    try c.put(a, &value, "code", c.s(codeName(out.code)));
    try c.put(a, &value, "label", c.s(shortLabel(out)));
    try c.put(a, &value, "detail", c.s(try explain(a, input, out)));
    try c.put(a, &value, "waitSec", c.rounded(out.wait_sec, 10));
    try c.put(a, &value, "sinceEvent", c.s(input.hook_event));
    if (show_evidence) {
        var evidence = c.object(a);
        try c.put(a, &evidence, "hookConnected", c.b(input.hook_connected));
        try c.put(a, &evidence, "hookEvent", c.s(input.hook_event));
        try c.put(a, &evidence, "hookAgeSec", c.rounded(input.hook_age_sec, 10));
        try c.put(a, &evidence, "liveStep", c.b(input.live));
        try c.put(a, &evidence, "liveStatus", c.opt(input.live_status));
        try c.put(a, &evidence, "charsIdleSec", c.rounded(input.chars_idle_sec, 10));
        try c.put(a, &evidence, "model", c.s(input.model));
        try c.put(a, &evidence, "prevModel", c.s(input.prev_model));
        try c.put(a, &evidence, "termination", c.s(truncate(input.termination, 80)));
        try c.put(a, &evidence, "evidenceTrusted", c.b(input.evidence_trusted));
        try c.put(a, &value, "evidence", evidence);
    }
    return value;
}
