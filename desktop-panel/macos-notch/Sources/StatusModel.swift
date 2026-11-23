import AppKit
import Combine
import Foundation

struct ActiveTaskItem: Identifiable, Equatable {
    let id: String
    var title: String
    var commandText: String
    var modelName: String
    var workspaceName: String
    var state: NotchSnapshot.RunState
    var stateLabel: String
    var tokPerSec: Double?
    var contextPct: Double?
    var isRunning: Bool = true
    var code: String = ""
}

struct NotchPeekEvent: Equatable {
    let id: UUID
    let state: NotchSnapshot.RunState
    let title: String
    let statusText: String
    let iconName: String

    init(state: NotchSnapshot.RunState, title: String, statusText: String, iconName: String) {
        self.id = UUID()
        self.state = state
        self.title = title
        self.statusText = statusText
        self.iconName = iconName
    }
}

struct NotchRemoteConfig: Equatable {
    var enabled: Bool = true
    var hideWhenIdle: Bool = false
    var screenMode: ScreenDisplayMode = .notchOrMain
    var avoidanceMode: NotchAvoidanceMode = .autoStackBelow
}

struct NotchSnapshot: Equatable {
    enum RunState: String {
        case idle
        case running
        case waiting
        case error

        var color: NSColor {
            switch self {
            case .idle: return NSColor(calibratedRed: 0.35, green: 0.80, blue: 0.50, alpha: 1.0)
            case .running: return NSColor(calibratedRed: 1.0, green: 0.56, blue: 0.18, alpha: 1.0)
            case .waiting: return NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.22, alpha: 1.0)
            case .error: return NSColor(calibratedRed: 0.96, green: 0.34, blue: 0.34, alpha: 1.0)
            }
        }
    }

    var found: Bool = false
    var conversationId: String = ""
    var title: String = "Antigravity"
    var commandText: String = ""
    var state: RunState = .idle
    var stateLabel: String = "就绪"
    var code: String = ""
    var modelName: String = ""
    var workspaceName: String = ""
    var tokPerSec: Double? = nil
    var lowSpeedThreshold: Double = 50
    var contextPct: Double? = nil
    var activeCount: Int = 0
    var activeTasks: [ActiveTaskItem] = []
    var recentTasks: [ActiveTaskItem] = []
    var quotaSummary: String = ""
    var isActive: Bool = false
    var remoteConfig: NotchRemoteConfig? = nil
}

enum ScreenDisplayMode: String, CaseIterable {
    case notchOrMain = "notchOrMain"
    case followActive = "followActive"
    case allScreens = "allScreens"

    var label: String {
        switch self {
        case .notchOrMain: return "优先刘海屏（无刘海时主屏）"
        case .followActive: return "跟随当前活跃屏幕"
        case .allScreens: return "所有屏幕同时显示"
        }
    }
}

enum NotchAvoidanceMode: String, CaseIterable {
    case autoStackBelow = "autoStackBelow"
    case forceNotch = "forceNotch"
    case topRight = "topRight"

    var label: String {
        switch self {
        case .autoStackBelow: return "自动避让（被占用时下移）"
        case .forceNotch: return "强制贴合刘海"
        case .topRight: return "悬浮在屏幕右上角"
        }
    }
}

/// Persistent NDJSON client communicating with `agy-desktop-backend --serve --data-dir <dataDir>`.
final class BackendLinesClient: @unchecked Sendable {
    private let backendPath: String
    private let dataDir: String
    private let lock = NSLock()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var readBuffer = Data()
    private var consecutiveFailures = 0
    private var nextRetryAt: Date = .distantPast
    private var isClosed = false

    init(backendPath: String, dataDir: String) {
        self.backendPath = backendPath
        self.dataDir = dataDir
        signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        close()
    }

    func request(conversationId: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }

        guard !isClosed else { return nil }
        guard startLockedIfNeeded() else { return nil }
        guard let stdinHandle, let stdoutHandle else { return nil }

        let payloadDict: [String: String] = ["conversationId": conversationId, "op": "brief"]
        guard var lineData = try? JSONSerialization.data(withJSONObject: payloadDict) else {
            return nil
        }
        lineData.append(0x0A)

