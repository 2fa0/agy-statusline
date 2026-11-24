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
    var activeCountTruncated: Bool = false
    var activeTasks: [ActiveTaskItem] = []
    var recentTasks: [ActiveTaskItem] = []
    var quotaSummary: String = ""
    var isActive: Bool = false
    var remoteConfig: NotchRemoteConfig? = nil

    var activeCountBadge: String {
        activeCountTruncated ? "\(activeCount)+" : "\(activeCount)"
    }
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

enum BackendRequestResult {
    case success([String: Any])
    case backingOff
    case failed
}

/// Persistent NDJSON client communicating with `agy-desktop-backend --serve --data-dir <dataDir>`.
final class BackendLinesClient: @unchecked Sendable {
    private let backendPath: String
    let dataDir: String
    private let ioLock = NSLock()
    private let stateLock = NSLock()

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var readBuffer = Data()
    private var consecutiveFailures = 0
    private var nextRetryAt: Date = .distantPast
    private var nextFallbackAt: Date = .distantPast

    private var isClosedFlag = false
    private var currentPID: pid_t = 0
    private let cancelReadFD: Int32
    private let cancelWriteFD: Int32

    init(backendPath: String, dataDir: String) {
        self.backendPath = backendPath
        self.dataDir = dataDir
        var fds: [Int32] = [-1, -1]
        if Darwin.pipe(&fds) == 0 {
            _ = fcntl(fds[0], F_SETFL, O_NONBLOCK)
            _ = fcntl(fds[1], F_SETFL, O_NONBLOCK)
            _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
            self.cancelReadFD = fds[0]
            self.cancelWriteFD = fds[1]
        } else {
            self.cancelReadFD = -1
            self.cancelWriteFD = -1
        }
        signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        close()
        if cancelReadFD >= 0 { Darwin.close(cancelReadFD) }
        if cancelWriteFD >= 0 { Darwin.close(cancelWriteFD) }
    }

    var isClosed: Bool {
        stateLock.lock()
        let v = isClosedFlag
        stateLock.unlock()
        return v
    }

    var cancellationFD: Int32 { cancelReadFD }

