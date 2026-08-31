import AppKit
import CodexBarCore
import SwiftUI

// MARK: - Motion

/// Shared motion vocabulary for the notch island so the AppKit controller and the SwiftUI tree
/// always animate on the same curves.
@MainActor
enum NotchMotion {
    static let expand = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let collapse = Animation.spring(response: 0.32, dampingFraction: 0.9)
    static let content = Animation.spring(response: 0.34, dampingFraction: 0.86)
    static let instant = Animation.easeOut(duration: 0.14)

    /// Seconds to wait before shrinking the host window back to the dormant footprint.
    static let collapseSettleDelay: Double = 0.45

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var expanding: Animation {
        self.reduceMotion ? self.instant : self.expand
    }

    static var collapsing: Animation {
        self.reduceMotion ? self.instant : self.collapse
    }

    static var contentChange: Animation {
        self.reduceMotion ? self.instant : self.content
    }
}

enum NotchIndicatorSide: Equatable {
    case left
    case right
}

enum NotchIndicatorState: Equatable {
    case hidden
    case idle
    case running
    case attention
}

enum NotchIndicatorColor: String, Equatable {
    case claude = "#D97757"
    case codex = "#F5F5F5"

    var swiftUIColor: Color {
        switch self {
        case .claude: Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
        case .codex: Color(red: 245 / 255, green: 245 / 255, blue: 245 / 255)
        }
    }
}

struct NotchLightPresentation: Equatable, Identifiable {
    let provider: AgentTaskProvider
    let side: NotchIndicatorSide
    let color: NotchIndicatorColor
    let state: NotchIndicatorState

    var id: AgentTaskProvider {
        self.provider
    }

    var showsEdgeGlow: Bool {
        self.state == .attention
    }

    static func make(
        provider: AgentTaskProvider,
        status: AgentTaskStatus,
        isConfigured: Bool,
        attention: AgentTaskAttention?)
        -> NotchLightPresentation
    {
        let side: NotchIndicatorSide = provider == .claude ? .left : .right
        let color: NotchIndicatorColor = provider == .claude ? .claude : .codex
        guard isConfigured else {
            return NotchLightPresentation(provider: provider, side: side, color: color, state: .hidden)
        }
        let attentionMatches = attention?.event.provider == provider && attention?.status.requiresUserAction == true
        let state: NotchIndicatorState = if status.requiresUserAction || attentionMatches {
            .attention
        } else if status == .running {
            .running
        } else {
            .idle
        }
        return NotchLightPresentation(provider: provider, side: side, color: color, state: state)
    }
}

extension AgentTaskStatus {
    fileprivate var requiresUserAction: Bool {
        switch self {
        case .needsApproval, .failed, .interrupted, .disconnected: true
        case .idle, .running, .completed: false
        }
    }
}

struct NotchCollapsedPresentation: Equatable {
    let lights: [NotchLightPresentation]
    let visibleText: String

    static func make(
        claude: AgentTaskStatus,
        codex: AgentTaskStatus,
        claudeConfigured: Bool = true,
        codexConfigured: Bool = true,
        attention: AgentTaskAttention? = nil)
        -> NotchCollapsedPresentation
    {
        NotchCollapsedPresentation(
            lights: [
                NotchLightPresentation.make(
                    provider: .claude,
                    status: claude,
                    isConfigured: claudeConfigured,
                    attention: attention),
                NotchLightPresentation.make(
                    provider: .codex,
                    status: codex,
                    isConfigured: codexConfigured,
                    attention: attention),
            ],
            visibleText: "")
    }

    static func fixture(_ scenario: IslandShellFixtureIndicatorScenario) -> NotchCollapsedPresentation {
        let statuses: (claude: AgentTaskStatus, codex: AgentTaskStatus) = switch scenario {
        case .running: (.running, .running)
        case .claudeAttention: (.needsApproval, .running)
        case .codexAttention: (.running, .needsApproval)
        case .bothAttention: (.needsApproval, .failed)
        }
        return self.make(claude: statuses.claude, codex: statuses.codex)
    }
}

// MARK: - Palette

/// Severity-driven accent ramp. The island is pure black so it fuses with the physical notch;
/// every bit of color comes from these gradients.
enum NotchPalette {
    static let mint = Color(red: 0.24, green: 0.86, blue: 0.60)
    static let cyan = Color(red: 0.22, green: 0.76, blue: 0.98)
    static let sun = Color(red: 1.0, green: 0.83, blue: 0.40)
    static let amber = Color(red: 1.0, green: 0.62, blue: 0.16)
    static let coral = Color(red: 1.0, green: 0.45, blue: 0.44)
    static let crimson = Color(red: 1.0, green: 0.24, blue: 0.42)

