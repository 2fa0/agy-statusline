import AppKit
import SwiftUI

/// Continuous-curvature notch shape:
/// inverse top shoulders flare outward at y=0 and bottom corners use cubic bezier curvature.
struct NotchShape: Shape {
    var topExtension: CGFloat = 7
    var bottomRadius: CGFloat = 15

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topExtension, bottomRadius) }
        set {
            topExtension = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ext = min(topExtension, max(0, rect.width * 0.08))
        let br = min(bottomRadius, rect.width / 4, rect.height / 2)
        let k: CGFloat = 0.62

        var path = Path()
        path.move(to: CGPoint(x: rect.minX - ext, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX + ext, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + ext),
            control1: CGPoint(x: rect.maxX + ext * 0.35, y: rect.minY),
            control2: CGPoint(x: rect.maxX, y: rect.minY + ext * 0.35)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addCurve(
            to: CGPoint(x: rect.maxX - br, y: rect.maxY),
            control1: CGPoint(x: rect.maxX, y: rect.maxY - br * (1 - k)),
            control2: CGPoint(x: rect.maxX - br * (1 - k), y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - br),
            control1: CGPoint(x: rect.minX + br * (1 - k), y: rect.maxY),
            control2: CGPoint(x: rect.minX, y: rect.maxY - br * (1 - k))
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + ext))
        path.addCurve(
            to: CGPoint(x: rect.minX - ext, y: rect.minY),
            control1: CGPoint(x: rect.minX, y: rect.minY + ext * 0.35),
            control2: CGPoint(x: rect.minX - ext * 0.35, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }
}

private struct PillFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private enum NotchDisplayPhase: Equatable {
    case idleHidden
    case idle
    case active
    case peek(NotchPeekEvent)
    case expanded
}

struct NotchView: View {
    @ObservedObject var store: NotchStore
    let hasNotch: Bool
    let hardwareNotchWidth: CGFloat
    let hardwareNotchHeight: CGFloat
    let isFloatingPill: Bool
    let onActivateApp: () -> Void
    let onOpenMenu: () -> Void
    let onPillFrameChange: (CGRect) -> Void

    private var snap: NotchSnapshot { store.snapshot }
    private var currentTask: ActiveTaskItem? { store.displayedTask }

    private var phase: NotchDisplayPhase {
        if store.isHovering {
            return .expanded
        }
        if let peek = store.activePeek {
            return .peek(peek)
        }
        if snap.isActive {
            return .active
        }
        if store.hideWhenIdle {
            return .idleHidden
        }
        return .idle
    }

    private var isExpanded: Bool {
        if case .expanded = phase { return true }
        return false
    }

    private var isPeeking: Bool {
        if case .peek = phase { return true }
        return false
    }

    private var isIdleHidden: Bool {
        if case .idleHidden = phase { return true }
        return false
    }

    private var useSplitWings: Bool {
        hasNotch && !isFloatingPill
    }

    private var displayTitle: String {
        currentTask?.title ?? snap.title
    }

    private var displayCommand: String {
        currentTask?.commandText ?? snap.commandText
    }

    private var displayState: NotchSnapshot.RunState {
        currentTask?.state ?? snap.state
    }

    private var displayStateLabel: String {
        currentTask?.stateLabel ?? snap.stateLabel
    }

    private var displayTokPerSec: Double? {
        if let task = currentTask { return task.tokPerSec }
        return snap.tokPerSec
    }

    private var displayContextPct: Double? {
        if let task = currentTask { return task.contextPct }
        return snap.contextPct
    }

    private var displayModel: String {
        currentTask?.modelName ?? snap.modelName
    }

    private var displayWorkspace: String {
        currentTask?.workspaceName ?? snap.workspaceName
    }

    private var barHeight: CGFloat {
        if isIdleHidden && !useSplitWings {
            return 14
        }
        return isFloatingPill ? 28 : (hasNotch ? max(hardwareNotchHeight, 34) : 30)
    }

    private var pillWidth: CGFloat {
        switch phase {
        case .idleHidden:
            return useSplitWings ? hardwareNotchWidth : 54
        case .idle:
            return useSplitWings ? (hardwareNotchWidth + 56) : 132
        case .active:
            return useSplitWings ? max(hardwareNotchWidth + 200, 380) : 284
        case .peek:
            return useSplitWings ? max(hardwareNotchWidth + 220, 400) : 340
        case .expanded:
            return useSplitWings ? max(410, hardwareNotchWidth + 220) : 400
        }
    }

    private var isCollapsedHardwareNotch: Bool {
        useSplitWings && !isExpanded && !isPeeking
    }

    private var pillShape: AnyShape {
        if isFloatingPill {
            let radius: CGFloat = isExpanded ? 18 : (isPeeking ? 16 : 14)
            return AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        let bottomRadius: CGFloat = isExpanded ? 18 : (isPeeking ? 15 : 12)
        return AnyShape(NotchShape(topExtension: isIdleHidden ? 4 : 7, bottomRadius: bottomRadius))
    }

    var body: some View {
        let topPad: CGFloat = isFloatingPill ? 2 : 0
        ZStack(alignment: .top) {
            Color.clear

            VStack(spacing: 0) {
                if useSplitWings {
                    splitNotchHeader
                } else {
                    floatingHeader
                }

                if case .peek(let peek) = phase {
                    peekBanner(peek)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if isExpanded {
                    expandedDrawer
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(width: pillWidth, alignment: .top)
            .clipShape(pillShape)
            .background(
                pillShape
                    .fill(Color.black)
                    .overlay(
                        pillShape
                            .stroke(
                                Color.white.opacity(isCollapsedHardwareNotch ? 0.0 : 0.12),
                                lineWidth: isCollapsedHardwareNotch ? 0 : 0.75
                            )
                    )
                    .shadow(
                        color: .black.opacity(isCollapsedHardwareNotch ? 0.0 : (isExpanded ? 0.48 : 0.24)),
                        radius: isCollapsedHardwareNotch ? 0 : (isExpanded ? 14 : 6),
                        y: isCollapsedHardwareNotch ? 0 : 4
                    )
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: PillFramePreferenceKey.self,
                        value: geo.frame(in: .named("notchPanel"))
                    )
                }
            )
            .padding(.top, topPad)
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: phase)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: snap.activeCount)
            .animation(.spring(response: 0.32, dampingFraction: 0.84), value: snap.recentTasks.count)
        }
        .coordinateSpace(name: "notchPanel")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(PillFramePreferenceKey.self) { rect in
            onPillFrameChange(rect)
        }
    }

    // MARK: - Split-Wing Hardware Notch Header

    private var splitNotchHeader: some View {
        let sideWidth = max(0, (pillWidth - hardwareNotchWidth) / 2)

        return HStack(spacing: 0) {
            // Left Wing
            Group {
                if isIdleHidden {
                    Color.clear
                } else if snap.isActive || isExpanded || isPeeking {
                    HStack(spacing: 6) {
                        StatusDot(
                            color: Color(nsColor: displayState.color),
                            pulsing: displayState == .running,
                            size: 6.5
                        )
                        Text(displayWorkspace.isEmpty ? displayStateLabel : displayWorkspace)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 4)
                } else {
                    // Restrained Idle Left Wing (28pt)
                    HStack {
                        StatusDot(
                            color: Color(nsColor: snap.state.color).opacity(0.88),
                            pulsing: false,
                            size: 6
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(width: sideWidth, height: barHeight, alignment: .leading)
            .clipped()

            // Center Hardware Camera Notch Spacer
            Spacer(minLength: hardwareNotchWidth)

            // Right Wing
            Group {
                if isIdleHidden {
                    Color.clear
                } else if snap.isActive || isExpanded || isPeeking {
                    HStack(spacing: 5) {
                        activeRightMetricView

                        if snap.activeCount > 1 {
                            Button {
                                store.cycleNextTask()
                            } label: {
                                Text("\(snap.activeCount)")
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .foregroundColor(.white.opacity(0.92))
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 1.5)
                                    .background(Color.white.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 10)
                } else {
                    // Restrained Idle Right Wing (28pt)
                    Group {
                        if let pct = snap.contextPct {
                            Text("\(Int(pct.rounded()))%")
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.48))
                                .minimumScaleFactor(0.75)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(width: sideWidth, height: barHeight, alignment: .trailing)
            .clipped()
        }
        .frame(height: barHeight)
    }

    // MARK: - Floating / Non-Notch Header

    private var floatingHeader: some View {
        Group {
            if isIdleHidden {
                HStack(spacing: 4) {
                    StatusDot(color: Color(nsColor: snap.state.color).opacity(0.65), pulsing: false, size: 5)
                }
                .frame(maxWidth: .infinity, maxHeight: barHeight)
            } else if snap.isActive || isExpanded || isPeeking {
                HStack(spacing: 8) {
                    StatusDot(
                        color: Color(nsColor: displayState.color),
                        pulsing: displayState == .running,
                        size: 6.5
                    )
                    Text(displayWorkspace.isEmpty ? displayStateLabel : displayWorkspace)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 8)

                    activeRightMetricView

                    if snap.activeCount > 1 {
                        Button {
                            store.cycleNextTask()
                        } label: {
                            Text("\(snap.activeCount)")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.92))
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1.5)
                                .background(Color.white.opacity(0.14))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: barHeight)
            } else {
                HStack(spacing: 6) {
                    StatusDot(
                        color: Color(nsColor: snap.state.color).opacity(0.88),
                        pulsing: false,
                        size: 6
                    )
                    Text(snap.workspaceName.isEmpty ? "AGY" : snap.workspaceName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if let pct = snap.contextPct {
                        Text("\(Int(pct.rounded()))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: barHeight)
            }
        }
    }

    @ViewBuilder
    private var activeRightMetricView: some View {
        if let tok = displayTokPerSec {
            Text("\(Int(tok.rounded())) t/s")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.76))
                .lineLimit(1)
        } else if let pct = displayContextPct {
            HStack(spacing: 4) {
                ContextRing(progress: pct / 100.0)
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.72))
            }
        } else {
            Text(displayStateLabel)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
        }
    }

    // MARK: - 3. Peek Transient Banner

    private func peekBanner(_ peek: NotchPeekEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: peek.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(nsColor: peek.state.color))

            Text(peek.title.isEmpty ? "Antigravity" : peek.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Text(peek.statusText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(nsColor: peek.state.color))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Color.white.opacity(0.03))
    }

    // MARK: - 4. Expanded Drawer (3-Tier Control Center Card)

    private var expandedDrawer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().background(Color.white.opacity(0.1))

            // Tier 1: Primary Task Card
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        StatusDot(
                            color: Color(nsColor: displayState.color),
                            pulsing: displayState == .running,
                            size: 6
                        )
                        Text(displayStateLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(Color(nsColor: displayState.color))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Color(nsColor: displayState.color).opacity(0.16))
                    .clipShape(Capsule())

                    if let tok = displayTokPerSec {
                        let isSlow = tok < snap.lowSpeedThreshold
                        Text(String(format: "%.1f t/s", tok))
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundColor(isSlow ? Color(red: 0.98, green: 0.80, blue: 0.22) : Color(red: 0.45, green: 0.90, blue: 0.60))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.white.opacity(0.07))
                            .clipShape(Capsule())
                    }

                    Spacer(minLength: 4)

                    if !displayModel.isEmpty {
                        Text(displayModel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Button {
                        onActivateApp()
                    } label: {
                        HStack(spacing: 3) {
                            Text("打开")
                            Image(systemName: "arrow.up.forward")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Text(displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.96))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !displayCommand.isEmpty {
                    Text(displayCommand)
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.76))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.045))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Tier 2: Task List (up to 4 recentTasks, matched by task.id)
            if snap.recentTasks.count > 1 {
                let selectedId = currentTask?.id ?? snap.conversationId
                VStack(spacing: 3) {
                    ForEach(Array(snap.recentTasks.prefix(4))) { task in
                        let isSelected = task.id == selectedId
                        HStack(spacing: 7) {
                            if task.isRunning {
                                StatusDot(
                                    color: Color(nsColor: task.state.color),
                                    pulsing: task.state == .running,
                                    size: 6
                                )
                            } else {
                                Image(systemName: task.state == .error ? "xmark.circle" : (task.code == "user_cancelled" ? "minus.circle" : "checkmark"))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Color(nsColor: task.state.color))
                                    .frame(width: 7)
                            }

                            Text(task.title)
                                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(isSelected ? .white.opacity(0.96) : .white.opacity(0.72))
                                .lineLimit(1)
                                .truncationMode(.tail)

                            Spacer(minLength: 6)

                            Text(task.workspaceName.isEmpty ? task.stateLabel : task.workspaceName)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(isSelected ? Color.white.opacity(0.10) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if task.isRunning {
                                store.selectTask(task)
                            }
                        }
                    }
                }
            }

            // Tier 3: Footer Metrics Bar
            HStack(spacing: 10) {
                if let pct = displayContextPct {
                    HStack(spacing: 5) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.14))
                                Capsule()
                                    .fill(pct > 80 ? Color.orange : Color(red: 0.38, green: 0.72, blue: 1.0))
                                    .frame(width: max(4, geo.size.width * min(1, max(0, pct / 100))))
                            }
                        }
                        .frame(width: 56, height: 4)

                        Text("\(Int(pct.rounded()))%")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.68))
                    }
                }

                if !snap.quotaSummary.isEmpty {
                    Text(snap.quotaSummary)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                HStack(spacing: 4) {
                    FooterIconButton(systemName: "arrow.clockwise", help: "刷新状态") {
                        store.refreshNow(force: true)
                    }
                    FooterIconButton(systemName: "eye.slash", help: "暂时隐藏") {
                        store.isHiddenByUser = true
                    }
                    FooterIconButton(systemName: "ellipsis.circle", help: "选项菜单") {
                        onOpenMenu()
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }
}

private struct ContextRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.18), lineWidth: 1.8)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(
                    progress > 0.8 ? Color.orange : Color.white.opacity(0.78),
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }
}

private struct FooterIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.62))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.06))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct StatusDot: View {
    let color: Color
    let pulsing: Bool
    var size: CGFloat = 7

    private var pulseState = State(initialValue: false)

    init(color: Color, pulsing: Bool, size: CGFloat = 7) {
        self.color = color
        self.pulsing = pulsing
        self.size = size
    }

    var body: some View {
        let pulse = pulseState.wrappedValue
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(pulsing && pulse ? 1.18 : 0.92)
            .opacity(pulsing ? (pulse ? 1.0 : 0.55) : 1.0)
            .animation(
                pulsing ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                value: pulse
            )
            .onAppear {
                if pulsing {
                    DispatchQueue.main.async {
                        pulseState.wrappedValue = true
                    }
                }
            }
            .onChange(of: pulsing) { newValue in
                pulseState.wrappedValue = newValue
            }
    }
}
