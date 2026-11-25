import AppKit
import Foundation

func mockBackend(at directory: URL, snapshot: [String: Any], requestLog: URL? = nil) throws -> String {
    let path = directory.appendingPathComponent(UUID().uuidString)
    let json = String(data: try JSONSerialization.data(withJSONObject: snapshot), encoding: .utf8)!
    let quoted = json.replacingOccurrences(of: "'", with: "'\\''")
    let logRequest = requestLog.map { "printf '%s\\n' \"$line\" >> '\($0.path.replacingOccurrences(of: "'", with: "'\\''"))'" } ?? ":"
    let script = """
    #!/bin/sh
    if [ "$1" = "status-brief" ]; then
      printf '%s\\n' '\(quoted)'
      exit 0
    fi
    while IFS= read -r line; do
      \(logRequest)
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
    // Appending keeps the title and refreshes the command, including on cache hits.
    let appendHandle = try! FileHandle(forWritingTo: utf8BoundaryLog)
    try! appendHandle.seekToEnd()
    try! appendHandle.write(contentsOf: Data("{\"type\":\"PLANNER_RESPONSE\",\"tool_calls\":[{\"name\":\"run_command\",\"arguments\":{\"CommandLine\":\"echo updated\"}}]}\n".utf8))
    try! appendHandle.close()
    for _ in 0..<2 {
        let updated = NotchStore.parseTranscriptTail(path: utf8BoundaryLog.path)
        assert(updated.title == "边界标题" && updated.command == "$ echo updated")
    }
    // An in-place rewrite may grow too; growth must not preserve a stale title.
    let rewriteHandle = try! FileHandle(forWritingTo: utf8BoundaryLog)
    let rewritten = "{\"type\":\"USER_INPUT\",\"content\":\"改写标题\"}\n" + String(repeating: " ", count: 40000)
    try! rewriteHandle.write(contentsOf: Data(rewritten.utf8))
    try! rewriteHandle.truncate(atOffset: UInt64(rewritten.utf8.count))
    try! rewriteHandle.close()
    assert(NotchStore.parseTranscriptTail(path: utf8BoundaryLog.path).title == "改写标题")
    try! "{\"type\":\"USER_INPUT\",\"content\":\"替换\"}\n".write(to: utf8BoundaryLog, atomically: true, encoding: .utf8)
    assert(NotchStore.parseTranscriptTail(path: utf8BoundaryLog.path).title == "替换")
    let truncateHandle = try! FileHandle(forWritingTo: utf8BoundaryLog)
    try! truncateHandle.truncate(atOffset: 0)
    try! truncateHandle.close()
    assert(NotchStore.parseTranscriptTail(path: utf8BoundaryLog.path).title.isEmpty)

    let badPath = try! mockBackend(at: tmp, snapshot: ["error": "telemetry unavailable"])
    let badClient = BackendLinesClient(backendPath: badPath, dataDir: tmp.path)
    if case .success = badClient.request(conversationId: "auto") {
        assertionFailure("expected bad backend request to fail")
    }
    if case .backingOff = badClient.request(conversationId: "auto") {
        // Error responses must back off just like timeouts and broken pipes.
    } else {
        assertionFailure("expected .backingOff after error response")
    }
    assert(NotchStore.fetchSnapshot(client: badClient, backendPath: badPath, previouslyActiveIds: []) == nil)
    badClient.close()

    // Hung backend must time out and close() must return immediately without deadlocking.
    let hungPath = tmp.appendingPathComponent("hung-backend")
    try! """
    #!/bin/sh
    sleep 30
    """.write(to: hungPath, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hungPath.path)
    let hungClient = BackendLinesClient(backendPath: hungPath.path, dataDir: tmp.path)
    let t0 = Date()
    if case .success = hungClient.request(conversationId: "auto", timeout: 0.25) {
        assertionFailure("expected hung backend request to time out")
    }
    assert(Date().timeIntervalSince(t0) < 1.5)
    // Immediate retry while backing off must return .backingOff without spawning a new process.
    if case .backingOff = hungClient.request(conversationId: "auto", timeout: 0.25) {
        // expected
    } else {
        assertionFailure("expected .backingOff after timeout failure")
    }
    hungClient.close()

    // close() while a request is blocked in flight must unblock immediately.
    let cancelClient = BackendLinesClient(backendPath: hungPath.path, dataDir: tmp.path)
    let cancelGroup = DispatchGroup()
    cancelGroup.enter()
    let cancelStart = Date()
    DispatchQueue.global().async {
        _ = cancelClient.request(conversationId: "auto", timeout: 5.0)
        cancelGroup.leave()
    }
    Thread.sleep(forTimeInterval: 0.08)
    let closeStart = Date()
    cancelClient.close()
    assert(Date().timeIntervalSince(closeStart) < 0.5)
    assert(cancelGroup.wait(timeout: .now() + 1.5) == .success)
    assert(Date().timeIntervalSince(cancelStart) < 1.5)

    // A client launched on the fetch queue must also close on the main thread
    // without waiting on Foundation's launching run loop.
    let closePath = try! mockBackend(at: tmp, snapshot: ["found": true])
    for _ in 0..<12 {
        let client = BackendLinesClient(backendPath: closePath, dataDir: tmp.path)
        let ready = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = client.request(conversationId: "auto")
            ready.signal()
        }
        assert(ready.wait(timeout: .now() + 2) == .success)
        let start = Date()
        client.close()
        assert(Date().timeIntervalSince(start) < 0.5)
    }

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

    // One primary + eight probes must count all nine tasks, while rendering four.
    let multiRequestLog = tmp.appendingPathComponent("multi-requests.jsonl")
    let multiRecent: [[String: Any]] = (0..<9).map {
        ["conversationId": "candidate-\($0)", "lastEvent": "PreInvocation", "terminalEnv": ["TERM_PROGRAM": "iTerm.app"]]
    }
    let multiPath = try! mockBackend(at: tmp, snapshot: [
        "found": true, "conversationId": "primary",
        "session": ["state": "running", "label": "生成中", "code": "streaming"],
        "terminalEnv": ["TERM_PROGRAM": "ghostty"],
        "recentConversations": multiRecent
    ], requestLog: multiRequestLog)
    let multiClient = BackendLinesClient(backendPath: multiPath, dataDir: tmp.path)
    let multi = NotchStore.fetchSnapshot(client: multiClient, backendPath: multiPath, previouslyActiveIds: [])!
    assert(multi.activeCount == 9 && multi.activeCountTruncated)
    assert(multi.activeTasks.count == 4 && multi.recentTasks.count == 4)
    assert(multi.activeTasks[0].terminalEnvironment["TERM_PROGRAM"] == "ghostty")
    assert(multi.activeTasks[1].terminalEnvironment["TERM_PROGRAM"] == "iTerm.app")
    let multiRequests = try! String(contentsOf: multiRequestLog, encoding: .utf8).split(separator: "\n")
    assert(multiRequests.count == 9)
    for (index, line) in multiRequests.enumerated() {
        let request = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        assert(request["includeShared"] as? Bool == (index == 0))
    }
    multiClient.close()

    // File events and timer callbacks share the hidden refresh limit;
    // manual refresh and showing the notch must still query immediately.
    let defaults = UserDefaults.standard
    let hiddenKey = "agy.notch.isHiddenByUser"
    let previousHidden = defaults.object(forKey: hiddenKey)
    defer {
        if let previousHidden { defaults.set(previousHidden, forKey: hiddenKey) }
        else { defaults.removeObject(forKey: hiddenKey) }
    }
    defaults.set(true, forKey: hiddenKey)
    let requestLog = tmp.appendingPathComponent("requests.jsonl")
    let refreshBackend = try! mockBackend(at: tmp, snapshot: ["found": true], requestLog: requestLog)
    let refreshingStore = NotchStore(backendPath: refreshBackend, dataDir: tmp.appendingPathComponent("data").path)
    func requestCount() -> Int {
        ((try? String(contentsOf: requestLog, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    func pumpUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        assert(condition())
    }
    pumpUntil { refreshingStore.snapshot.found }
    for _ in 0..<20 { refreshingStore.refreshNow(force: false) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    assert(requestCount() == 1)
    refreshingStore.refreshNow(force: true)
    pumpUntil { requestCount() == 2 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    refreshingStore.isHiddenByUser = false
    pumpUntil { requestCount() == 3 }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    refreshingStore.shutdown()

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

    // Selecting a completed/failed task in recentTasks must persist even while another task is running.
    let selStore = NotchStore(backendPath: "/nonexistent", dataDir: tmp.path, demoMode: true)
    let runningTask = ActiveTaskItem(id: "run-1", title: "running", commandText: "", modelName: "m", workspaceName: "w1", state: .running, stateLabel: "生成中", tokPerSec: 60, contextPct: 20, isRunning: true, code: "streaming")
    let doneTask = ActiveTaskItem(id: "done-1", title: "done", commandText: "", modelName: "m", workspaceName: "w2", state: .idle, stateLabel: "已完成", tokPerSec: nil, contextPct: 10, isRunning: false, code: "idle")
    var selSnap = NotchSnapshot()
    selSnap.conversationId = runningTask.id
    selSnap.activeTasks = [runningTask]
    selSnap.recentTasks = [runningTask, doneTask]
    selSnap.activeCount = 1
    selSnap.isActive = true
    selStore.applyFetchedSnapshot(selSnap)
    selStore.selectTask(doneTask)
    assert(selStore.displayedTask?.id == "done-1")
    selStore.applyFetchedSnapshot(selSnap)
    assert(selStore.displayedTask?.id == "done-1")

    // Starting a brand-new active task must override a stale manual idle selection.
    let secondRunningTask = ActiveTaskItem(id: "run-2", title: "running-2", commandText: "", modelName: "m", workspaceName: "w3", state: .running, stateLabel: "生成中", tokPerSec: 70, contextPct: 25, isRunning: true, code: "streaming")
    var newActiveSnap = NotchSnapshot()
    newActiveSnap.conversationId = secondRunningTask.id
    newActiveSnap.activeTasks = [secondRunningTask, runningTask]
    newActiveSnap.recentTasks = [secondRunningTask, runningTask, doneTask]
    newActiveSnap.activeCount = 2
    newActiveSnap.isActive = true
    selStore.applyFetchedSnapshot(newActiveSnap)
    assert(selStore.displayedTask?.id == "run-2")

    // When the currently selected running task finishes while another task is still running,
    // selection must auto-switch to the remaining running task.
    var finishedSecondTask = secondRunningTask
    finishedSecondTask.state = .idle
    finishedSecondTask.stateLabel = "已完成"
    finishedSecondTask.isRunning = false
    finishedSecondTask.code = "idle"
    var switchToRemainingSnap = NotchSnapshot()
    switchToRemainingSnap.conversationId = runningTask.id
    switchToRemainingSnap.activeTasks = [runningTask]
    switchToRemainingSnap.recentTasks = [runningTask, finishedSecondTask, doneTask]
    switchToRemainingSnap.activeCount = 1
    switchToRemainingSnap.isActive = true
    selStore.applyFetchedSnapshot(switchToRemainingSnap)
    assert(selStore.displayedTask?.id == "run-1")

    // When all tasks are idle (auto-selected) and a task later starts running, it must auto-switch to the running task.
    let idleStore = NotchStore(backendPath: "/nonexistent", dataDir: tmp.path, demoMode: true)
    var allIdleSnap = NotchSnapshot()
    allIdleSnap.conversationId = doneTask.id
    allIdleSnap.activeTasks = []
    allIdleSnap.recentTasks = [doneTask]
    allIdleSnap.isActive = false
    idleStore.applyFetchedSnapshot(allIdleSnap)
    assert(idleStore.displayedTask?.id == "done-1")
    idleStore.applyFetchedSnapshot(selSnap)
    assert(idleStore.displayedTask?.id == "run-1")
    idleStore.shutdown()
    // Temporary hide must not persist isHiddenByUser.
    selStore.isTemporarilyHidden = true
    assert(selStore.isHidden && !selStore.isHiddenByUser)
    selStore.isTemporarilyHidden = false
    assert(!selStore.isHidden)
    // Badge formatting for truncated counts.
    selSnap.activeCount = 5
    selSnap.activeCountTruncated = true
    assert(selSnap.activeCountBadge == "5+")
    selSnap.activeCountTruncated = false
    assert(selSnap.activeCountBadge == "5")
    selStore.shutdown()

    let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    var occupancy = OccupancyState()
    assert(!occupancy.update(0, immediate: true))
    assert(occupancy.update(44, immediate: false) && occupancy.offset == 0)
    assert(!occupancy.update(0, immediate: false) && occupancy.offset == 0) // Transient occupant.
    assert(occupancy.update(44, immediate: false))
    assert(!occupancy.update(44, immediate: false) && occupancy.offset == 44)
    assert(occupancy.update(0, immediate: false) && occupancy.offset == 44)
    assert(!occupancy.update(0, immediate: false) && occupancy.offset == 0)
    // Fullscreen app toolbar / menu bar strip spanning the screen must not trigger notch avoidance.
    assert(NotchPanelController.occupiedBottomOffset(
        for: CGRect(x: 0, y: 0, width: 1512, height: 38),
        screenFrame: screenFrame,
        screenTopCG: 0,
        notchWidth: 180
    ) == nil)
    // A real third-party notch app centered over the notch should still trigger avoidance.
    assert(NotchPanelController.occupiedBottomOffset(
        for: CGRect(x: 576, y: 0, width: 360, height: 38),
        screenFrame: screenFrame,
        screenTopCG: 0,
        notchWidth: 180
    ) == 44)
    let ghostty = NotchStore.resolveCliTerminalTarget(env: ["__CFBundleIdentifier": "com.mitchellh.ghostty", "TERM_PROGRAM": "ghostty"])
    assert(ghostty.bundleId == "com.mitchellh.ghostty" && ghostty.appName == "Ghostty")
    let iterm = NotchStore.resolveCliTerminalTarget(env: ["TERM_PROGRAM": "iTerm.app"])
    assert(iterm.bundleId == "com.googlecode.iterm2" && iterm.appName == "iTerm2")
    let integrated = NotchStore.resolveCliTerminalTarget(env: ["TERM_PROGRAM": "vscode", "__CFBundleIdentifier": "com.apple.Terminal"])
    assert(integrated.bundleId == "com.microsoft.VSCode")
    let unknown = NotchStore.resolveCliTerminalTarget(env: [:])
    assert(unknown.bundleId == nil && unknown.appName == nil)
    assert(NotchPaths.dataRoot(for: "/tmp/custom-cli/plugin_data/agy-desktop-status") == "/tmp/custom-cli")
    assert(NotchPaths.dataRoot(for: "/tmp/arbitrary-data") == nil)
    let cliStore = NotchStore(backendPath: "/nonexistent", dataDir: "/tmp/custom-cli/plugin_data/agy-desktop-status", demoMode: true, isCLI: true)
    assert(cliStore.isCLI)
    var firstTerminalTask = runningTask
    firstTerminalTask.terminalEnvironment = ["TERM_PROGRAM": "ghostty"]
    var secondTerminalTask = doneTask
    secondTerminalTask.terminalEnvironment = ["TERM_PROGRAM": "iTerm.app"]
    var terminals = NotchSnapshot()
    terminals.activeTasks = [firstTerminalTask]
    terminals.recentTasks = [firstTerminalTask, secondTerminalTask]
    cliStore.applyFetchedSnapshot(terminals)
    cliStore.selectTask(firstTerminalTask)
    assert(NotchStore.resolveCliTerminalTarget(env: cliStore.displayedTask!.terminalEnvironment).appName == "Ghostty")
    cliStore.selectTask(secondTerminalTask)
    assert(NotchStore.resolveCliTerminalTarget(env: cliStore.displayedTask!.terminalEnvironment).appName == "iTerm2")
    cliStore.shutdown()
    print("macOS notch regressions passed")
}