    static let warningThreshold: Double = 0.55
    static let criticalThreshold: Double = 0.82

    /// Fraction of the quota already consumed, regardless of whether the metric counts up or down.
    static func usedFraction(for metric: UsageMenuCardView.Model.Metric) -> Double {
        let filled = min(max(metric.percent, 0), 100) / 100
        return metric.percentStyle == .left ? 1 - filled : filled
    }

    static func accent(usedFraction: Double) -> (start: Color, end: Color) {
        if usedFraction < self.warningThreshold {
            return (self.mint, self.cyan)
        }
        if usedFraction < self.criticalThreshold {
            return (self.sun, self.amber)
        }
        return (self.coral, self.crimson)
    }

    static func brandColor(for provider: UsageProvider) -> Color {
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }
}

// MARK: - Shape

/// Dynamic-Island silhouette: the top edge spans the full width and curls *inward* with concave
/// shoulders, so the panel reads as if it grew out of the hardware notch instead of floating below it.
struct NotchIslandShape: Shape {
    var shoulderRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(self.shoulderRadius, self.bottomRadius) }
        set {
            self.shoulderRadius = newValue.first
            self.bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = max(0, min(self.shoulderRadius, rect.width / 2))
        let bottom = max(0, min(self.bottomRadius, min(rect.height, (rect.width - shoulder * 2) / 2)))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder, y: rect.minY + shoulder),
            control: CGPoint(x: rect.minX + shoulder, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + shoulder, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Actions

struct NotchIslandActions {
    var refresh: @MainActor () -> Void
    var settings: @MainActor () -> Void
    var selectProvider: @MainActor (UsageProvider) -> Void
    var togglePinned: @MainActor () -> Void
    var toggleExpanded: @MainActor () -> Void
    var openTask: @MainActor () -> Void
    /// Entry-only hover signal; the controller owns exits.
    var hoverEntered: @MainActor () -> Void
}

// MARK: - Root

/// The whole notch surface. Top-aligned inside a transparent stage window; every pixel outside the
/// island silhouette stays fully transparent so clicks fall through to whatever is underneath.
struct NotchIslandView: View {
    let state: NotchBarState
    let actions: NotchIslandActions

    var body: some View {
        VStack(spacing: 0) {
            IslandShellView(
                presentation: self.state.shellPresentation,
                indicators: self.state.collapsedPresentation,
                reduceMotion: self.state.reduceMotion,
                actions: IslandShellActions(
                    toggleExpanded: self.actions.toggleExpanded,
                    hoverEntered: self.actions.hoverEntered))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(x: self.state.centerOffset)
    }

    private var shape: NotchIslandShape {
        NotchIslandShape(
            shoulderRadius: self.state.shoulderRadius,
            bottomRadius: self.state.bottomRadius)
    }

    private var island: some View {
        let plan = self.state.taskDetailPlan
        return ZStack(alignment: .top) {
            self.background
            VStack(spacing: 0) {
                NotchBandView(state: self.state)
                    .frame(height: self.state.compactHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { self.actions.toggleExpanded() }
                if self.state.phase == .expanded {
                    NotchTaskDetailView(plan: plan, openTask: self.actions.openTask)
                        .frame(height: NotchTaskDetailView.height)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, self.state.shoulderRadius)
        }
        .frame(width: self.state.totalWidth, height: self.state.islandHeight, alignment: .top)
        .clipShape(self.shape)
        .overlay {
            self.shape
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(self.state.phase == .dormant ? 0 : 0.14)],
                        startPoint: .top,
                        endPoint: .bottom),
                    lineWidth: 0.8)
        }
        .onHover { isInside in
            if isInside { self.actions.hoverEntered() }
        }
    }

    private var background: some View {
        ZStack {
            Color.black
            LinearGradient(
                colors: [Color(white: 0.085), Color(white: 0.015)],
                startPoint: .top,
                endPoint: .bottom)
                .opacity(self.state.phase == .dormant ? 0 : 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Task detail

struct NotchTaskDetailView: View {
    static let height: CGFloat = 208

    let plan: NotchTaskDetailPlan
    let openTask: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            self.eventHeader
            self.eventIdentity
            if self.plan.sections.contains(where: { $0.kind == .openTask }) {
                Button(action: self.openTask) {
                    Text(L("agent_task_open"))
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(.white.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if let quota = self.plan.quota {
                self.quotaFooter(quota)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }

    private var eventHeader: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2.5)
                .fill(self.providerColor)
                .frame(width: 8, height: 8)
                .shadow(color: self.providerColor.opacity(0.7), radius: 4)
            Text(self.plan.providerName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 8)
            Text(self.plan.statusText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(self.providerColor)
        }
    }

    private var eventIdentity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(self.plan.eventTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if let subtitle = self.plan.eventSubtitle {
                Text(subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private func quotaFooter(_ quota: NotchQuotaSummary) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(L("agent_task_quota"))
                Spacer(minLength: 8)
                Text("\(Int(quota.usedPercent.rounded()))%")
                if let resetText = quota.resetText {
                    Text("· \(resetText)")
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.42))
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.08))
                    Capsule()
                        .fill(self.providerColor.opacity(0.58))
                        .frame(width: geometry.size.width * quota.usedPercent / 100)
                }
            }
            .frame(height: 3)
        }
    }

    private var providerColor: Color {
        self.plan.provider == .codex
            ? NotchPalette.mint
            : Color(red: 1, green: 0.55, blue: 0.22)
    }
}

// MARK: - Menu-bar band

/// The strip that lives at menu-bar height. Its middle is a transparent gap exactly as wide as the
/// hardware notch, so the wings appear to sprout from either side of the camera housing.
private struct NotchBandView: View {
    let state: NotchBarState

    var body: some View {
        NotchProviderLightsView(presentation: self.state.collapsedPresentation)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}

private struct NotchProviderLightsView: View {
    let presentation: NotchCollapsedPresentation

    var body: some View {
        HStack(spacing: 7) {
            ForEach(self.presentation.lights.filter { $0.state != .hidden }) { light in
                Circle()
                    .fill(light.color.swiftUIColor)
                    .frame(width: 5, height: 5)
                    .opacity(light.state == .idle ? 0.3 : 1)
            }
        }
        .frame(height: NotchGeometry.lightShelfHeight)
    }
}

// MARK: - Expanded detail

private struct NotchDetailView: View {
    let state: NotchBarState
    let plan: NotchDetailPlan
    let actions: NotchIslandActions

    var body: some View {
        VStack(spacing: 0) {
            NotchHeroView(state: self.state, plan: self.plan)
                .frame(height: NotchDetailPlan.heroHeight)
            if self.plan.visibleRowCount > 0 {
                self.rows
                    .frame(height: self.plan.rowsHeight)
            }
            if !self.plan.stats.isEmpty {
                self.stats
                    .frame(height: NotchDetailPlan.statsHeight)
            }
            NotchFooterView(state: self.state, actions: self.actions)
                .frame(height: NotchDetailPlan.footerHeight)
        }
        .padding(.horizontal, 18)
        // Matches NotchDetailPlan.height exactly, so the measured silhouette and the rendered
        // content stay pixel-identical while the panel springs open.
        .padding(.bottom, NotchDetailPlan.bottomInset)
    }

    private var rows: some View {
        ScrollView(.vertical) {
            VStack(spacing: NotchDetailPlan.rowSpacing) {
                ForEach(self.plan.rows) { metric in
                    NotchMetricRow(metric: metric)
                        .frame(height: NotchDetailPlan.rowHeight)
                }
            }
            .padding(.top, NotchDetailPlan.rowsTopInset)
        }
        .scrollIndicators(.never)
        .scrollDisabled(self.plan.rows.count <= NotchDetailPlan.maxVisibleRows)
    }

    private var stats: some View {
        HStack(spacing: 8) {
            ForEach(Array(self.plan.stats.enumerated()), id: \.offset) { _, text in
                Text(text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.07), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Hero

private struct NotchHeroView: View {
    let state: NotchBarState
    let plan: NotchDetailPlan

    var body: some View {
        HStack(spacing: 14) {
            if let metric = self.plan.primary {
                NotchGaugeRing(metric: metric, accent: self.state.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.title)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let reset = metric.resetText ?? metric.statusText {
                        Text(reset)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.58))
                            .lineLimit(1)
                    }
                    if let detail = self.plan.heroDetail {
                        Text(detail)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let trailing = metric.detailRightText {
                    Text(trailing)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .frame(maxWidth: 120, alignment: .trailing)
                }
            } else {
                NotchPlaceholderBadge(tint: self.state.accent.end)
                VStack(alignment: .leading, spacing: 3) {
                    Text(self.plan.headline)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(self.plan.emptyMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: NotchDetailPlan.heroCardHeight)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.05)))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 0.8)
        }
    }
}

private struct NotchPlaceholderBadge: View {
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 7)
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(self.tint.opacity(0.85))
        }
        .frame(width: 66, height: 66)
    }
}

/// Big ring gauge: the one element that has to catch the eye the instant the panel drops down.
private struct NotchGaugeRing: View {
    let metric: UsageMenuCardView.Model.Metric
    let accent: (start: Color, end: Color)

    private var fraction: Double {
        min(max(self.metric.percent, 0), 100) / 100
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.10), lineWidth: 7)
            Circle()
                .trim(from: 0, to: max(0.004, self.fraction))
                .stroke(
                    AngularGradient(
                        colors: [self.accent.start, self.accent.end, self.accent.start],
                        center: .center),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: self.accent.end.opacity(0.55), radius: 6)
                .animation(NotchMotion.contentChange, value: self.fraction)
            VStack(spacing: -2) {
                Text(self.percentNumber)
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text(self.metric.percentStyle.labelSuffix)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .frame(width: 66, height: 66)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.metric.percentStyle.accessibilityLabel)
        .accessibilityValue(self.metric.percentLabel)
    }

    private var percentNumber: String {
        let clamped = min(max(self.metric.percent, 0), 100)
        if clamped > 0, clamped < 1 {
            return "<1%"
        }
        return "\(Int(clamped.rounded()))%"
    }
}