        do {
            try stdinHandle.write(contentsOf: lineData)
        } catch {
            recordFailureAndTeardownLocked()
            return nil
        }

        while true {
            if let newlineRange = readBuffer.firstRange(of: Data([0x0A])) {
                let line = readBuffer.subdata(in: readBuffer.startIndex..<newlineRange.lowerBound)
                readBuffer.removeSubrange(readBuffer.startIndex..<newlineRange.upperBound)
                if line.isEmpty { continue }
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   obj["error"] == nil, obj["found"] is Bool {
                    consecutiveFailures = 0
                    nextRetryAt = .distantPast
                    return obj
                }
                return nil
            }

            let chunk = stdoutHandle.availableData
            if chunk.isEmpty {
                recordFailureAndTeardownLocked()
                return nil
            }
            readBuffer.append(chunk)
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }

        isClosed = true
        if let proc = process, proc.isRunning {
            if let stdinHandle {
                try? stdinHandle.write(contentsOf: Data("{\"op\":\"close\"}\n".utf8))
                try? stdinHandle.close()
            }
            let deadline = Date().addingTimeInterval(0.15)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if proc.isRunning {
                proc.terminate()
            }
        }
        teardownLocked()
    }

    private func startLockedIfNeeded() -> Bool {
        if let proc = process, proc.isRunning {
            return true
        }
        teardownLocked()

        guard Date() >= nextRetryAt else { return false }
        guard FileManager.default.isExecutableFile(atPath: backendPath) else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: backendPath)
        proc.arguments = ["--serve", "--data-dir", dataDir]

        var env = ProcessInfo.processInfo.environment
        env["AGY_NO_NOTCH"] = "1"
        proc.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            recordFailureAndTeardownLocked()
            return false
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        readBuffer.removeAll(keepingCapacity: true)
        return true
    }

    private func recordFailureAndTeardownLocked() {
        consecutiveFailures += 1
        let delay = min(8.0, 0.5 * pow(2.0, Double(min(consecutiveFailures - 1, 4))))
        nextRetryAt = Date().addingTimeInterval(delay)
        teardownLocked()
    }

    private func teardownLocked() {
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        readBuffer.removeAll(keepingCapacity: false)
        if let proc = process {
            if proc.isRunning {
                proc.terminate()
            }
            proc.waitUntilExit()
        }
        process = nil
    }
}

@MainActor
final class NotchStore: ObservableObject {
    private enum DefaultsKey {
        static let screenMode = "agy.notch.screenMode"
        static let avoidanceMode = "agy.notch.avoidanceMode"
        static let isHiddenByUser = "agy.notch.isHiddenByUser"
        static let hideWhenIdle = "agy.notch.hideWhenIdle"
    }

    @Published var snapshot = NotchSnapshot()
    @Published var isHovering = false {
        didSet {
            if isHovering {
                dismissPeekImmediately()
            }
        }
    }
    @Published var isHiddenByUser: Bool {
        didSet {
            if !demoMode {
                UserDefaults.standard.set(isHiddenByUser, forKey: DefaultsKey.isHiddenByUser)
                persistNotchSettingsIfLocal(["enabled": !isHiddenByUser])
            }
        }
    }
    @Published var hideWhenIdle: Bool {
        didSet {
            UserDefaults.standard.set(hideWhenIdle, forKey: DefaultsKey.hideWhenIdle)
            persistNotchSettingsIfLocal(["hideWhenIdle": hideWhenIdle])
        }
    }
    @Published var demoMode = false
    @Published var screenMode: ScreenDisplayMode {
        didSet {
            UserDefaults.standard.set(screenMode.rawValue, forKey: DefaultsKey.screenMode)
            persistNotchSettingsIfLocal(["screenMode": screenMode.rawValue])
        }
    }
    @Published var avoidanceMode: NotchAvoidanceMode {
        didSet {
            UserDefaults.standard.set(avoidanceMode.rawValue, forKey: DefaultsKey.avoidanceMode)
            persistNotchSettingsIfLocal(["avoidanceMode": avoidanceMode.rawValue])
        }
    }
    @Published var selectedConversationId: String? = nil
    @Published var activePeek: NotchPeekEvent? = nil