    func request(
        conversationId: String,
        op: String = "brief",
        includeShared: Bool = true,
        timeout: TimeInterval = 3.0
    ) -> BackendRequestResult {
        ioLock.lock()
        defer { ioLock.unlock() }

        guard !isClosed else { return .failed }
        switch startLockedIfNeeded() {
        case .ready:
            break
        case .backingOff:
            return .backingOff
        case .failed:
            return .failed
        }
        guard let stdinHandle, let stdoutHandle else { return .failed }

        return autoreleasepool {
            let payloadDict: [String: Any] = [
                "conversationId": conversationId,
                "op": op,
                "includeShared": includeShared
            ]
            guard var lineData = try? JSONSerialization.data(withJSONObject: payloadDict) else {
                return .failed
            }
            lineData.append(0x0A)

            do {
                try stdinHandle.write(contentsOf: lineData)
            } catch {
                recordFailureAndTeardownLocked()
                return .failed
            }

            let deadline = Date().addingTimeInterval(timeout)
            let stdoutFD = stdoutHandle.fileDescriptor
            var chunkBuf = [UInt8](repeating: 0, count: 4096)

            while true {
                if isClosed {
                    teardownLocked()
                    return .failed
                }
                if let newlineIdx = readBuffer.firstIndex(of: 0x0A) {
                    let line = readBuffer[readBuffer.startIndex..<newlineIdx]
                    readBuffer.removeSubrange(readBuffer.startIndex...newlineIdx)
                    if line.isEmpty { continue }
                    if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                       obj["error"] == nil, obj["found"] is Bool {
                        consecutiveFailures = 0
                        nextRetryAt = .distantPast
                        nextFallbackAt = .distantPast
                        return .success(obj)
                    }
                    recordFailureAndTeardownLocked()
                    return .failed
                }

                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    recordFailureAndTeardownLocked()
                    return .failed
                }
                let waitMs = Int32(min(max(remaining * 1000.0, 1.0), 1000.0))
                var fds = [
                    pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: cancelReadFD, events: Int16(POLLIN), revents: 0)
                ]
                let nfds: nfds_t = cancelReadFD >= 0 ? 2 : 1
                let ready = Darwin.poll(&fds, nfds, waitMs)
                if ready < 0 {
                    if errno == EINTR { continue }
                    recordFailureAndTeardownLocked()
                    return .failed
                }
                if ready == 0 {
                    continue
                }
                if nfds == 2 && (fds[1].revents & Int16(POLLIN)) != 0 {
                    teardownLocked()
                    return .failed
                }
                if (fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
                    let n = Darwin.read(stdoutFD, &chunkBuf, chunkBuf.count)
                    if n > 0 {
                        readBuffer.append(contentsOf: chunkBuf[0..<n])
                    } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                        continue
                    } else {
                        recordFailureAndTeardownLocked()
                        return .failed
                    }
                }
            }
        }
    }

    /// Unified rate-limiter for fallback one-shot process queries so sustained
    /// backend failures cannot repeatedly spawn processes during backoff.
    func beginFallbackAttempt() -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard !isClosed else { return false }
        let now = Date()
        guard now >= nextFallbackAt else { return false }
        nextFallbackAt = now.addingTimeInterval(2.0)
        return true
    }

    func recordFallbackResult(success: Bool) {
        ioLock.lock()
        defer { ioLock.unlock() }
        if success {
            consecutiveFailures = 0
            nextRetryAt = .distantPast
            nextFallbackAt = .distantPast
        } else {
            consecutiveFailures += 1
            let delay = min(8.0, 0.5 * pow(2.0, Double(min(consecutiveFailures - 1, 4))))
            let until = Date().addingTimeInterval(delay)
            nextRetryAt = max(nextRetryAt, until)
            nextFallbackAt = max(nextFallbackAt, until)
        }
    }

    /// Cancels any in-flight blocking read immediately without risking main-thread deadlock.
    func close() {
        stateLock.lock()
        isClosedFlag = true
        let pid = currentPID
        stateLock.unlock()

        if cancelWriteFD >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(cancelWriteFD, &byte, 1)
        }

        // If no request is currently holding ioLock, shut down cleanly right now.
        // If a request is in flight, the wakeup pipe + SIGTERM will unblock it
        // immediately and it will tear down before releasing ioLock.
        if ioLock.try() {
            defer { ioLock.unlock() }
            if let proc = process, proc.isRunning {
                if let stdinHandle {
                    try? stdinHandle.write(contentsOf: Data("{\"op\":\"close\"}\n".utf8))
                    try? stdinHandle.close()
                }
                terminateProcessBounded(proc, graceSeconds: 0.15)
            }
            teardownLocked()
        } else if pid > 0 {
            _ = Darwin.kill(pid, SIGTERM)
        }
    }

    private enum StartOutcome {
        case ready
        case backingOff
        case failed
    }

    private func startLockedIfNeeded() -> StartOutcome {
        if let proc = process, proc.isRunning {
            return .ready
        }
        teardownLocked()

        guard Date() >= nextRetryAt else { return .backingOff }
        guard FileManager.default.isExecutableFile(atPath: backendPath) else { return .failed }

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
            return .failed
        }

        process = proc
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stateLock.lock()
        currentPID = proc.processIdentifier
        stateLock.unlock()
        readBuffer.removeAll(keepingCapacity: true)
        return .ready
    }

    private func recordFailureAndTeardownLocked() {
        consecutiveFailures += 1
        let delay = min(8.0, 0.5 * pow(2.0, Double(min(consecutiveFailures - 1, 4))))
        nextRetryAt = Date().addingTimeInterval(delay)
        teardownLocked()
    }

    private func terminateProcessBounded(_ proc: Process, graceSeconds: TimeInterval) {
        if proc.isRunning {
            proc.terminate()
        }
        let deadline = Date().addingTimeInterval(graceSeconds)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if proc.isRunning {
            _ = Darwin.kill(proc.processIdentifier, SIGKILL)
        }
        // Foundation reaps the child; waitUntilExit() can hang across run loops.
    }

    private func teardownLocked() {
        try? stdinHandle?.close()
        try? stdoutHandle?.close()
        stdinHandle = nil
        stdoutHandle = nil
        readBuffer.removeAll(keepingCapacity: false)
        if let proc = process {
            terminateProcessBounded(proc, graceSeconds: 0.15)
        }
        process = nil
        stateLock.lock()
        currentPID = 0
        stateLock.unlock()
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
    @Published var hoveredScreenID: CGDirectDisplayID? = nil {
        didSet {
            if hoveredScreenID != nil {
                dismissPeekImmediately()
            }
        }
    }
    var isHovering: Bool {
        hoveredScreenID != nil
    }
    /// Session-only temporary hide: does NOT persist `notch.enabled = false` to config.json.
    @Published var isTemporarilyHidden: Bool = false {
        didSet {
            if isTemporarilyHidden {
                hoveredScreenID = nil
            }
            if !demoMode {
                scheduleTimer(interval: desiredPollInterval(isActive: snapshot.isActive))
                if !isHidden {
                    refreshNow(force: true)
                }
            }
        }
    }
    /// Persistent disabled state synced with `notch.enabled` in config.json.
    @Published var isHiddenByUser: Bool {
        didSet {
            if isHiddenByUser {
                hoveredScreenID = nil
            }
            if !demoMode {
                UserDefaults.standard.set(isHiddenByUser, forKey: DefaultsKey.isHiddenByUser)
                persistNotchSettingsIfLocal(["enabled": !isHiddenByUser])
                scheduleTimer(interval: desiredPollInterval(isActive: snapshot.isActive))
                if !isHidden && !isApplyingRemoteConfig {
                    refreshNow(force: true)
                }
            }
        }
    }
    var isHidden: Bool {
        isTemporarilyHidden || isHiddenByUser
    }
    @Published var isConnectionStale: Bool = false
    @Published var lastSuccessAt: Date? = nil
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
    let dataDir: String
    private var isApplyingRemoteConfig = false
    private let backendClient: BackendLinesClient
    private let fetchQueue = DispatchQueue(label: "agy.notch.fetch", qos: .userInitiated)
    private var timer: Timer?
    private var currentPollInterval: TimeInterval = 0
    private var demoPeekTimer: Timer?
    private var dirMonitor: DispatchSourceFileSystemObject?
    private var dirDebounceWorkItem: DispatchWorkItem?
    private var dirFD: Int32 = -1
    private var isFetching = false
    private var lastFetchAt: Date = .distantPast
    private var consecutiveFetchFailures = 0

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
        dirDebounceWorkItem?.cancel()
        dirMonitor?.cancel()
        peekDismissWorkItem?.cancel()
        backendClient.close()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        demoPeekTimer?.invalidate()
        demoPeekTimer = nil
        dirDebounceWorkItem?.cancel()
        dirDebounceWorkItem = nil
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
            if let recentMatch = snapshot.recentTasks.first(where: { $0.id == cid }) {
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
        if timer != nil && abs(currentPollInterval - interval) < 0.01 { return }
        currentPollInterval = interval
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshNow(force: false)
            }
        }
        t.tolerance = interval * 0.25
        timer = t
    }

    private func desiredPollInterval(isActive: Bool) -> TimeInterval {
        if isHidden { return 5.0 }
        return isActive ? 1.0 : 3.5
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
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isHidden else { return }
                self.dirDebounceWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.refreshNow(force: false)
                }
                self.dirDebounceWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
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
        if !force && now.timeIntervalSince(lastFetchAt) < automaticRefreshInterval { return }

        isFetching = true
        lastFetchAt = now
        let client = self.backendClient
        let backend = self.backendPath
        let data = self.dataDir
        let configOnly = self.isHidden && !force
        var prevActiveMap: [String: ActiveTaskItem] = [:]
        for task in snapshot.activeTasks {
            prevActiveMap[task.id] = task
        }

        fetchQueue.async { [weak self] in
            if configOnly {
                let remoteCfg: NotchRemoteConfig? = autoreleasepool {
                    Self.fetchRemoteConfigOnly(client: client, backendPath: backend, dataDir: data)
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isFetching = false
                    if let remoteCfg {
                        let wasHidden = self.isHidden
                        self.applyRemoteConfig(remoteCfg)
                        if wasHidden && !self.isHidden {
                            self.refreshNow(force: true)
                        }
                    }
                }
                return
            }

            let next: NotchSnapshot? = autoreleasepool {
                Self.fetchSnapshot(
                    client: client,
                    backendPath: backend,
                    dataDir: data,
                    previouslyActiveTasks: prevActiveMap
                )
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetching = false
                if let next {
                    self.consecutiveFetchFailures = 0
                    self.lastSuccessAt = Date()
                    if self.isConnectionStale {
                        self.isConnectionStale = false
                    }
                    self.applyFetchedSnapshot(next)
                } else {
                    self.consecutiveFetchFailures += 1
                    if self.consecutiveFetchFailures >= 2 && !self.isConnectionStale {
                        self.isConnectionStale = true
                    }
                }
            }
        }
    }

    private var automaticRefreshInterval: TimeInterval {
        isHidden ? 5.0 : 1.0
    }

    private func applyRemoteConfig(_ remote: NotchRemoteConfig) {
        isApplyingRemoteConfig = true
        let shouldHide = !remote.enabled
        if isHiddenByUser != shouldHide { isHiddenByUser = shouldHide }
        if hideWhenIdle != remote.hideWhenIdle { hideWhenIdle = remote.hideWhenIdle }
        if screenMode != remote.screenMode { screenMode = remote.screenMode }
        if avoidanceMode != remote.avoidanceMode { avoidanceMode = remote.avoidanceMode }
        isApplyingRemoteConfig = false
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
                let deadline = Date().addingTimeInterval(3.0)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    process.terminate()
                }
                process.waitUntilExit()
            } catch {
                try? pipe.fileHandleForWriting.close()
            }
        }
    }

    func applyFetchedSnapshot(_ next: NotchSnapshot) {
        if let remote = next.remoteConfig {
            applyRemoteConfig(remote)
        }

        evaluatePeekTransitions(for: next)
        if snapshot != next {
            snapshot = next
        }

        let nextSelectedId: String?
        if let cid = selectedConversationId {
            let stillValid = next.activeTasks.contains(where: { $0.id == cid })
                || next.recentTasks.contains(where: { $0.id == cid })
            nextSelectedId = stillValid ? cid : (next.activeTasks.first?.id ?? next.recentTasks.first?.id)
        } else {
            nextSelectedId = next.activeTasks.first?.id ?? next.recentTasks.first?.id
        }
        if selectedConversationId != nextSelectedId {
            selectedConversationId = nextSelectedId
        }

        scheduleTimer(interval: desiredPollInterval(isActive: next.isActive))
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
        conversationId: String,
        op: String = "brief",
        includeShared: Bool = true
    ) -> [String: Any]? {
        switch client.request(conversationId: conversationId, op: op, includeShared: includeShared) {
        case .success(let served):
            return served
        case .backingOff:
            // Respect persistent client backoff: do not spawn one-shot fallback processes while backing off.
            return nil
        case .failed:
            guard op != "config", client.beginFallbackAttempt() else { return nil }
            let result = runBackendStatusFallback(
                backendPath: backendPath,
                dataDir: dataDir,
                conversationId: conversationId,
                timeout: 3.0,
                cancelFD: client.cancellationFD
            )
            client.recordFallbackResult(success: result != nil)
            return result
        }
    }

    nonisolated private static func fetchRemoteConfigOnly(
        client: BackendLinesClient,
        backendPath: String,
        dataDir: String?
    ) -> NotchRemoteConfig? {
        guard let json = queryBackend(
            client: client,
            backendPath: backendPath,
            dataDir: dataDir,
            conversationId: "",
            op: "config",
            includeShared: true
        ) else {
            return nil
        }
        return parseRemoteConfig(from: json)
    }

    nonisolated private static func parseRemoteConfig(from json: [String: Any]) -> NotchRemoteConfig? {
        guard let cfg = json["config"] as? [String: Any],
              let notch = cfg["notch"] as? [String: Any] else {
            return nil
        }
        var rc = NotchRemoteConfig()
        if let en = notch["enabled"] as? Bool { rc.enabled = en }
        if let hideIdle = notch["hideWhenIdle"] as? Bool { rc.hideWhenIdle = hideIdle }
        if let sm = notch["screenMode"] as? String, let parsed = ScreenDisplayMode(rawValue: sm) {
            rc.screenMode = parsed
        }
        if let am = notch["avoidanceMode"] as? String, let parsed = NotchAvoidanceMode(rawValue: am) {
            rc.avoidanceMode = parsed
        }
        return rc
    }

    nonisolated private static func runBackendStatusFallback(
        backendPath: String,
        dataDir: String? = nil,
        conversationId: String? = nil,
        timeout: TimeInterval = 3.0,
        cancelFD: Int32 = -1
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

        let readHandle = pipe.fileHandleForReading
        let stdoutFD = readHandle.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var chunkBuf = [UInt8](repeating: 0, count: 4096)
        var timedOutOrCancelled = false

        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOutOrCancelled = true
                break
            }
            let waitMs = Int32(min(max(remaining * 1000.0, 1.0), 1000.0))
            var fds = [
                pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: cancelFD, events: Int16(POLLIN), revents: 0)
            ]
            let nfds: nfds_t = cancelFD >= 0 ? 2 : 1
            let ready = Darwin.poll(&fds, nfds, waitMs)
            if ready < 0 {
                if errno == EINTR { continue }
                timedOutOrCancelled = true
                break
            }
            if ready == 0 {
                continue
            }
            if nfds == 2 && (fds[1].revents & Int16(POLLIN)) != 0 {
                timedOutOrCancelled = true
                break
            }
            if (fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR)) != 0 {
                let n = Darwin.read(stdoutFD, &chunkBuf, chunkBuf.count)
                if n > 0 {
                    data.append(contentsOf: chunkBuf[0..<n])
                } else if n == 0 {
                    break
                } else if errno == EINTR || errno == EAGAIN {
                    continue
                } else {
                    timedOutOrCancelled = true
                    break
                }
            }
        }

        try? readHandle.close()
        if timedOutOrCancelled {
            if process.isRunning {
                process.terminate()
                let killDeadline = Date().addingTimeInterval(0.15)
                while process.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                }
            }
            process.waitUntilExit()
            return nil
        }

        let exitDeadline = Date().addingTimeInterval(0.25)
        while process.isRunning && Date() < exitDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error"] == nil, json["found"] is Bool else {
            return nil
        }
        return json
    }

    nonisolated private static let isoLock = NSLock()
    nonisolated(unsafe) private static let isoFormatterWithFrac: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()
    nonisolated(unsafe) private static let isoFormatterPlain: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt
    }()

    nonisolated private static func isWithinSeconds(_ isoString: String?, seconds: TimeInterval) -> Bool {
        guard let isoString, !isoString.isEmpty else { return false }
        isoLock.lock()
        let date = isoFormatterWithFrac.date(from: isoString) ?? isoFormatterPlain.date(from: isoString)
        isoLock.unlock()
        guard let date else { return false }
        return abs(Date().timeIntervalSince(date)) <= seconds
    }

    nonisolated static func fetchSnapshot(
        client: BackendLinesClient,
        backendPath: String,
        dataDir: String? = nil,
        previouslyActiveIds: Set<String>
    ) -> NotchSnapshot? {
        var map: [String: ActiveTaskItem] = [:]
        for cid in previouslyActiveIds {
            map[cid] = ActiveTaskItem(
                id: cid,
                title: String(cid.prefix(8)),
                commandText: "运行中",
                modelName: "",
                workspaceName: "",
                state: .running,
                stateLabel: "运行中",
                tokPerSec: nil,
                contextPct: nil,
                isRunning: true,
                code: ""
            )
        }
        return fetchSnapshot(
            client: client,
            backendPath: backendPath,
            dataDir: dataDir,
            previouslyActiveTasks: map
        )
    }

    nonisolated static func fetchSnapshot(
        client: BackendLinesClient,
        backendPath: String,
        dataDir: String? = nil,
        previouslyActiveTasks: [String: ActiveTaskItem]
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
        snap.remoteConfig = parseRemoteConfig(from: json)

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
        var totalActiveCount = 0
        var activeCountTruncated = false

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
                totalActiveCount += 1
            }
        }

        if let recent = json["recentConversations"] as? [[String: Any]] {
            struct Candidate {
                let index: Int
                let item: [String: Any]
                let cid: String
                let wasActive: Bool
                let shouldProbe: Bool
                let priority: Int
            }
            var candidates: [Candidate] = []
            candidates.reserveCapacity(recent.count)
            for (idx, item) in recent.enumerated() {
                let cid = (item["conversationId"] as? String) ?? ""
                if cid.isEmpty || cid == convId { continue }
                let hookFlag = (item["isActive"] as? Bool) ?? false
                let lastEvent = (item["lastEvent"] as? String) ?? ""
                let eventActive = lastEvent == "PreInvocation" || lastEvent == "PostInvocation"
                let wasActive = previouslyActiveTasks[cid] != nil
                let recentlyUpdated = isWithinSeconds(item["updatedAt"] as? String, seconds: 180)
                let shouldProbe = hookFlag || eventActive || wasActive || recentlyUpdated
                let priority = wasActive ? 3 : ((hookFlag || eventActive) ? 2 : (recentlyUpdated ? 1 : 0))
                candidates.append(Candidate(
                    index: idx,
                    item: item,
                    cid: cid,
                    wasActive: wasActive,
                    shouldProbe: shouldProbe,
                    priority: priority
                ))
            }
            // Prioritize previously active sessions first so probe budget is spent
            // on active tasks before merely recently-updated historical sessions.
            candidates.sort { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.index < rhs.index
            }

            let maxProbes = 8
            var probedCount = 0
            for cand in candidates {
                let item = cand.item
                let cid = cand.cid

                if !cand.shouldProbe && recentList.count >= 4 { continue }

                var ws = (item["workspace"] as? String) ?? ""
                var model = (item["modelName"] as? String) ?? ""
                var transcriptPath = (item["transcriptPath"] as? String) ?? ""

                var active = false
                var state: NotchSnapshot.RunState = .idle
                var label = "已完成"
                var tok: Double? = nil
                var ctx: Double? = nil
                var code = ""
                var preservedTitle: String? = nil
                var preservedCmd: String? = nil

                if cand.shouldProbe {
                    if probedCount < maxProbes {
                        probedCount += 1
                        if let subJson = queryBackend(client: client, backendPath: backendPath, dataDir: dataDir, conversationId: cid, includeShared: false) {
                            let parsed = parseStateAndSpeed(from: subJson)
                            active = parsed.isActive
                            state = parsed.state
                            label = parsed.label
                            code = parsed.code
                            if let subPath = subJson["transcriptPath"] as? String, !subPath.isEmpty {
                                transcriptPath = subPath
                            }
                            tok = parsed.tokPerSec
                            ctx = subJson["contextPct"] as? Double
                            if ws.isEmpty, let subWs = subJson["workspaceName"] as? String {
                                ws = subWs
                            }
                            if model.isEmpty, let subModel = subJson["modelName"] as? String {
                                model = subModel
                            }
                        } else if let prev = previouslyActiveTasks[cid] {
                            // Transient backend query failure: preserve previous state and avoid false completion peek.
                            active = prev.isRunning
                            state = prev.state
                            label = prev.stateLabel
                            tok = nil
                            ctx = prev.contextPct
                            code = prev.code
                            if ws.isEmpty { ws = prev.workspaceName }
                            if model.isEmpty { model = prev.modelName }
                            preservedTitle = prev.title
                            preservedCmd = prev.commandText
                        } else {
                            label = "状态未知"
                            code = "unknown"
                        }
                    } else {
                        // Probe budget exhausted: do not misreport as completed.
                        activeCountTruncated = true
                        if let prev = previouslyActiveTasks[cid] {
                            active = prev.isRunning
                            state = prev.state
                            label = prev.stateLabel
                            tok = nil
                            ctx = prev.contextPct
                            code = prev.code
                            if ws.isEmpty { ws = prev.workspaceName }
                            if model.isEmpty { model = prev.modelName }
                            preservedTitle = prev.title
                            preservedCmd = prev.commandText
                        } else {
                            label = "状态未知"
                            code = "unknown"
                        }
                    }
                }

                if active {
                    totalActiveCount += 1
                }

                if !active && recentList.count >= 4 { continue }
                if active && tasks.count >= 4 {
                    // Already filled the 4 displayed active task slots; keep counting totalActiveCount.
                    continue
                }

                let tInfo = parseTranscriptTail(path: transcriptPath)
                let title = !tInfo.title.isEmpty ? tInfo.title : (preservedTitle ?? (!ws.isEmpty ? ws : String(cid.prefix(8))))
                let cmd = !tInfo.command.isEmpty ? tInfo.command : (preservedCmd ?? label)
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
        snap.activeCount = totalActiveCount
        snap.activeCountTruncated = activeCountTruncated
        if totalActiveCount > 0 {
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

    nonisolated static func resolveCliTerminalTarget(env: [String: String]) -> (bundleId: String?, appName: String?) {
        let cfBundle = (env["__CFBundleIdentifier"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let termProgram = (env["TERM_PROGRAM"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let mapped: (String, String)? = switch termProgram {
        case "ghostty": ("com.mitchellh.ghostty", "Ghostty")
        case "iterm.app": ("com.googlecode.iterm2", "iTerm2")
        case "apple_terminal": ("com.apple.Terminal", "Terminal")
        case "warpterminal": ("dev.warp.Warp-Stable", "Warp")
        case "wezterm": ("com.github.wez.wezterm", "WezTerm")
        case "alacritty": ("org.alacritty", "Alacritty")
        case "kitty": ("net.kovidgoyal.kitty", "kitty")
        case "vscode": ("com.microsoft.VSCode", "Visual Studio Code")
        case "cursor": ("com.todesktop.230313mzl4w4u92", "Cursor")
        case "zed": ("dev.zed.Zed", "Zed")
        default: nil
        }

        if !cfBundle.isEmpty, !cfBundle.lowercased().contains("antigravity") {
            return (cfBundle, mapped?.1)
        }
        if let mapped {
            return (mapped.0, mapped.1)
        }
        return (nil, nil)
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

    private struct CachedTranscriptTail {
        let size: UInt64
        let mtimeSec: Int
        let mtimeNsec: Int
        let inode: UInt64
        let head: Data
        let headTitle: String
        let title: String
        let command: String
    }

    nonisolated private static let transcriptCacheLock = NSLock()
    nonisolated(unsafe) private static var transcriptTailCache: [String: CachedTranscriptTail] = [:]

    nonisolated static func parseTranscriptTail(path: String) -> (title: String, command: String) {
        guard !path.isEmpty else { return ("", "") }

        var st = stat()
        guard stat(path, &st) == 0 else { return ("", "") }
        let fileSize = UInt64(max(0, st.st_size))
        let mtimeSec = st.st_mtimespec.tv_sec
        let mtimeNsec = st.st_mtimespec.tv_nsec

        transcriptCacheLock.lock()
        let cached = transcriptTailCache[path]
        if let cached,
           cached.inode == UInt64(st.st_ino),
           cached.size == fileSize,
           cached.mtimeSec == mtimeSec,
           cached.mtimeNsec == mtimeNsec {
            transcriptCacheLock.unlock()
            return (cached.title, cached.command)
        }
        transcriptCacheLock.unlock()

        let result: (title: String, command: String, head: Data, headTitle: String) = autoreleasepool {
            guard let handle = FileHandle(forReadingAtPath: path) else { return ("", "", Data(), "") }
            defer { try? handle.close() }

            var title = ""
            var titlePrefix = Data()
            let headData = handle.readData(ofLength: 16384)
            // Validate the bytes through the title: growth alone does not prove
            // append-only writes. Retain only this prefix, not the whole head.
            if let cached, !cached.headTitle.isEmpty,
               cached.inode == UInt64(st.st_ino), fileSize >= cached.size,
               headData.starts(with: cached.head) {
                title = cached.headTitle
                titlePrefix = cached.head
            } else {
                let headText = String(decoding: headData, as: UTF8.self)
                var prefixLength = 0
                for line in headText.split(separator: "\n", maxSplits: 6, omittingEmptySubsequences: false) {
                    prefixLength += line.utf8.count + 1
                    guard let lineData = line.data(using: .utf8),
                          let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                    if (obj["type"] as? String) == "USER_INPUT",
                       let content = obj["content"] as? String {
                        title = cleanUserRequest(content)
                        if !title.isEmpty {
                            titlePrefix = Data(headData.prefix(prefixLength))
                            break
                        }
                    }
                }
            }
            let headTitle = title

            var command = ""
            let tailOffset: UInt64 = fileSize > 32768 ? fileSize - 32768 : 0
            try? handle.seek(toOffset: tailOffset)
            let tailData = handle.readData(ofLength: 32768)
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

            return (title, command, titlePrefix, headTitle)
        }

        transcriptCacheLock.lock()
        if transcriptTailCache[path] == nil && transcriptTailCache.count >= 64 {
            transcriptTailCache.removeAll(keepingCapacity: true)
        }
        transcriptTailCache[path] = CachedTranscriptTail(
            size: fileSize,
            mtimeSec: mtimeSec,
            mtimeNsec: mtimeNsec,
            inode: UInt64(st.st_ino),
            head: result.head,
            headTitle: result.headTitle,
            title: result.title,
            command: result.command
        )
        transcriptCacheLock.unlock()

        return (result.title, result.command)
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