// MARK: - Metric row

private struct NotchMetricRow: View {
    let metric: UsageMenuCardView.Model.Metric

    private var accent: (start: Color, end: Color) {
        NotchPalette.accent(usedFraction: NotchPalette.usedFraction(for: self.metric))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(self.metric.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let reset = self.metric.resetText {
                    Text(reset)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Text(self.metric.percentLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(self.accent.end)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            if let status = self.metric.statusText {
                Text(status)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .frame(height: 6, alignment: .center)
            } else {
                NotchMeter(
                    fraction: min(max(self.metric.percent, 0), 100) / 100,
                    pace: self.metric.pacePercent.map { min(max($0, 0), 100) / 100 },
                    accent: self.accent)
                    .frame(height: 6)
            }
        }
    }
}

private struct NotchMeter: View {
    let fraction: Double
    let pace: Double?
    let accent: (start: Color, end: Color)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [self.accent.start, self.accent.end],
                            startPoint: .leading,
                            endPoint: .trailing))
                    .frame(width: max(4, geometry.size.width * self.fraction))
                    .shadow(color: self.accent.end.opacity(0.5), radius: 4)
                if let pace = self.pace {
                    Capsule()
                        .fill(Color.white.opacity(0.75))
                        .frame(width: 1.5)
                        .offset(x: max(0, min(geometry.size.width - 1.5, geometry.size.width * pace)))
                }
            }
        }
        .animation(NotchMotion.contentChange, value: self.fraction)
    }
}