    private let backendPath: String
    private let dataDir: String
    private var isApplyingRemoteConfig = false
    private let backendClient: BackendLinesClient
    private let fetchQueue = DispatchQueue(label: "agy.notch.fetch", qos: .userInitiated)
    private var timer: Timer?
    private var demoPeekTimer: Timer?
    private var dirMonitor: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1
    private var isFetching = false
    private var lastFetchAt: Date = .distantPast

    private var hasSeenInitialSnapshot = false
    private var previousTaskStates: [String: (state: NotchSnapshot.RunState, isActive: Bool)] = [:]
    private var peekDismissWorkItem: DispatchWorkItem?

    init(backendPath: String, dataDir: String, demoMode: Bool = false) {
        self.backendPath = backendPath
        self.dataDir = dataDir
        self.backendClient = BackendLinesClient(backendPath: backendPath, dataDir: dataDir)
        self.demoMode = demoMode

        let defaults = UserDefaults.standard
        if let rawScreen = defaults.string(forKey: DefaultsKey.screenMode),
           let parsedScreen = ScreenDisplayMode(rawValue: rawScreen) {
            self.screenMode = parsedScreen
        } else {
            self.screenMode = .notchOrMain
        }
        if let rawAvoid = defaults.string(forKey: DefaultsKey.avoidanceMode),
           let parsedAvoid = NotchAvoidanceMode(rawValue: rawAvoid) {
            self.avoidanceMode = parsedAvoid
        } else {
            self.avoidanceMode = .autoStackBelow
        }
        self.hideWhenIdle = defaults.object(forKey: DefaultsKey.hideWhenIdle) as? Bool ?? false
        self.isHiddenByUser = demoMode ? false : (defaults.object(forKey: DefaultsKey.isHiddenByUser) as? Bool ?? false)

        if demoMode {
            applyDemoSnapshot()
            scheduleDemoShowcase()
        } else {
            startMonitoring()
            refreshNow(force: true)
        }
    }

    deinit {
        timer?.invalidate()
        demoPeekTimer?.invalidate()
        dirMonitor?.cancel()
        peekDismissWorkItem?.cancel()
        backendClient.close()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        demoPeekTimer?.invalidate()
        demoPeekTimer = nil
        dirMonitor?.cancel()
        dirMonitor = nil
        peekDismissWorkItem?.cancel()
        peekDismissWorkItem = nil
        backendClient.close()
    }

    var displayedTask: ActiveTaskItem? {
        if let cid = selectedConversationId {
            if let activeMatch = snapshot.activeTasks.first(where: { $0.id == cid }) {
                return activeMatch
            }
            if snapshot.activeTasks.isEmpty,
               let recentMatch = snapshot.recentTasks.first(where: { $0.id == cid }) {
                return recentMatch
            }
        }
        return snapshot.activeTasks.first ?? snapshot.recentTasks.first
    }

    func selectTask(_ task: ActiveTaskItem) {
        selectedConversationId = task.id
    }

    func cycleNextTask() {
        guard snapshot.activeTasks.count > 1 else { return }
        let currentIdx = snapshot.activeTasks.firstIndex(where: { $0.id == displayedTask?.id }) ?? 0
        let nextIdx = (currentIdx + 1) % snapshot.activeTasks.count
        selectedConversationId = snapshot.activeTasks[nextIdx].id
    }

