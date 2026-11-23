import AppKit
import Foundation

func mockBackend(at directory: URL, snapshot: [String: Any]) throws -> String {
    let path = directory.appendingPathComponent(UUID().uuidString)
    let json = String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)!
    let quoted = json.replacingOccurrences(of: "'", with: "'\\''")
    let script = """
    #!/bin/sh
    if [ "$1" = "status-brief" ]; then
      printf '%s\\n' '\(quoted)'
      exit 0
    fi
    while IFS= read -r line; do
      printf '%s\\n' '\(quoted)'
    done
    """
    try script.write(to: path, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    return path.path
}

MainActor.assumeIsolated {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    for terminal in ["idle", "error"] {
        let parsed = NotchStore.parseStateAndSpeed(from: [
            "live": ["active": true],
            "session": ["state": terminal, "label": "已取消", "code": "user_cancelled"]
        ])
        assert(!parsed.isActive)
        assert(parsed.state == (terminal == "idle" ? .idle : .error))
    }
    assert(NotchStore.formatQuota(["windows": [["pool": "gemini", "window": "5h", "remainingPct": 82.0]]]) == "gemini 5h 82%")

    let log = tmp.appendingPathComponent("custom-transcript.jsonl")
    try! """
    {"type":"USER_INPUT","content":"custom title"}
    {"type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command","arguments":{"CommandLine":"echo hello"}}]}

    """.write(to: log, atomically: true, encoding: .utf8)
    let tail = NotchStore.parseTranscriptTail(path: log.path)
    assert(tail.title == "custom title" && tail.command == "$ echo hello")

    let utf8BoundaryLog = tmp.appendingPathComponent("utf8-boundary.jsonl")
    let padding = String(repeating: "中", count: 12000)
    try! """
    {"type":"USER_INPUT","content":"边界标题"}
    {"type":"PLANNER_RESPONSE","content":"\(padding)"}
    {"type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command","arguments":{"CommandLine":"git status"}}]}

    """.write(to: utf8BoundaryLog, atomically: true, encoding: .utf8)
    let boundaryTail = NotchStore.parseTranscriptTail(path: utf8BoundaryLog.path)
    assert(boundaryTail.title == "边界标题" && boundaryTail.command == "$ git status")

    let badPath = try! mockBackend(at: tmp, snapshot: ["error": "telemetry unavailable"])
    let badClient = BackendLinesClient(backendPath: badPath, dataDir: tmp.path)
    assert(badClient.request(conversationId: "auto") == nil)
    assert(NotchStore.fetchSnapshot(client: badClient, backendPath: badPath, previouslyActiveIds: []) == nil)
    badClient.close()

    let failedPath = try! mockBackend(at: tmp, snapshot: [
        "found": true, "conversationId": "task", "transcriptPath": log.path,
        "session": ["state": "error", "label": "执行异常", "code": "terminated_error"],
        "config": ["lowSpeedWarnTokS": 80.0]
    ])
    let failedClient = BackendLinesClient(backendPath: failedPath, dataDir: tmp.path)
    let failed = NotchStore.fetchSnapshot(client: failedClient, backendPath: failedPath, previouslyActiveIds: [])!
    assert(failed.recentTasks[0].stateLabel == "执行异常")
    assert(failed.recentTasks[0].code == "terminated_error")
    assert(failed.title == "custom title" && failed.lowSpeedThreshold == 80)
    failedClient.close()

    let store = NotchStore(backendPath: "/nonexistent", dataDir: tmp.path, demoMode: true)
    var task = ActiveTaskItem(id: "task", title: "test", commandText: "", modelName: "model-b",
                              workspaceName: "", state: .running, stateLabel: "生成中",
                              tokPerSec: nil, contextPct: nil, code: "streaming")
    @MainActor func applyTask() {
        var next = NotchSnapshot()
        next.conversationId = task.id
        next.activeTasks = task.isRunning ? [task] : []
        next.recentTasks = [task]
        next.isActive = task.isRunning
        store.applyFetchedSnapshot(next)
    }
    applyTask()
    task.state = .waiting; task.stateLabel = "输出停滞"; task.code = "stalled"
    applyTask()
    assert(store.activePeek?.statusText == "输出停滞")
    store.activePeek = nil
    task.state = .idle; task.stateLabel = "已取消"; task.code = "user_cancelled"; task.isRunning = false
    applyTask()
    assert(store.activePeek == nil)
    task.state = .running; task.isRunning = true; task.code = "streaming"
    applyTask()
    task.state = .idle; task.isRunning = false; task.code = "idle"
    applyTask()
    assert(store.activePeek?.statusText == "✓ 已完成")
    store.shutdown()
    print("macOS notch regressions passed")
}