// MARK: - Footer

private struct NotchFooterView: View {
    let state: NotchBarState
    let actions: NotchIslandActions

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(self.state.enabledProviders, id: \.self) { provider in
                        NotchProviderChip(
                            provider: provider,
                            isSelected: provider == self.state.selectedProvider,
                            action: { self.actions.selectProvider(provider) })
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            NotchIconButton(
                systemName: self.state.isPinned ? "pin.fill" : "pin",
                isActive: self.state.isPinned,
                help: L("Keep panel open"),
                action: self.actions.togglePinned)
            NotchIconButton(
                systemName: "arrow.clockwise",
                isActive: false,
                help: L("Refresh"),
                action: self.actions.refresh)
            NotchIconButton(
                systemName: "gearshape",
                isActive: false,
                help: L("Settings..."),
                action: self.actions.settings)
        }
    }
}

private struct NotchProviderChip: View {
    let provider: UsageProvider
    let isSelected: Bool
    let action: @MainActor () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            Group {
                if let icon = ProviderBrandIcon.image(for: self.provider) {
                    Image(nsImage: icon)
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: 13, height: 13)
                } else {
                    Text(String(self.displayName.prefix(1)))
                        .font(.system(size: 10, weight: .bold))
                }
            }
            .foregroundStyle(.white.opacity(self.isSelected ? 1 : (self.isHovering ? 0.85 : 0.5)))
            .frame(width: 30, height: 26)
            .background(self.chipBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        NotchPalette.brandColor(for: self.provider).opacity(self.isSelected ? 0.65 : 0),
                        lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
        .help(self.displayName)
        .accessibilityLabel(self.displayName)
    }

    private var displayName: String {
        ProviderDescriptorRegistry.descriptor(for: self.provider).metadata.displayName
    }

    private var chipBackground: Color {
        if self.isSelected {
            return NotchPalette.brandColor(for: self.provider).opacity(0.26)
        }
        return .white.opacity(self.isHovering ? 0.13 : 0.07)
    }
}

private struct NotchIconButton: View {
    let systemName: String
    let isActive: Bool
    let help: String
    let action: @MainActor () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            Image(systemName: self.systemName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(self.isActive ? 1 : (self.isHovering ? 0.95 : 0.62)))
                .frame(width: 27, height: 27)
                .background(
                    .white.opacity(self.isActive ? 0.2 : (self.isHovering ? 0.14 : 0.07)),
                    in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
        .help(self.help)
        .accessibilityLabel(self.help)
    }
}