    func applyDemoSnapshot() {
        let t1 = ActiveTaskItem(
            id: "demo-1",
            title: "重构 macOS Dynamic Island 刘海状态栏交互与 4 态视图",
            commandText: "$ ./desktop-panel/macos-notch/build.sh",
            modelName: "gemini-4-hydrogen-medium",
            workspaceName: "agy-statusline",
            state: .running,
            stateLabel: "生成中",
            tokPerSec: 68.4,
            contextPct: 42.0,
            isRunning: true
        )
        let t2 = ActiveTaskItem(
            id: "demo-2",
            title: "修复登录态刷新竞态问题与断线重连",
            commandText: "edit_file AuthManager.swift",
            modelName: "gemini-4-hydrogen-medium",
            workspaceName: "mobile-app",
            state: .waiting,
            stateLabel: "等待确认",
            tokPerSec: nil,
            contextPct: 61.0,
            isRunning: true
        )
        let t3 = ActiveTaskItem(
            id: "demo-3",
            title: "优化 backend --serve NDJSON 长连接复用",
            commandText: "✓ 已完成",
            modelName: "gemini-4-hydrogen-medium",
            workspaceName: "backend-zig",
            state: .idle,
            stateLabel: "已完成",
            tokPerSec: 74.2,
            contextPct: 28.0,
            isRunning: false
        )
        selectedConversationId = t1.id
        snapshot = NotchSnapshot(
            found: true,
            conversationId: t1.id,
            title: t1.title,
            commandText: t1.commandText,
            state: .running,
            stateLabel: "生成中",
            modelName: t1.modelName,
            workspaceName: t1.workspaceName,
            tokPerSec: 68.4,
            contextPct: 42.0,
            activeCount: 2,
            activeTasks: [t1, t2],
            recentTasks: [t1, t2, t3],
            quotaSummary: "5h 82% · 周 91%",
            isActive: true
        )
    }

