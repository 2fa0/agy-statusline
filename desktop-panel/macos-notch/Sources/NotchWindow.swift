import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPanelController {
    let screenID: CGDirectDisplayID
    private(set) var screen: NSScreen
    private let store: NotchStore
    private let panel: NotchPanel
    private let hostingView: NSHostingView<NotchView>
    private let onActivateApp: () -> Void
    private let onBuildContextMenu: () -> NSMenu

    private let maxPanelWidth: CGFloat = 520
    private let maxPanelHeight: CGFloat = 360
    private var hasNotch: Bool = false
    private var notchWidth: CGFloat = 180
    private var notchHeight: CGFloat = 34
    private var topOffset: CGFloat = 0
    private var isFloatingPill: Bool = false

    private var renderedPillFrameInPanel: CGRect = .zero
    private var debouncedOccupiedOffset: CGFloat = 0
    private var occupiedStreak: Int = 0
    private var clearStreak: Int = 0

    private var isInsideLocally = false
    private var hoverEnterWorkItem: DispatchWorkItem?
    private var hoverLeaveWorkItem: DispatchWorkItem?

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var rightClickMonitor: Any?

    init(
        screen: NSScreen,
        screenID: CGDirectDisplayID,
        store: NotchStore,
        onActivateApp: @escaping () -> Void,
        onBuildContextMenu: @escaping () -> NSMenu
    ) {
        self.screen = screen
        self.screenID = screenID
        self.store = store
        self.onActivateApp = onActivateApp
        self.onBuildContextMenu = onBuildContextMenu

        let metrics = Self.computeMetrics(for: screen)
        self.hasNotch = metrics.hasNotch
        self.notchWidth = metrics.width
        self.notchHeight = metrics.height

        if store.avoidanceMode == .autoStackBelow {
            let raw = Self.detectOccupiedBottomOffset(for: screen, notchWidth: metrics.width)
            self.debouncedOccupiedOffset = raw
            self.occupiedStreak = raw > 0 ? 2 : 0
            self.clearStreak = raw > 0 ? 0 : 2
        }

        let layout = Self.computeLayout(
            for: screen,
            mode: store.avoidanceMode,
            occupiedOffset: debouncedOccupiedOffset
        )
        self.topOffset = layout.topOffset
        self.isFloatingPill = layout.isFloating

        let placeholderView = NotchView(
            store: store,
            hasNotch: metrics.hasNotch,
            hardwareNotchWidth: metrics.width,
            hardwareNotchHeight: metrics.height,
            isFloatingPill: layout.isFloating,
            onActivateApp: onActivateApp,
            onOpenMenu: {},
            onPillFrameChange: { _ in }
        )
        self.hostingView = NSHostingView(rootView: placeholderView)

        let frame = Self.panelFrame(
            for: screen,
            width: maxPanelWidth,
            height: maxPanelHeight,
            topOffset: layout.topOffset,
            topRight: layout.topRight
        )
        self.panel = NotchPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView

        hostingView.rootView = makeRootView()
        installMouseMonitors()
        panel.orderFrontRegardless()
    }

    deinit {
        hoverEnterWorkItem?.cancel()
        hoverLeaveWorkItem?.cancel()
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = rightClickMonitor { NSEvent.removeMonitor(m) }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
            }
        }
    }

    private func makeRootView() -> NotchView {
        NotchView(
            store: store,
            hasNotch: hasNotch,
            hardwareNotchWidth: notchWidth,
            hardwareNotchHeight: notchHeight,
            isFloatingPill: isFloatingPill,
            onActivateApp: onActivateApp,
            onOpenMenu: { [weak self] in
                self?.openContextMenuFromButton()
            },
            onPillFrameChange: { [weak self] rect in
                self?.renderedPillFrameInPanel = rect
            }
        )
    }

    private func openContextMenuFromButton() {
        let menu = onBuildContextMenu()
        let pillRect = currentVisiblePillRectInScreen()
        let anchor = NSPoint(
            x: pillRect.maxX - panel.frame.minX - 24,
            y: max(4, pillRect.minY - panel.frame.minY)
        )
        menu.popUp(positioning: nil, at: anchor, in: hostingView)
    }

    func updateScreen(_ newScreen: NSScreen) {
        self.screen = newScreen
        let metrics = Self.computeMetrics(for: newScreen)
        self.hasNotch = metrics.hasNotch
        self.notchWidth = metrics.width
        self.notchHeight = metrics.height
        refreshAvoidanceLayout(immediate: true)
    }

    func refreshAvoidanceLayout(immediate: Bool = false) {
        if store.avoidanceMode == .autoStackBelow {
            let raw = Self.detectOccupiedBottomOffset(for: screen, notchWidth: notchWidth)
            if immediate {
                debouncedOccupiedOffset = raw
                occupiedStreak = raw > 0 ? 2 : 0
                clearStreak = raw > 0 ? 0 : 2
            } else if raw > 0 {
                occupiedStreak += 1
                clearStreak = 0
                if occupiedStreak >= 2 {
                    debouncedOccupiedOffset = raw
                }
            } else {
                clearStreak += 1
                occupiedStreak = 0
                if clearStreak >= 2 {
                    debouncedOccupiedOffset = 0
                }
            }
        } else {
            debouncedOccupiedOffset = 0
            occupiedStreak = 0
            clearStreak = 0
        }

        let layout = Self.computeLayout(
            for: screen,
            mode: store.avoidanceMode,
            occupiedOffset: debouncedOccupiedOffset
        )
        let changed = abs(layout.topOffset - topOffset) > 1.0 || layout.isFloating != isFloatingPill
        self.topOffset = layout.topOffset
        self.isFloatingPill = layout.isFloating
        if changed {
            hostingView.rootView = makeRootView()
        }
        let targetFrame = Self.panelFrame(
            for: screen,
            width: maxPanelWidth,
            height: maxPanelHeight,
            topOffset: layout.topOffset,
            topRight: layout.topRight
        )
        if panel.frame != targetFrame {
            panel.setFrame(targetFrame, display: true, animate: changed)
        }
    }

    func setVisible(_ visible: Bool) {
        if visible {
            panel.orderFrontRegardless()
        } else {
            cancelHoverTimers()
            isInsideLocally = false
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
        }
    }

    private func currentVisiblePillRectInScreen() -> CGRect {
        if renderedPillFrameInPanel.width > 1, renderedPillFrameInPanel.height > 1 {
            let x = panel.frame.minX + renderedPillFrameInPanel.minX
            let y = panel.frame.maxY - renderedPillFrameInPanel.maxY
            return CGRect(
                x: x,
                y: y,
                width: renderedPillFrameInPanel.width,
                height: renderedPillFrameInPanel.height
            )
        }

        // Minimal fallback strictly before the first SwiftUI geometry pass completes.
        let fallbackW = max(notchWidth, 132)
        let fallbackH = max(notchHeight, 34)
        let x = panel.frame.midX - fallbackW / 2
        let y = panel.frame.maxY - fallbackH
        return CGRect(x: x, y: y, width: fallbackW, height: fallbackH)
    }

    private func cancelHoverTimers() {
        hoverEnterWorkItem?.cancel()
        hoverEnterWorkItem = nil
        hoverLeaveWorkItem?.cancel()
        hoverLeaveWorkItem = nil
    }

    private func handleMousePoint(_ screenPoint: NSPoint) {
        guard !store.isHiddenByUser else {
            cancelHoverTimers()
            isInsideLocally = false
            panel.ignoresMouseEvents = true
            return
        }

        let hitRect = currentVisiblePillRectInScreen().insetBy(dx: -6, dy: -6)
        let inside = hitRect.contains(screenPoint)
        panel.ignoresMouseEvents = !inside

        if inside {
            hoverLeaveWorkItem?.cancel()
            hoverLeaveWorkItem = nil

            if !isInsideLocally {
                isInsideLocally = true
                if !store.isHovering && hoverEnterWorkItem == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.hoverEnterWorkItem = nil
                        if self.isInsideLocally && !self.store.isHiddenByUser {
                            self.store.isHovering = true
                        }
                    }
                    hoverEnterWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
                }
            }
        } else {
            hoverEnterWorkItem?.cancel()
            hoverEnterWorkItem = nil

            if isInsideLocally {
                isInsideLocally = false
                if store.isHovering && hoverLeaveWorkItem == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.hoverLeaveWorkItem = nil
                        if !self.isInsideLocally {
                            self.store.isHovering = false
                        }
                    }
                    hoverLeaveWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
                }
            }
        }
    }

    private func installMouseMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMousePoint(NSEvent.mouseLocation)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            self?.handleMousePoint(NSEvent.mouseLocation)
            return event
        }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let menu = self.onBuildContextMenu()
            NSMenu.popUpContextMenu(menu, with: event, for: self.hostingView)
            return nil
        }
    }

    private static func computeMetrics(for screen: NSScreen) -> (hasNotch: Bool, width: CGFloat, height: CGFloat) {
        let topInset = screen.safeAreaInsets.top
        let hasNotch = topInset > 0
        var width: CGFloat = 180
        if hasNotch,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           left.width > 0, right.width > 0 {
            let computed = screen.frame.width - left.width - right.width
            if computed > 80 && computed < 360 {
                width = computed
            }
        }
        return (hasNotch, width, hasNotch ? topInset : 30)
    }

    private static func computeLayout(
        for screen: NSScreen,
        mode: NotchAvoidanceMode,
        occupiedOffset: CGFloat
    ) -> (topOffset: CGFloat, isFloating: Bool, topRight: Bool) {
        switch mode {
        case .forceNotch:
            return (0, false, false)
        case .topRight:
            let barH = max(screen.safeAreaInsets.top, 28)
            return (barH + 6, true, true)
        case .autoStackBelow:
            if occupiedOffset > 0 {
                return (occupiedOffset, true, false)
            }
            return (0, false, false)
        }
    }

    private static func detectOccupiedBottomOffset(for screen: NSScreen, notchWidth: CGFloat) -> CGFloat {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return 0
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        let ignoredOwners: Set<String> = [
            "WindowServer", "Dock", "SystemUIServer",
            "Control Center", "ControlCenter",
            "Notification Center", "NotificationCenter",
            "Spotlight", "WindowManager"
        ]
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let screenTopCG = primaryHeight - screen.frame.maxY
        let notchMinX = screen.frame.midX - notchWidth / 2 - 12
        let notchMaxX = screen.frame.midX + notchWidth / 2 + 12
        let minLayer = Int(CGWindowLevelForKey(.statusWindow))

        var maxBottomOffset: CGFloat = 0
        for win in list {
            guard let pid = win[kCGWindowOwnerPID as String] as? Int32, pid != myPID else { continue }
            if let owner = win[kCGWindowOwnerName as String] as? String, ignoredOwners.contains(owner) { continue }
            let layer = (win[kCGWindowLayer as String] as? Int) ?? 0
            guard layer >= minLayer else { continue }
            let alpha = (win[kCGWindowAlpha as String] as? Double) ?? 1.0
            guard alpha > 0.05 else { continue }
            guard let boundsDict = win[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }

            guard bounds.width >= 60, bounds.height >= 18, bounds.height <= 260 else { continue }
            let overlapsX = bounds.maxX >= notchMinX && bounds.minX <= notchMaxX
            let nearTop = abs(bounds.minY - screenTopCG) <= 14
            if overlapsX && nearTop {
                let offset = (bounds.maxY - screenTopCG) + 6
                if offset > maxBottomOffset {
                    maxBottomOffset = offset
                }
            }
        }
        return maxBottomOffset
    }

    private static func panelFrame(for screen: NSScreen, width: CGFloat, height: CGFloat, topOffset: CGFloat, topRight: Bool) -> CGRect {
        let x = topRight ? (screen.frame.maxX - width - 16) : (screen.frame.midX - width / 2)
        let y = screen.frame.maxY - topOffset - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor
final class NotchWindowManager: NSObject, NSMenuDelegate {
    private let store: NotchStore
    private var controllers: [CGDirectDisplayID: NotchPanelController] = [:]
    private var screenObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    private var mouseScreenTimer: Timer?
    private var occupancyTimer: Timer?

    init(store: NotchStore) {
        self.store = store
        super.init()
        rebuildPanels()
        startOccupancyTimer()
        updateFollowTimer(enabled: store.screenMode == .followActive)

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildPanels()
            }
        }

        store.$isHiddenByUser
            .receive(on: RunLoop.main)
            .sink { [weak self] hidden in
                if hidden {
                    self?.store.isHovering = false
                }
                self?.controllers.values.forEach { $0.setVisible(!hidden) }
            }
            .store(in: &cancellables)

        store.$screenMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.rebuildPanels()
                self?.updateFollowTimer(enabled: mode == .followActive)
            }
            .store(in: &cancellables)

        store.$avoidanceMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.controllers.values.forEach { $0.refreshAvoidanceLayout(immediate: true) }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs) }
        mouseScreenTimer?.invalidate()
        occupancyTimer?.invalidate()
    }

    private func startOccupancyTimer() {
        occupancyTimer?.invalidate()
        occupancyTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.store.avoidanceMode == .autoStackBelow else { return }
                self.controllers.values.forEach { $0.refreshAvoidanceLayout(immediate: false) }
            }
        }
    }

    private func updateFollowTimer(enabled: Bool) {
        mouseScreenTimer?.invalidate()
        guard enabled else { return }
        mouseScreenTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildPanels()
            }
        }
    }

    private func targetScreens() -> [NSScreen] {
        let all = NSScreen.screens
        guard !all.isEmpty else { return [] }
        switch store.screenMode {
        case .allScreens:
            return all
        case .followActive:
            let mouse = NSEvent.mouseLocation
            if let underMouse = all.first(where: { $0.frame.contains(mouse) }) {
                return [underMouse]
            }
            return [NSScreen.main ?? all[0]]
        case .notchOrMain:
            if let notched = all.first(where: { $0.safeAreaInsets.top > 0 }) {
                return [notched]
            }
            return [NSScreen.main ?? all[0]]
        }
    }

    func rebuildPanels() {
        let targets = targetScreens()
        var targetIDs = Set<CGDirectDisplayID>()

        for screen in targets {
            let sid = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            targetIDs.insert(sid)
            if let existing = controllers[sid] {
                existing.updateScreen(screen)
                existing.setVisible(!store.isHiddenByUser)
            } else {
                let ctrl = NotchPanelController(
                    screen: screen,
                    screenID: sid,
                    store: store,
                    onActivateApp: { [weak self] in self?.activateAntigravity() },
                    onBuildContextMenu: { [weak self] in self?.buildContextMenu() ?? NSMenu() }
                )
                ctrl.setVisible(!store.isHiddenByUser)
                controllers[sid] = ctrl
            }
        }

        for sid in Array(controllers.keys) where !targetIDs.contains(sid) {
            controllers.removeValue(forKey: sid)
        }
    }

    func activateAntigravity() {
        let running = NSWorkspace.shared.runningApplications
        if let app = running.first(where: {
            let name = ($0.localizedName ?? "").lowercased()
            let bid = ($0.bundleIdentifier ?? "").lowercased()
            return name.contains("antigravity") || bid.contains("antigravity")
        }) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Antigravity"]
        try? proc.run()
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        populateContextMenu(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateContextMenu(menu)
    }

    private func populateContextMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let refreshItem = NSMenuItem(title: "立即刷新状态", action: #selector(MenuActions.refreshNow), keyEquivalent: "r")
        refreshItem.target = MenuActions.shared
        menu.addItem(refreshItem)

        let hideTitle = store.isHiddenByUser ? "显示刘海状态栏" : "暂时隐藏刘海状态栏"
        let hideItem = NSMenuItem(title: hideTitle, action: #selector(MenuActions.toggleHidden), keyEquivalent: "h")
        hideItem.target = MenuActions.shared
        menu.addItem(hideItem)

        let idleHideItem = NSMenuItem(title: "空闲时隐入刘海", action: #selector(MenuActions.toggleHideWhenIdle), keyEquivalent: "")
        idleHideItem.target = MenuActions.shared
        idleHideItem.state = store.hideWhenIdle ? .on : .off
        menu.addItem(idleHideItem)

        menu.addItem(.separator())

        let screenSubmenu = NSMenu()
        for mode in ScreenDisplayMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(MenuActions.selectScreenMode(_:)), keyEquivalent: "")
            item.target = MenuActions.shared
            item.representedObject = mode.rawValue
            item.state = store.screenMode == mode ? .on : .off
            screenSubmenu.addItem(item)
        }
        let screenRoot = NSMenuItem(title: "多屏幕显示", action: nil, keyEquivalent: "")
        screenRoot.submenu = screenSubmenu
        menu.addItem(screenRoot)

        let avoidSubmenu = NSMenu()
        for mode in NotchAvoidanceMode.allCases {
            let item = NSMenuItem(title: mode.label, action: #selector(MenuActions.selectAvoidanceMode(_:)), keyEquivalent: "")
            item.target = MenuActions.shared
            item.representedObject = mode.rawValue
            item.state = store.avoidanceMode == mode ? .on : .off
            avoidSubmenu.addItem(item)
        }
        let avoidRoot = NSMenuItem(title: "刘海被占用时", action: nil, keyEquivalent: "")
        avoidRoot.submenu = avoidSubmenu
        menu.addItem(avoidRoot)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 agy-notch", action: #selector(MenuActions.quitApp), keyEquivalent: "q")
        quitItem.target = MenuActions.shared
        menu.addItem(quitItem)
    }
}

@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()
    weak var store: NotchStore?
    weak var manager: NotchWindowManager?

    @objc func refreshNow() {
        store?.refreshNow(force: true)
    }

    @objc func toggleHidden() {
        store?.isHiddenByUser.toggle()
    }

    @objc func toggleHideWhenIdle() {
        store?.hideWhenIdle.toggle()
    }

    @objc func selectScreenMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ScreenDisplayMode(rawValue: raw) else { return }
        store?.screenMode = mode
    }

    @objc func selectAvoidanceMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = NotchAvoidanceMode(rawValue: raw) else { return }
        store?.avoidanceMode = mode
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}
