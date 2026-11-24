import AppKit
import Combine
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct OccupancyState {
    private(set) var offset: CGFloat = 0
    private var candidate: CGFloat?

    mutating func update(_ raw: CGFloat, immediate: Bool) -> Bool {
        if immediate || candidate == raw {
            offset = raw
            candidate = nil
        } else if raw != offset {
            candidate = raw
        } else {
            candidate = nil
        }
        return candidate != nil
    }
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
    private var occupancy = OccupancyState()

    private var isInsideLocally = false
    private var hoverEnterWorkItem: DispatchWorkItem?
    private var hoverLeaveWorkItem: DispatchWorkItem?

    var panelWindow: NSWindow { panel }

    init(
        screen: NSScreen,
        screenID: CGDirectDisplayID,
        store: NotchStore,
        occupantBounds: [CGRect],
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
            let raw = Self.detectOccupiedBottomOffset(for: screen, notchWidth: metrics.width, bounds: occupantBounds)
            _ = occupancy.update(raw, immediate: true)
        }

        let layout = Self.computeLayout(
            for: screen,
            mode: store.avoidanceMode,
            occupiedOffset: occupancy.offset
        )
        self.topOffset = layout.topOffset
        self.isFloatingPill = layout.isFloating

        let placeholderView = NotchView(
            store: store,
            screenID: screenID,
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
        panel.orderFrontRegardless()
    }

    deinit {
        hoverEnterWorkItem?.cancel()
        hoverLeaveWorkItem?.cancel()
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                panel.orderOut(nil)
            }
        }
    }

    private func makeRootView() -> NotchView {
        NotchView(
            store: store,
            screenID: screenID,
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

    func showContextMenu(with event: NSEvent) {
        let menu = onBuildContextMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: hostingView)
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

    func updateScreen(_ newScreen: NSScreen, occupantBounds: [CGRect]) {
        self.screen = newScreen
        let metrics = Self.computeMetrics(for: newScreen)
        let metricsChanged = (metrics.hasNotch != hasNotch)
            || abs(metrics.width - notchWidth) > 0.5
            || abs(metrics.height - notchHeight) > 0.5
        self.hasNotch = metrics.hasNotch
        self.notchWidth = metrics.width
        self.notchHeight = metrics.height
        refreshAvoidanceLayout(occupantBounds: occupantBounds, immediate: true, forceRebuildView: metricsChanged)
    }

    @discardableResult
    func refreshAvoidanceLayout(
        occupantBounds: [CGRect],
        immediate: Bool = false,
        forceRebuildView: Bool = false
    ) -> Bool {
        let raw = store.avoidanceMode == .autoStackBelow
            ? Self.detectOccupiedBottomOffset(for: screen, notchWidth: notchWidth, bounds: occupantBounds)
            : 0
        let needsConfirmation = occupancy.update(raw, immediate: immediate || store.avoidanceMode != .autoStackBelow)

        let layout = Self.computeLayout(
            for: screen,
            mode: store.avoidanceMode,
            occupiedOffset: occupancy.offset
        )
        let changed = abs(layout.topOffset - topOffset) > 1.0 || layout.isFloating != isFloatingPill
        self.topOffset = layout.topOffset
        self.isFloatingPill = layout.isFloating
        if changed || forceRebuildView {
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
        return needsConfirmation
    }

    func setVisible(_ visible: Bool) {
        if visible {
            panel.orderFrontRegardless()
        } else {
            cancelHoverTimers()
            isInsideLocally = false
            if store.hoveredScreenID == screenID {
                store.hoveredScreenID = nil
            }
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

    func handleMousePoint(_ screenPoint: NSPoint) {
        if store.isHidden {
            if isInsideLocally || hoverEnterWorkItem != nil || hoverLeaveWorkItem != nil {
                cancelHoverTimers()
                isInsideLocally = false
            }
            if !panel.ignoresMouseEvents {
                panel.ignoresMouseEvents = true
            }
            return
        }

        let isThisScreenHovered = store.hoveredScreenID == screenID

        // Fast-path reject when cursor is far outside the panel bounds and not tracking hover.
        let pFrame = panel.frame
        if !isInsideLocally && !isThisScreenHovered {
            if screenPoint.y < pFrame.minY - 12
                || screenPoint.x < pFrame.minX - 12
                || screenPoint.x > pFrame.maxX + 12 {
                if !panel.ignoresMouseEvents {
                    panel.ignoresMouseEvents = true
                }
                return
            }
        }

        let hitRect = currentVisiblePillRectInScreen().insetBy(dx: -6, dy: -6)
        let inside = hitRect.contains(screenPoint)
        if panel.ignoresMouseEvents != !inside {
            panel.ignoresMouseEvents = !inside
        }

        if inside {
            hoverLeaveWorkItem?.cancel()
            hoverLeaveWorkItem = nil

            if !isInsideLocally {
                isInsideLocally = true
                if !isThisScreenHovered && hoverEnterWorkItem == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.hoverEnterWorkItem = nil
                        if self.isInsideLocally && !self.store.isHidden {
                            self.store.hoveredScreenID = self.screenID
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
                if isThisScreenHovered && hoverLeaveWorkItem == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.hoverLeaveWorkItem = nil
                        if !self.isInsideLocally && self.store.hoveredScreenID == self.screenID {
                            self.store.hoveredScreenID = nil
                        }
                    }
                    hoverLeaveWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
                }
            }
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

    nonisolated private static let ignoredOwners: Set<String> = [
        "WindowServer", "Dock", "SystemUIServer",
        "Control Center", "ControlCenter",
        "Notification Center", "NotificationCenter",
        "Spotlight", "WindowManager"
    ]

    nonisolated static func occupiedBottomOffset(
        for bounds: CGRect,
        screenFrame: CGRect,
        screenTopCG: CGFloat,
        notchWidth: CGFloat
    ) -> CGFloat? {
        let maxOccupantWidth = min(screenFrame.width * 0.75, 860)
        guard bounds.width >= 60,
              bounds.width <= maxOccupantWidth,
              bounds.height >= 18,
              bounds.height <= 260 else {
            return nil
        }
        let notchMinX = screenFrame.midX - notchWidth / 2 - 12
        let notchMaxX = screenFrame.midX + notchWidth / 2 + 12
        let overlapsX = bounds.maxX >= notchMinX && bounds.minX <= notchMaxX
        let nearTop = abs(bounds.minY - screenTopCG) <= 14
        guard overlapsX && nearTop else { return nil }
        return (bounds.maxY - screenTopCG) + 6
    }

    nonisolated static func occupantBounds() -> [CGRect] {
        autoreleasepool {
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                return []
            }
            let myPID = ProcessInfo.processInfo.processIdentifier
            let minLayer = Int(CGWindowLevelForKey(.statusWindow))
            return list.compactMap { win in
                guard let pid = win[kCGWindowOwnerPID as String] as? Int32, pid != myPID else { return nil }
                if let owner = win[kCGWindowOwnerName as String] as? String, ignoredOwners.contains(owner) { return nil }
                guard ((win[kCGWindowLayer as String] as? Int) ?? 0) >= minLayer,
                      ((win[kCGWindowAlpha as String] as? Double) ?? 1.0) > 0.05,
                      let boundsDict = win[kCGWindowBounds as String] as? NSDictionary else { return nil }
                return CGRect(dictionaryRepresentation: boundsDict)
            }
        }
    }

    private static func detectOccupiedBottomOffset(for screen: NSScreen, notchWidth: CGFloat, bounds: [CGRect]) -> CGFloat {
        let screenTopCG = CGDisplayBounds(CGMainDisplayID()).height - screen.frame.maxY
        return bounds.compactMap {
            occupiedBottomOffset(for: $0, screenFrame: screen.frame, screenTopCG: screenTopCG, notchWidth: notchWidth)
        }.max() ?? 0
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
    private var occupancyConfirmation: DispatchWorkItem?
    private let occupancyQueue = DispatchQueue(label: "agy.notch.occupancy", qos: .utility)
    private var isScanningOccupancy = false

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var rightClickMonitor: Any?
    private var recoveryStatusItem: NSStatusItem?

    init(store: NotchStore) {
        self.store = store
        super.init()
        rebuildPanels()
        startOccupancyTimer()
        updateFollowTimer(enabled: store.screenMode == .followActive)
        updateMouseMonitors()
        updateRecoveryStatusItem()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildPanels()
            }
        }

        Publishers.CombineLatest(store.$isTemporarilyHidden, store.$isHiddenByUser)
            .receive(on: RunLoop.main)
            .sink { [weak self] tempHidden, disabled in
                guard let self else { return }
                let hidden = tempHidden || disabled
                if hidden {
                    self.store.hoveredScreenID = nil
                }
                self.controllers.values.forEach { $0.setVisible(!hidden) }
                self.updateMouseMonitors()
                self.updateRecoveryStatusItem()
                self.updateOccupancyTimer(enabled: self.store.avoidanceMode == .autoStackBelow)
                if !hidden { self.refreshOccupancy(immediate: true) }
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
            .sink { [weak self] mode in
                self?.refreshOccupancy(immediate: true)
                self?.updateOccupancyTimer(enabled: mode == .autoStackBelow)
            }
            .store(in: &cancellables)
    }

    deinit {
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs) }
        mouseScreenTimer?.invalidate()
        occupancyTimer?.invalidate()
        occupancyConfirmation?.cancel()
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = rightClickMonitor { NSEvent.removeMonitor(m) }
        if let item = recoveryStatusItem, Thread.isMainThread {
            MainActor.assumeIsolated {
                NSStatusBar.system.removeStatusItem(item)
            }
        }
    }

    private func updateMouseMonitors() {
        let shouldMonitor = !store.isHidden && !controllers.isEmpty
        if shouldMonitor {
            if globalMouseMonitor == nil {
                globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.dispatchMousePoint(NSEvent.mouseLocation)
                    }
                }
            }
            if localMouseMonitor == nil {
                localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
                    self?.dispatchMousePoint(NSEvent.mouseLocation)
                    return event
                }
            }
            if rightClickMonitor == nil {
                rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
                    guard let self, let win = event.window else { return event }
                    if let controller = self.controllers.values.first(where: { $0.panelWindow === win }) {
                        controller.showContextMenu(with: event)
                        return nil
                    }
                    return event
                }
            }
        } else {
            if let m = globalMouseMonitor {
                NSEvent.removeMonitor(m)
                globalMouseMonitor = nil
            }
            if let m = localMouseMonitor {
                NSEvent.removeMonitor(m)
                localMouseMonitor = nil
            }
            if let m = rightClickMonitor {
                NSEvent.removeMonitor(m)
                rightClickMonitor = nil
            }
        }
    }

    private func dispatchMousePoint(_ point: NSPoint) {
        for controller in controllers.values {
            controller.handleMousePoint(point)
        }
    }

    /// Shows a minimal menu bar icon only while temporarily hidden so the user
    /// always has a discoverable one-click way to restore the notch.
    private func updateRecoveryStatusItem() {
        let shouldShow = store.isTemporarilyHidden && !store.isHiddenByUser
        if shouldShow {
            if recoveryStatusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
                if let button = item.button {
                    button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "显示 agy-notch")
                    button.toolTip = "agy-notch 已暂时隐藏（点击恢复）"
                }
                let menu = NSMenu()
                let showItem = NSMenuItem(title: "显示刘海状态栏", action: #selector(MenuActions.restoreFromTemporaryHide), keyEquivalent: "")
                showItem.target = MenuActions.shared
                menu.addItem(showItem)
                let disableItem = NSMenuItem(title: "关闭刘海状态栏（可在设置中重新开启）", action: #selector(MenuActions.disableNotch), keyEquivalent: "")
                disableItem.target = MenuActions.shared
                menu.addItem(disableItem)
                menu.addItem(.separator())
                let quitItem = NSMenuItem(title: "退出 agy-notch", action: #selector(MenuActions.quitApp), keyEquivalent: "q")
                quitItem.target = MenuActions.shared
                menu.addItem(quitItem)
                item.menu = menu
                recoveryStatusItem = item
            }
        } else if let item = recoveryStatusItem {
            NSStatusBar.system.removeStatusItem(item)
            recoveryStatusItem = nil
        }
    }

    private func startOccupancyTimer() {
        updateOccupancyTimer(enabled: store.avoidanceMode == .autoStackBelow)
    }

    private func updateOccupancyTimer(enabled: Bool) {
        occupancyTimer?.invalidate()
        occupancyTimer = nil
        occupancyConfirmation?.cancel()
        occupancyConfirmation = nil
        guard enabled, !store.isHidden else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      !self.store.isHidden,
                      self.store.avoidanceMode == .autoStackBelow else { return }
                self.refreshOccupancy(immediate: false)
            }
        }
        t.tolerance = 0.5
        occupancyTimer = t
    }

    private func refreshOccupancy(immediate: Bool, confirming: Bool = false) {
        guard !store.isHidden else { return }
        if store.avoidanceMode != .autoStackBelow {
            applyOccupancyBounds([], immediate: immediate, confirming: confirming)
            return
        }
        if immediate {
            let bounds = NotchPanelController.occupantBounds()
            applyOccupancyBounds(bounds, immediate: true, confirming: confirming)
            return
        }
        guard !isScanningOccupancy else { return }
        isScanningOccupancy = true
        occupancyQueue.async { [weak self] in
            let bounds = NotchPanelController.occupantBounds()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanningOccupancy = false
                guard !self.store.isHidden, self.store.avoidanceMode == .autoStackBelow else { return }
                self.applyOccupancyBounds(bounds, immediate: false, confirming: confirming)
            }
        }
    }

    private func applyOccupancyBounds(_ bounds: [CGRect], immediate: Bool, confirming: Bool) {
        var needsConfirmation = false
        for controller in controllers.values {
            if controller.refreshAvoidanceLayout(occupantBounds: bounds, immediate: immediate) {
                needsConfirmation = true
            }
        }
        occupancyConfirmation?.cancel()
        occupancyConfirmation = nil
        if needsConfirmation && !confirming {
            let work = DispatchWorkItem { [weak self] in
                self?.refreshOccupancy(immediate: false, confirming: true)
            }
            occupancyConfirmation = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    private func updateFollowTimer(enabled: Bool) {
        mouseScreenTimer?.invalidate()
        mouseScreenTimer = nil
        guard enabled else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.store.isHidden else { return }
                let targets = self.targetScreens()
                guard let target = targets.first else { return }
                let sid = (target.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                if self.controllers.count == 1 && self.controllers[sid] != nil {
                    return
                }
                self.rebuildPanels()
            }
        }
        t.tolerance = 0.25
        mouseScreenTimer = t
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
        let bounds = store.avoidanceMode == .autoStackBelow && !store.isHidden
            ? NotchPanelController.occupantBounds() : []
        var targetIDs = Set<CGDirectDisplayID>()

        for screen in targets {
            let sid = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            targetIDs.insert(sid)
            if let existing = controllers[sid] {
                existing.updateScreen(screen, occupantBounds: bounds)
                existing.setVisible(!store.isHidden)
            } else {
                let ctrl = NotchPanelController(
                    screen: screen,
                    screenID: sid,
                    store: store,
                    occupantBounds: bounds,
                    onActivateApp: { [weak self] in self?.activateAntigravity() },
                    onBuildContextMenu: { [weak self] in self?.buildContextMenu() ?? NSMenu() }
                )
                ctrl.setVisible(!store.isHidden)
                controllers[sid] = ctrl
            }
        }

        for sid in Array(controllers.keys) where !targetIDs.contains(sid) {
            if store.hoveredScreenID == sid {
                store.hoveredScreenID = nil
            }
            controllers.removeValue(forKey: sid)
        }
        updateMouseMonitors()
    }

    private func activateRunningApp(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    func activateAntigravity() {
        let running = NSWorkspace.shared.runningApplications
        if store.dataDir.contains("antigravity-cli") {
            let target = NotchStore.resolveCliTerminalTarget(env: ProcessInfo.processInfo.environment)
            if let bid = target.bundleId?.lowercased(),
               let app = running.first(where: { ($0.bundleIdentifier ?? "").lowercased() == bid }) {
                activateRunningApp(app)
                return
            }
            if let name = target.appName?.lowercased(),
               let app = running.first(where: { ($0.localizedName ?? "").lowercased() == name }) {
                activateRunningApp(app)
                return
            }
            let fallbackTerminalBundles = [
                "com.mitchellh.ghostty",
                "com.googlecode.iterm2",
                "com.apple.Terminal",
                "dev.warp.Warp-Stable",
                "net.kovidgoyal.kitty",
                "com.github.wez.wezterm",
                "org.alacritty",
            ]
            if let app = running.first(where: {
                let bid = ($0.bundleIdentifier ?? "").lowercased()
                return fallbackTerminalBundles.contains(where: { $0.lowercased() == bid })
            }) {
                activateRunningApp(app)
                return
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = ["-a", target.appName ?? "Terminal"]
            try? proc.run()
            return
        }

        if let app = running.first(where: {
            let name = ($0.localizedName ?? "").lowercased()
            let bid = ($0.bundleIdentifier ?? "").lowercased()
            return name.contains("antigravity") || bid.contains("antigravity")
        }) {
            activateRunningApp(app)
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

        let tempHideItem = NSMenuItem(title: "暂时隐藏刘海状态栏", action: #selector(MenuActions.temporaryHide), keyEquivalent: "h")
        tempHideItem.target = MenuActions.shared
        menu.addItem(tempHideItem)

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

        let disableItem = NSMenuItem(title: "关闭刘海状态栏（可在设置中重新开启）", action: #selector(MenuActions.disableNotch), keyEquivalent: "")
        disableItem.target = MenuActions.shared
        menu.addItem(disableItem)

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

    @objc func temporaryHide() {
        store?.isTemporarilyHidden = true
    }

    @objc func restoreFromTemporaryHide() {
        store?.isTemporarilyHidden = false
    }

    @objc func disableNotch() {
        store?.isTemporarilyHidden = false
        store?.isHiddenByUser = true
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