    private func scheduleDemoShowcase() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.demoMode, !self.isHovering else { return }
            self.triggerPeek(
                NotchPeekEvent(
                    state: .idle,
                    title: "backend-zig",
                    statusText: "✓ 已完成",
                    iconName: "checkmark.circle.fill"
                )
            )
        }
        demoPeekTimer?.invalidate()
        demoPeekTimer = Timer.scheduledTimer(withTimeInterval: 14.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.demoMode, !self.isHovering else { return }
                self.triggerPeek(
                    NotchPeekEvent(
                        state: .waiting,
                        title: "mobile-app",
                        statusText: "等待确认",
                        iconName: "exclamationmark.circle.fill"
                    )
                )
            }
        }
    }

    func startMonitoring() {
        watchDataDirectory()
        scheduleTimer(interval: 1.5)
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshNow(force: false)
            }
        }
    }

    private func watchDataDirectory() {
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        dirFD = open(dataDir, O_EVTONLY)
        guard dirFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .rename, .extend],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshNow(force: true)
            }
        }
        source.setCancelHandler { [fd = dirFD] in
            if fd >= 0 { close(fd) }
        }
        source.resume()
        dirMonitor = source
    }

    func refreshNow(force: Bool) {
        if demoMode { return }
        let now = Date()
        if isFetching { return }
        if !force && now.timeIntervalSince(lastFetchAt) < 0.45 { return }

        isFetching = true
        lastFetchAt = now
        let client = self.backendClient
        let backend = self.backendPath
        let data = self.dataDir
        let prevActiveIds = Set(snapshot.activeTasks.map(\.id))

        fetchQueue.async { [weak self] in
            let next = Self.fetchSnapshot(
                client: client,
                backendPath: backend,
                dataDir: data,
                previouslyActiveIds: prevActiveIds
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetching = false
                if let next {
                    self.applyFetchedSnapshot(next)
                }
            }
        }
    }

    private func persistNotchSettingsIfLocal(_ patch: [String: Any]) {
        guard !demoMode, !isApplyingRemoteConfig,
              let payload = try? JSONSerialization.data(withJSONObject: ["notch": patch]) else { return }
        let backend = backendPath
        let data = dataDir
        fetchQueue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: backend)
            process.arguments = ["settings-patch", "--data-dir", data]
            var env = ProcessInfo.processInfo.environment
            env["AGY_NO_NOTCH"] = "1"
            process.environment = env
            let pipe = Pipe()
            process.standardInput = pipe
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                try pipe.fileHandleForWriting.write(contentsOf: payload)
                try pipe.fileHandleForWriting.close()
                process.waitUntilExit()
            } catch {
                try? pipe.fileHandleForWriting.close()
            }
        }
    }

    func applyFetchedSnapshot(_ next: NotchSnapshot) {
        if let remote = next.remoteConfig {
            isApplyingRemoteConfig = true
            let shouldHide = !remote.enabled
            if isHiddenByUser != shouldHide { isHiddenByUser = shouldHide }
            if hideWhenIdle != remote.hideWhenIdle { hideWhenIdle = remote.hideWhenIdle }
            if screenMode != remote.screenMode { screenMode = remote.screenMode }
            if avoidanceMode != remote.avoidanceMode { avoidanceMode = remote.avoidanceMode }
            isApplyingRemoteConfig = false
        }

        let wasActive = snapshot.isActive
        evaluatePeekTransitions(for: next)
        snapshot = next

        if let cid = selectedConversationId {
            let stillValid = next.activeTasks.contains(where: { $0.id == cid })
                || (next.activeTasks.isEmpty && next.recentTasks.contains(where: { $0.id == cid }))
            if !stillValid {
                selectedConversationId = next.activeTasks.first?.id ?? next.recentTasks.first?.id
            }
        } else {
            selectedConversationId = next.activeTasks.first?.id ?? next.recentTasks.first?.id
        }

        if next.isActive != wasActive {
            scheduleTimer(interval: next.isActive ? 1.0 : 3.5)
        }
    }

    private func evaluatePeekTransitions(for next: NotchSnapshot) {
        var candidates: [ActiveTaskItem] = next.recentTasks
        if !next.conversationId.isEmpty && !candidates.contains(where: { $0.id == next.conversationId }) {
            let primary = ActiveTaskItem(
                id: next.conversationId,
                title: next.title,
                commandText: next.commandText,
                modelName: next.modelName,
                workspaceName: next.workspaceName,
                state: next.state,
                stateLabel: next.stateLabel,
                tokPerSec: next.tokPerSec,
                contextPct: next.contextPct,
                isRunning: next.isActive
            )
            candidates.insert(primary, at: 0)
        }

        var nextMap: [String: (state: NotchSnapshot.RunState, isActive: Bool)] = [:]
        for item in candidates {
            nextMap[item.id] = (item.state, item.isRunning)
        }

        if !hasSeenInitialSnapshot {
            hasSeenInitialSnapshot = true
            previousTaskStates = nextMap
            return
        }

        var selectedEvent: NotchPeekEvent? = nil
        var bestPriority = 0

        for item in candidates {
            let prev = previousTaskStates[item.id]
            let displayName = !item.workspaceName.isEmpty ? item.workspaceName : item.title

            if item.state == .error && prev?.state != .error {
                if bestPriority < 3 {
                    bestPriority = 3
                    selectedEvent = NotchPeekEvent(
                        state: .error,
                        title: displayName,
                        statusText: "执行异常",
                        iconName: "xmark.octagon.fill"
                    )
                }
            } else if item.state == .waiting && prev?.state != .waiting {
                if bestPriority < 2 {
                    bestPriority = 2
                    selectedEvent = NotchPeekEvent(
                        state: .waiting,
                        title: displayName,
                        statusText: item.stateLabel,
                        iconName: "exclamationmark.circle.fill"
                    )
                }
            } else if let prev,
                      (prev.isActive || prev.state == .running || prev.state == .waiting),
                      !item.isRunning,
                      item.state == .idle, item.code == "idle" {
                if bestPriority < 1 {
                    bestPriority = 1
                    selectedEvent = NotchPeekEvent(
                        state: .idle,
                        title: displayName,
                        statusText: "✓ 已完成",
                        iconName: "checkmark.circle.fill"
                    )
                }
            }
        }

        previousTaskStates = nextMap

        if let selectedEvent {
            triggerPeek(selectedEvent)
        }
    }

    func triggerPeek(_ event: NotchPeekEvent) {
        guard !isHovering else { return }
        activePeek = event
        peekDismissWorkItem?.cancel()

        let eventID = event.id
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.activePeek?.id == eventID && !self.isHovering {
                self.activePeek = nil
            }
        }
        peekDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    private func dismissPeekImmediately() {
        peekDismissWorkItem?.cancel()
        peekDismissWorkItem = nil
        if activePeek != nil {
            activePeek = nil
        }
    }

    nonisolated private static func queryBackend(
        client: BackendLinesClient,
        backendPath: String,
        dataDir: String? = nil,
        conversationId: String
    ) -> [String: Any]? {
        if let served = client.request(conversationId: conversationId) {
            return served
        }
        return runBackendStatusFallback(backendPath: backendPath, dataDir: dataDir, conversationId: conversationId)
    }

    nonisolated private static func runBackendStatusFallback(
        backendPath: String,
        dataDir: String? = nil,
        conversationId: String? = nil
    ) -> [String: Any]? {
        guard FileManager.default.isExecutableFile(atPath: backendPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: backendPath)
        var args = ["status-brief"]
        if let dataDir, !dataDir.isEmpty {
            args.append(contentsOf: ["--data-dir", dataDir])
        }
        if let cid = conversationId, !cid.isEmpty, cid != "auto" {
            args.append(contentsOf: ["--conversation-id", cid])
        }
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["AGY_NO_NOTCH"] = "1"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil, json["found"] is Bool else {
            return nil
        }
        return json
    }

    nonisolated private static func isWithinSeconds(_ isoString: String?, seconds: TimeInterval) -> Bool {
        guard let isoString, !isoString.isEmpty else { return false }
        let fmtWithFrac = ISO8601DateFormatter()
        fmtWithFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fmtWithFrac.date(from: isoString) {
            return abs(Date().timeIntervalSince(date)) <= seconds
        }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        if let date = fmt.date(from: isoString) {
            return abs(Date().timeIntervalSince(date)) <= seconds
        }
        return false
    }

    nonisolated static func fetchSnapshot(
        client: BackendLinesClient,
        backendPath: String,
        dataDir: String? = nil,
        previouslyActiveIds: Set<String>
    ) -> NotchSnapshot? {
        guard let json = queryBackend(client: client, backendPath: backendPath, dataDir: dataDir, conversationId: "auto") else {
            return nil
        }

        var snap = NotchSnapshot()
        snap.found = (json["found"] as? Bool) ?? false
        let convId = (json["conversationId"] as? String) ?? ""
        snap.conversationId = convId
        snap.modelName = (json["modelName"] as? String) ?? ""
        snap.workspaceName = (json["workspaceName"] as? String) ?? ""
        if let pct = json["contextPct"] as? Double {
            snap.contextPct = pct
        }

        let primaryParsed = parseStateAndSpeed(from: json)
        snap.state = primaryParsed.state
        snap.stateLabel = primaryParsed.label
        snap.code = primaryParsed.code
        snap.tokPerSec = primaryParsed.tokPerSec
        snap.isActive = primaryParsed.isActive

        if let quota = json["quota"] as? [String: Any] {
            snap.quotaSummary = formatQuota(quota)
        }

        snap.lowSpeedThreshold = (json["config"] as? [String: Any])?["lowSpeedWarnTokS"] as? Double ?? 50
        if let cfg = json["config"] as? [String: Any],
           let notch = cfg["notch"] as? [String: Any] {
            var rc = NotchRemoteConfig()
            if let en = notch["enabled"] as? Bool { rc.enabled = en }
            if let hideIdle = notch["hideWhenIdle"] as? Bool { rc.hideWhenIdle = hideIdle }
            if let sm = notch["screenMode"] as? String, let parsed = ScreenDisplayMode(rawValue: sm) {
                rc.screenMode = parsed
            }
            if let am = notch["avoidanceMode"] as? String, let parsed = NotchAvoidanceMode(rawValue: am) {
                rc.avoidanceMode = parsed
            }
            snap.remoteConfig = rc
        }

        let primaryTranscript = parseTranscriptTail(path: json["transcriptPath"] as? String ?? "")
        snap.title = !primaryTranscript.title.isEmpty
            ? primaryTranscript.title
            : (!snap.workspaceName.isEmpty ? snap.workspaceName : "Antigravity")

        if !primaryTranscript.command.isEmpty {
            snap.commandText = primaryTranscript.command
        } else if let tok = snap.tokPerSec, snap.isActive {
            snap.commandText = String(format: "%.0f t/s · %@", tok, snap.stateLabel)
        } else if snap.isActive {
            snap.commandText = snap.stateLabel
        } else {
            snap.commandText = snap.modelName
        }

        var tasks: [ActiveTaskItem] = []
        var recentList: [ActiveTaskItem] = []

        if !convId.isEmpty {
            let primaryItem = ActiveTaskItem(
                id: convId,
                title: snap.title,
                commandText: !primaryTranscript.command.isEmpty ? primaryTranscript.command : snap.stateLabel,
                modelName: snap.modelName,
                workspaceName: snap.workspaceName,
                state: snap.state,
                stateLabel: snap.stateLabel,
                tokPerSec: snap.tokPerSec,
                contextPct: snap.contextPct,
                isRunning: snap.isActive,
                code: snap.code
            )
            recentList.append(primaryItem)
            if snap.isActive {
                tasks.append(primaryItem)
            }
        }

        if let recent = json["recentConversations"] as? [[String: Any]] {
            var probedCount = 0
            for item in recent {
                let cid = (item["conversationId"] as? String) ?? ""
                if cid.isEmpty || cid == convId { continue }

                let hookFlag = (item["isActive"] as? Bool) ?? false
                let lastEvent = (item["lastEvent"] as? String) ?? ""
                let eventActive = lastEvent == "PreInvocation" || lastEvent == "PostInvocation"
                let wasActive = previouslyActiveIds.contains(cid)
                let recentlyUpdated = isWithinSeconds(item["updatedAt"] as? String, seconds: 180)
                let shouldProbe = hookFlag || eventActive || wasActive || recentlyUpdated

                if !shouldProbe && recentList.count >= 4 { continue }
                if tasks.count >= 4 && recentList.count >= 4 { break }

                var ws = (item["workspace"] as? String) ?? ""
                var model = (item["modelName"] as? String) ?? ""
                var tInfo = parseTranscriptTail(path: item["transcriptPath"] as? String ?? "")

                var active = false
                var state: NotchSnapshot.RunState = .idle
                var label = "已完成"
                var tok: Double? = nil
                var ctx: Double? = nil
                var code = ""

                if shouldProbe && probedCount < 6 {
                    probedCount += 1
                    if let subJson = queryBackend(client: client, backendPath: backendPath, dataDir: dataDir, conversationId: cid) {
                        let parsed = parseStateAndSpeed(from: subJson)
                        active = parsed.isActive
                        state = parsed.state
                        label = parsed.label
                        code = parsed.code
                        tInfo = parseTranscriptTail(path: subJson["transcriptPath"] as? String ?? "")
                        tok = parsed.tokPerSec
                        ctx = subJson["contextPct"] as? Double
                        if ws.isEmpty, let subWs = subJson["workspaceName"] as? String {
                            ws = subWs
                        }
                        if model.isEmpty, let subModel = subJson["modelName"] as? String {
                            model = subModel
                        }
                    } else if wasActive {
                        // Transient backend query failure: don't falsely emit a completion peek.
                        active = true
                        state = .running
                        label = "运行中"
                    }
                }

                if !active && recentList.count >= 4 { continue }

                let title = !tInfo.title.isEmpty ? tInfo.title : (!ws.isEmpty ? ws : String(cid.prefix(8)))
                let cmd = !tInfo.command.isEmpty ? tInfo.command : label
                let taskItem = ActiveTaskItem(
                    id: cid,
                    title: title,
                    commandText: cmd,
                    modelName: model,
                    workspaceName: ws,
                    state: state,
                    stateLabel: label,
                    tokPerSec: tok,
                    contextPct: ctx,
                    isRunning: active,
                    code: code
                )
                if active && tasks.count < 4 {
                    tasks.append(taskItem)
                }
                if recentList.count < 4 {
                    recentList.append(taskItem)
                } else if active, let replaceIdx = recentList.lastIndex(where: { !$0.isRunning }) {
                    recentList[replaceIdx] = taskItem
                }
            }
        }

        snap.activeTasks = tasks
        snap.recentTasks = recentList
        snap.activeCount = tasks.count
        if !tasks.isEmpty {
            snap.isActive = true
        }

        return snap
    }

    nonisolated static func parseStateAndSpeed(from json: [String: Any]) -> (state: NotchSnapshot.RunState, label: String, tokPerSec: Double?, isActive: Bool, code: String) {
        let live = json["live"] as? [String: Any]
        let liveActive = (live?["active"] as? Bool) ?? false
        var tokPerSec: Double? = nil
        if let est = live?["estTokPerSec"] as? Double {
            tokPerSec = est
        } else if !liveActive, let avg = json["lastAvgSpeed"] as? Double {
            tokPerSec = avg
        }

        let session = json["session"] as? [String: Any]
        let stateStr = (session?["state"] as? String) ?? "idle"
        let label = (session?["label"] as? String) ?? "就绪"
        let state: NotchSnapshot.RunState
        switch stateStr {
        case "running", "streaming", "tool":
            state = .running
        case "waiting", "stalled", "slow":
            state = .waiting
        case "error", "failed":
            state = .error
        default:
            state = session == nil && liveActive ? .running : .idle
        }
        let isActive = state == .running || state == .waiting
        return (state, label, tokPerSec, isActive, session?["code"] as? String ?? "")
    }

    nonisolated static func formatQuota(_ quota: [String: Any]) -> String {
        var parts: [String] = []
        if let buckets = quota["windows"] as? [[String: Any]] {
            for b in buckets.prefix(2) {
                let pool = (b["pool"] as? String) ?? ""
                let window = (b["window"] as? String) ?? ""
                let label = "\(pool) \(window == "weekly" ? "周" : window)"
                if let pct = b["remainingPct"] as? Double {
                    parts.append("\(label) \(Int(pct.rounded()))%")
                }
            }
        }
        return parts.joined(separator: " · ")
    }

    nonisolated static func parseTranscriptTail(path: String) -> (title: String, command: String) {
        guard !path.isEmpty else { return ("", "") }
        guard let handle = FileHandle(forReadingAtPath: path) else { return ("", "") }
        defer { try? handle.close() }

        var title = ""
        let headData = handle.readData(ofLength: 16384)
        let headText = String(decoding: headData, as: UTF8.self)
        for line in headText.split(separator: "\n", maxSplits: 6) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if (obj["type"] as? String) == "USER_INPUT",
               let content = obj["content"] as? String {
                title = cleanUserRequest(content)
                if !title.isEmpty { break }
            }
        }

        var command = ""
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        let tailOffset: UInt64 = fileSize > 32768 ? fileSize - 32768 : 0
        try? handle.seek(toOffset: tailOffset)
        let tailData = handle.readDataToEndOfFile()
        let tailText = String(decoding: tailData, as: UTF8.self)
        let lines = tailText.split(separator: "\n")
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            let typ = (obj["type"] as? String) ?? ""
            if typ == "USER_INPUT", title.isEmpty, let content = obj["content"] as? String {
                title = cleanUserRequest(content)
            }
            if typ == "PLANNER_RESPONSE",
               let calls = obj["tool_calls"] as? [[String: Any]],
               let lastCall = calls.last {
                command = formatToolCall(lastCall)
                if !command.isEmpty { break }
            }
        }

        return (title, command)
    }

    nonisolated private static func cleanUserRequest(_ raw: String) -> String {
        var text = raw
        if let start = text.range(of: "<USER_REQUEST>"),
           let end = text.range(of: "</USER_REQUEST>", range: start.upperBound..<text.endIndex) {
            text = String(text[start.upperBound..<end.lowerBound])
        }
        return text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func formatToolCall(_ call: [String: Any]) -> String {
        let name = (call["name"] as? String) ?? ""
        let args = call["arguments"] as? [String: Any]
        if name == "run_command", let cmd = args?["CommandLine"] as? String {
            let singleLine = cmd.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return "$ \(singleLine)"
        }
        if let path = args?["Path"] as? String {
            let base = URL(fileURLWithPath: path).lastPathComponent
            return "\(name) \(base)"
        }
        if let query = args?["query"] as? String {
            return "🔍 \(query)"
        }
        return name
    }
}
