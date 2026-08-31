import AppKit
import CodexBarCore
import Observation
import SwiftUI

// MARK: - Content models

struct NotchPillContent: Equatable {
    var text: String?
    var icon: NSImage?
    var isRefreshing: Bool

    static func == (lhs: NotchPillContent, rhs: NotchPillContent) -> Bool {
        lhs.text == rhs.text
            && lhs.isRefreshing == rhs.isRefreshing
            && lhs.icon === rhs.icon
    }
}

struct NotchBarContentSnapshot {
    var selectedProvider: UsageProvider
    var enabledProviders: [UsageProvider]
    var pill: NotchPillContent
    var cardModel: UsageMenuCardView.Model?
    var taskAggregates: [AgentTaskProvider: AgentTaskProviderAggregate]
    var hookHealth: [AgentTaskProvider: AgentTaskHookHealth]
    var attention: AgentTaskAttention?
    var activeSession: AgentTaskSessionState?
    var hidePersonalInfo: Bool
}

struct NotchQuotaSummary: Equatable {
    let usedPercent: Double
    let resetText: String?

    init(usedPercent: Double, resetText: String?) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.resetText = resetText
    }

    init?(card: UsageMenuCardView.Model?) {
        guard let metric = card?.metrics.first else { return nil }
        self.init(
            usedPercent: NotchPalette.usedFraction(for: metric) * 100,
            resetText: metric.resetText)
    }
}

struct NotchTaskDetailPlan {
    enum SectionKind: Equatable {
        case event
        case openTask
        case quota
    }

    struct Section: Equatable {
        let kind: SectionKind
    }

    let provider: AgentTaskProvider
    let providerName: String
    let statusText: String
    let eventTitle: String
    let eventSubtitle: String?
    let quota: NotchQuotaSummary?
    let sections: [Section]

    init(
        attention: AgentTaskAttention?,
        activeSession: AgentTaskSessionState?,
        quota: NotchQuotaSummary?,
        hidePersonalInfo: Bool = false)
    {
        let event = attention?.event
        let provider = event?.provider ?? activeSession?.provider ?? .codex
        let status = attention?.status ?? activeSession?.status ?? .idle
        let path = event?.projectPath ?? activeSession?.projectPath
        self.provider = provider
        self.providerName = provider == .codex ? "Codex" : "Claude"
        self.statusText = status.displayName
        self.eventTitle = if hidePersonalInfo {
            status.displayName
        } else {
            event?.taskTitle
                ?? activeSession?.taskTitle
                ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? L("agent_task_none")
        }
        self.eventSubtitle = hidePersonalInfo ? nil : path
        self.quota = quota
        var sections = [Section(kind: .event)]
        if event != nil || activeSession != nil { sections.append(Section(kind: .openTask)) }
        if quota != nil { sections.append(Section(kind: .quota)) }
        self.sections = sections
    }
}

enum NotchAttentionPolicy {
    static func dismissAfter(status: AgentTaskStatus) -> TimeInterval? {
        switch status {
        case .completed, .interrupted: 5
        case .idle, .running, .needsApproval, .failed, .disconnected: nil
        }
    }
}

extension AgentTaskStatus {
    var displayName: String {
        switch self {
        case .idle: L("agent_task_none")
        case .running: L("agent_task_running")
        case .needsApproval: L("agent_task_needs_approval")
        case .completed: L("agent_task_completed")
        case .failed: L("agent_task_failed")
        case .interrupted: L("agent_task_interrupted")
        case .disconnected: L("agent_task_disconnected")
        }
    }
}

// MARK: - Geometry

struct NotchBarLayout: Equatable {
    /// The hardware cut-out or simulated floating island, in screen coordinates.
    let anchorRect: CGRect
    let hasPhysicalNotch: Bool
    /// Window footprint while asleep — just the notch plus a sliver of grab area below it.
    let dormantFrame: CGRect
    /// Window footprint while open. Everything outside the island silhouette stays transparent,
    /// so clicks in the margins fall through to the apps underneath.
    let stageFrame: CGRect
}

enum NotchGeometry {
    static let stageWidth: CGFloat = IslandShellMetrics.stageWidth
    static let stageHeight: CGFloat = IslandShellMetrics.stageHeight
    /// Slack on both sides of the stage window so the island's drop shadow is not clipped.
    static let stageSideMargin: CGFloat = IslandShellMetrics.stageSideMargin
    /// Extra pointer-catching width/height around the sleeping notch.
    static let dormantSideGrab: CGFloat = 20
    static let dormantBottomGrab: CGFloat = 8
    static let lightShelfHeight: CGFloat = 8
    static let simulatedAnchorSize = CGSize(width: 84, height: 20)
    static let simulatedTopGap: CGFloat = 6
    /// Forgiveness margin so a slightly wandering pointer does not collapse the panel.
    static let hoverGrace: CGFloat = IslandShellMetrics.hoverGrace

    static func layout(
        screenFrame: CGRect,
        leftArea: CGRect?,
        rightArea: CGRect?,
        menuBarHeight: CGFloat = 0,
        stageWidth: CGFloat = Self.stageWidth,
        stageHeight: CGFloat = Self.stageHeight)
        -> NotchBarLayout?
    {
        let physicalNotch = self.physicalNotch(leftArea: leftArea, rightArea: rightArea)
        let anchorRect = physicalNotch ?? CGRect(
            x: screenFrame.midX - self.simulatedAnchorSize.width / 2,
            y: screenFrame.maxY - max(0, menuBarHeight) - self.simulatedTopGap - self.simulatedAnchorSize.height,
            width: self.simulatedAnchorSize.width,
            height: self.simulatedAnchorSize.height)
        let hasPhysicalNotch = physicalNotch != nil
        let surfaceTop = hasPhysicalNotch ? screenFrame.maxY : anchorRect.maxY

        let dormantWidth = min(anchorRect.width + self.dormantSideGrab * 2, screenFrame.width)
        let dormantHeight = min(anchorRect.height + self.dormantBottomGrab, screenFrame.height)
        let dormantFrame = CGRect(
            x: self.clampedOriginX(center: anchorRect.midX, width: dormantWidth, screenFrame: screenFrame),
            y: max(screenFrame.minY, surfaceTop - dormantHeight),
            width: dormantWidth,
            height: dormantHeight)

        let clampedStageWidth = min(stageWidth, screenFrame.width)
        let clampedStageHeight = min(stageHeight, screenFrame.height)
        let stageFrame = CGRect(
            x: self.clampedOriginX(center: anchorRect.midX, width: clampedStageWidth, screenFrame: screenFrame),
            y: max(screenFrame.minY, surfaceTop - clampedStageHeight),
            width: clampedStageWidth,
            height: min(clampedStageHeight, surfaceTop - screenFrame.minY))

        return NotchBarLayout(
            anchorRect: anchorRect,
            hasPhysicalNotch: hasPhysicalNotch,
            dormantFrame: dormantFrame,
            stageFrame: stageFrame)
    }

    private static func physicalNotch(leftArea: CGRect?, rightArea: CGRect?) -> CGRect? {
        guard let leftArea, let rightArea else { return nil }
        let minX = leftArea.maxX
        let maxX = rightArea.minX
        let minY = max(leftArea.minY, rightArea.minY)
        let maxY = min(leftArea.maxY, rightArea.maxY)
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func clampedOriginX(center: CGFloat, width: CGFloat, screenFrame: CGRect) -> CGFloat {
        min(max(center - width / 2, screenFrame.minX), screenFrame.maxX - width)
    }

    static func layout(on screen: NSScreen) -> NotchBarLayout? {
        self.layout(
            screenFrame: screen.frame,
            leftArea: screen.auxiliaryTopLeftArea,
            rightArea: screen.auxiliaryTopRightArea,
            menuBarHeight: max(0, screen.frame.maxY - screen.visibleFrame.maxY))
    }
}

enum NotchMouseEventPolicy {
    static func ignoresMouseEvents(
        pointerLocation: CGPoint,
        hoverZone: CGRect,
        isFixture _: Bool = false)
        -> Bool
    {
        !hoverZone.contains(pointerLocation)
    }
}

enum IslandShellInteractionPolicy {
    static func hoverZone(visibleBounds: CGRect) -> CGRect {
        visibleBounds.insetBy(
            dx: -IslandShellMetrics.hoverGrace,
            dy: -IslandShellMetrics.hoverGrace)
    }

    static func canEnter(now: Date, collapsedAt: Date?) -> Bool {
        guard let collapsedAt else { return true }
        return now.timeIntervalSince(collapsedAt) >= IslandShellMetrics.hoverCooldown
    }
}

// MARK: - Detail plan

/// Deterministic layout arithmetic for the expanded panel. Both the SwiftUI tree and the AppKit
/// hover math read heights from here, so the animated silhouette and the hover hit-box never drift.
struct NotchDetailPlan {
    /// Hero band height, and the inset card drawn inside it.
    static let heroHeight: CGFloat = 100
    static let heroCardHeight: CGFloat = 88
    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 10
    static let rowsTopInset: CGFloat = 10
    static let statsHeight: CGFloat = 30
    static let footerHeight: CGFloat = 54
    static let bottomInset: CGFloat = 12
    static let maxVisibleRows = 3

    let primary: UsageMenuCardView.Model.Metric?
    let rows: [UsageMenuCardView.Model.Metric]
    let stats: [String]
    let headline: String
    let heroDetail: String?
    let emptyMessage: String

    init(card: UsageMenuCardView.Model?) {
        let metrics = card?.metrics ?? []
        self.primary = metrics.first
        self.rows = Array(metrics.dropFirst())
        self.headline = card?.providerName ?? "CodexBar"
        self.heroDetail = card?.planText ?? metrics.first?.detailLeftText ?? metrics.first?.detailText
        self.emptyMessage = card?.placeholder ?? card?.subtitleText ?? L("Loading…")

        var stats: [String] = []
        if let credits = card?.creditsText { stats.append(credits) }
        if let cost = card?.providerCost?.spendLine { stats.append(cost) }
        if let session = card?.tokenUsage?.sessionLine, stats.isEmpty { stats.append(session) }
        self.stats = Array(stats.prefix(2))
    }

    var visibleRowCount: Int {
        min(self.rows.count, Self.maxVisibleRows)
    }

    var rowsHeight: CGFloat {
        guard self.visibleRowCount > 0 else { return 0 }
        return Self.rowsTopInset
            + CGFloat(self.visibleRowCount) * Self.rowHeight
            + CGFloat(self.visibleRowCount - 1) * Self.rowSpacing
    }

    var height: CGFloat {
        Self.heroHeight
            + self.rowsHeight
            + (self.stats.isEmpty ? 0 : Self.statsHeight)
            + Self.footerHeight
            + Self.bottomInset
    }
}

// MARK: - Panel

@MainActor
final class NotchBarPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override var acceptsFirstResponder: Bool {
        false
    }

    /// AppKit otherwise pushes windows out from under the menu bar; the island has to sit on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Lets a single click reach a control even while CodexBar is in the background.
@MainActor
final class NotchIslandHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        self.sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The panel frame is managed explicitly by NotchBarController. NSHostingView's private
    /// window-layout hook otherwise tries to resize the window to its measured SwiftUI content.
    @objc private func windowDidLayout() {}

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

// MARK: - State

@MainActor
@Observable
final class NotchBarState {
    var phase: IslandShellPhase = .compact
    var pill: NotchPillContent?
    var selectedProvider: UsageProvider = .codex
    var enabledProviders: [UsageProvider] = []
    var card: UsageMenuCardView.Model?
    var taskAggregates: [AgentTaskProvider: AgentTaskProviderAggregate] = [:]
    var hookHealth: [AgentTaskProvider: AgentTaskHookHealth] = [:]
    var attention: AgentTaskAttention?
    var activeSession: AgentTaskSessionState?
    var hidePersonalInfo = false
    var notchSize = CGSize(width: 180, height: 32)
    var hasPhysicalNotch = true
    var fixtureIndicatorScenario: IslandShellFixtureIndicatorScenario?
    /// Horizontal correction so the island stays centered on the notch even when the host window
    /// had to be clamped to the screen edge.
    var centerOffset: CGFloat = 0
    var isPinned = false
    var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
}

// MARK: - NotchBarState + derived layout

extension NotchBarState {
    var shellPresentation: IslandShellPresentation {
        IslandShellPresentation(
            phase: self.phase,
            anchorSize: self.notchSize,
            hasPhysicalNotch: self.hasPhysicalNotch,
            fixture: .reference)
    }

    var plan: NotchDetailPlan {
        NotchDetailPlan(card: self.card)
    }

    var bodyWidth: CGFloat {
        self.shellPresentation.bodyWidth
    }

    var shoulderRadius: CGFloat {
        self.shellPresentation.shoulderRadius
    }

    var bottomRadius: CGFloat {
        self.shellPresentation.bottomRadius
    }

    var totalWidth: CGFloat {
        self.shellPresentation.totalWidth
    }

    var islandHeight: CGFloat {
        self.shellPresentation.height
    }

    var compactHeight: CGFloat {
        IslandShellMetrics.compactHeight
    }

    var collapsedPresentation: NotchCollapsedPresentation {
        if let fixtureIndicatorScenario {
            return NotchCollapsedPresentation.fixture(fixtureIndicatorScenario)
        }
        return NotchCollapsedPresentation.make(
            claude: self.taskAggregates[.claude]?.status ?? .idle,
            codex: self.taskAggregates[.codex]?.status ?? .idle,
            claudeConfigured: self.hookHealth[.claude]?.isConfiguredForTaskStatus == true,
            codexConfigured: self.hookHealth[.codex]?.isConfiguredForTaskStatus == true,
            attention: self.attention)
    }

    var taskDetailPlan: NotchTaskDetailPlan {
        NotchTaskDetailPlan(
            attention: self.attention,
            activeSession: self.activeSession,
            quota: NotchQuotaSummary(card: self.card),
            hidePersonalInfo: self.hidePersonalInfo)
    }

    var usedFraction: Double? {
        self.plan.primary.map { NotchPalette.usedFraction(for: $0) }
    }

    var isCritical: Bool {
        (self.usedFraction ?? 0) >= NotchPalette.criticalThreshold
    }

    var accent: (start: Color, end: Color) {
        guard let usedFraction = self.usedFraction else {
            return (Color(white: 0.5), Color(white: 0.72))
        }
        return NotchPalette.accent(usedFraction: usedFraction)
    }

    /// What the right wing shows: the same string the classic menu bar item would have rendered,
    /// falling back to the primary metric.
    var bandValueText: String {
        if let text = self.pill?.text, !text.isEmpty {
            return text
        }
        if let primary = self.plan.primary {
            return primary.percentLabel
        }
        return "—"
    }
}

// MARK: - Controller

@MainActor
final class NotchBarController: NSObject {
    let displayID: CGDirectDisplayID
    private let makeContent: @MainActor () -> NotchBarContentSnapshot
    private let onRefresh: @MainActor () -> Void
    private let onSettings: @MainActor () -> Void
    private let onSelectProvider: @MainActor (UsageProvider) -> Void
    private let onOpenTask: @MainActor () -> Void
    private let onDismissAttention: @MainActor () -> Void
    private let refreshMonitor: MenuCardRefreshMonitor?
    private let launchOptions = IslandShellLaunchOptions.current
    private let state = NotchBarState()
    private let panel: NotchBarPanel
    private var screen: NSScreen
    private var layout: NotchBarLayout?
    private var eventMonitors: [Any] = []
    private var pointerWatchdog: Timer?
    private var dwellTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var isPointerInside = false
    private var hoverZone: CGRect = .zero
    private var lastCollapsedAt: Date?
    private var lastFullscreenCheckAt = Date.distantPast
    private var cachedFullscreen = false

    var isActive: Bool {
        self.layout != nil
    }

    var isExpanded: Bool {
        self.state.phase == .expanded
    }

    var screenFrame: CGRect {
        self.screen.frame
    }

    var isOnMainScreen: Bool {
        self.screen === NSScreen.main
    }

    init(
        displayID: CGDirectDisplayID,
        screen: NSScreen,
        layout: NotchBarLayout,
        refreshMonitor: MenuCardRefreshMonitor?,
        makeContent: @escaping @MainActor () -> NotchBarContentSnapshot,
        onRefresh: @escaping @MainActor () -> Void,
        onSettings: @escaping @MainActor () -> Void,
        onSelectProvider: @escaping @MainActor (UsageProvider) -> Void,
        onOpenTask: @escaping @MainActor () -> Void,
        onDismissAttention: @escaping @MainActor () -> Void)
    {
        self.displayID = displayID
        self.screen = screen
        self.layout = layout
        self.refreshMonitor = refreshMonitor
        self.makeContent = makeContent
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.onSelectProvider = onSelectProvider
        self.onOpenTask = onOpenTask
        self.onDismissAttention = onDismissAttention
        self.panel = NotchBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        super.init()
        self.configurePanel()
        self.state.notchSize = layout.anchorRect.size
        self.state.hasPhysicalNotch = layout.hasPhysicalNotch
        self.state.phase = self.launchOptions.phase
        self.state.fixtureIndicatorScenario = self.launchOptions.isFixture
            ? self.launchOptions.indicatorScenario
            : nil
        self.state.reduceMotion = self.launchOptions.reduceMotion
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.applyPanelFrame()
        if self.launchOptions.isFixture {
            self.panel.styleMask = [.borderless]
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
        } else {
            self.panel.orderFrontRegardless()
        }
        self.installEventMonitors()
        self.refreshPillContent()
        self.refreshHoverZone()
    }

    // MARK: - Setup

    private func configurePanel() {
        IslandShellFont.register()
        self.panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        self.panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        self.panel.backgroundColor = .clear
        self.panel.isOpaque = false
        self.panel.hasShadow = false
        self.panel.isMovable = false
        self.panel.isMovableByWindowBackground = false
        self.panel.isReleasedWhenClosed = false
        self.panel.hidesOnDeactivate = false
        self.panel.canHide = false
        self.panel.ignoresMouseEvents = true
        self.panel.acceptsMouseMovedEvents = true
        self.panel.isExcludedFromWindowsMenu = true
        self.panel.becomesKeyOnlyIfNeeded = true
        self.panel.setAccessibilityElement(true)
        self.panel.setAccessibilityRole(.window)
        self.panel.setAccessibilitySubrole(.floatingWindow)
        self.panel.setAccessibilityTitle(L("Usage"))

        let hosting = NotchIslandHostingView(
            rootView: NotchIslandView(state: self.state, actions: self.makeActions()))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.autoresizingMask = [.width, .height]
        self.panel.contentView = hosting
    }

    private func makeActions() -> NotchIslandActions {
        NotchIslandActions(
            refresh: { [weak self] in self?.onRefresh() },
            settings: { [weak self] in
                self?.setPinned(false)
                self?.collapseNow()
                self?.onSettings()
            },
            selectProvider: { [weak self] provider in self?.onSelectProvider(provider) },
            togglePinned: { [weak self] in
                guard let self else { return }
                self.setPinned(!self.state.isPinned)
            },
            toggleExpanded: { [weak self] in self?.toggle() },
            openTask: { [weak self] in
                guard let self else { return }
                self.onOpenTask()
                self.collapseAttention()
            },
            // Redundant entry signal: AppKit tracking areas still fire when a mouse-moved event is
            // dropped (fast flicks, Space switches). Exits stay owned by the pointer watchdog so a
            // transient SwiftUI hover glitch can never slam the panel shut under the pointer.
            hoverEntered: { [weak self] in self?.pointerDidEnter() })
    }

    // MARK: - Public API

    func update(screen: NSScreen, layout: NotchBarLayout) {
        self.screen = screen
        let isNewLayout = self.layout != layout
        self.layout = layout
        self.state.notchSize = layout.anchorRect.size
        self.state.hasPhysicalNotch = layout.hasPhysicalNotch
        if isNewLayout {
            self.applyPanelFrame()
        }
        if !self.panel.isVisible {
            self.panel.orderFrontRegardless()
        }
        self.installEventMonitors()
        self.refreshPillContent()
        self.refreshHoverZone()
    }

    func refreshPillContent() {
        guard self.isActive else { return }
        let content = self.makeContent()
        // Reuse the menu card's freeze so a manual refresh does not blank the panel mid-flight.
        let card = content.cardModel.map {
            self.refreshMonitor?.model(for: content.selectedProvider, fallback: $0) ?? $0
        }
        withAnimation(NotchMotion.contentChange) {
            self.state.selectedProvider = content.selectedProvider
            self.state.enabledProviders = content.enabledProviders
            self.state.pill = content.pill
            self.state.card = card
            self.state.taskAggregates = content.taskAggregates
            self.state.hookHealth = content.hookHealth
            self.state.attention = content.attention
            self.state.activeSession = content.activeSession
            self.state.hidePersonalInfo = content.hidePersonalInfo
        }
        // Metric count drives the panel height, so the hit-box moves with the data.
        self.refreshHoverZone()
    }

    func refreshContent() {
        self.refreshPillContent()
    }

    func present(_: AgentTaskAttention) {}

    func collapseForExternalAttention() {}

    func collapseAttention() {}

    /// Used by the global hotkey and by clicks on the band.
    func toggle() {
        if self.state.phase == .expanded {
            self.collapseNow()
        } else if self.state.phase == .compact {
            guard NotchSurfaceVisibilityPolicy.shouldExpand(
                trigger: .click,
                isFullscreen: self.isFullscreen())
            else { return }
            self.setPhase(.expanded)
            self.startPointerWatchdog()
        }
    }

    var expansionOriginInScreen: CGPoint? {
        self.layout.map { CGPoint(x: $0.anchorRect.midX, y: $0.anchorRect.midY) }
    }

    func teardown() {
        self.cancelPendingWork()
        self.removeEventMonitors()
        self.stopPointerWatchdog()
        self.panel.orderOut(nil)
        self.state.phase = .dormant
        self.state.isPinned = false
        self.layout = nil
        self.hoverZone = .zero
    }

    private func applyPanelFrame() {
        guard let layout else { return }
        self.panel.setFrame(layout.stageFrame, display: true)
        self.state.centerOffset = layout.anchorRect.midX - layout.stageFrame.midX
    }

    // MARK: - Hover choreography

    /// Pointer tracking runs on every mouse-moved event, so the hit-box is cached instead of being
    /// rebuilt (and re-measuring the detail plan) per event.
    private func handlePointerActivity() {
        guard self.layout != nil else { return }
        let pointerLocation = NSEvent.mouseLocation
        self.updatePanelMouseEventPolicy(pointerLocation: pointerLocation)
        if self.hoverZone.contains(pointerLocation) {
            self.pointerDidEnter()
        } else {
            self.pointerDidExit()
        }
    }

    /// Recomputes the hit-box: the sleeping grab strip, or the island silhouette plus a forgiveness
    /// margin so a slightly wandering pointer does not slam the panel shut.
    private func refreshHoverZone() {
        defer { self.updatePanelMouseEventPolicy(pointerLocation: NSEvent.mouseLocation) }
        guard let layout else {
            self.hoverZone = .zero
            return
        }
        let shell = self.state.shellPresentation
        let visibleBounds = CGRect(
            x: layout.anchorRect.midX - shell.totalWidth / 2,
            y: layout.stageFrame.maxY - shell.height,
            width: shell.totalWidth,
            height: shell.height)
        self.hoverZone = IslandShellInteractionPolicy.hoverZone(visibleBounds: visibleBounds)
    }

    private func updatePanelMouseEventPolicy(pointerLocation: CGPoint) {
        self.panel.ignoresMouseEvents = NotchMouseEventPolicy.ignoresMouseEvents(
            pointerLocation: pointerLocation,
            hoverZone: self.hoverZone,
            isFixture: self.launchOptions.isFixture)
    }

    private func pointerDidEnter() {
        self.collapseTask?.cancel()
        self.collapseTask = nil
        guard IslandShellInteractionPolicy.canEnter(
            now: Date(),
            collapsedAt: self.lastCollapsedAt)
        else { return }
        guard !self.isPointerInside else { return }
        guard NotchSurfaceVisibilityPolicy.shouldExpand(
            trigger: .hover,
            isFullscreen: self.isFullscreen())
        else { return }
        self.isPointerInside = true
        if self.state.phase == .compact {
            self.scheduleDwellExpansion()
            self.startPointerWatchdog()
        }
    }

    private func pointerDidExit() {
        guard self.isPointerInside else { return }
        self.isPointerInside = false
        self.dwellTask?.cancel()
        self.dwellTask = nil
        if self.state.phase == .expanded {
            self.scheduleCollapse()
        }
    }

    private func scheduleDwellExpansion() {
        guard self.state.phase == .compact, self.dwellTask == nil else { return }
        self.dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(IslandShellMetrics.hoverDelay))
            guard !Task.isCancelled,
                  let self,
                  self.isPointerInside,
                  self.state.phase == .compact
            else { return }
            self.dwellTask = nil
            self.setPhase(.expanded)
        }
    }

    private func scheduleCollapse() {
        self.collapseTask?.cancel()
        self.collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(IslandShellMetrics.collapseDelay))
            guard !Task.isCancelled, let self, !self.isPointerInside else { return }
            self.collapseTask = nil
            self.collapseNow()
        }
    }

    private func collapseNow() {
        self.dwellTask?.cancel()
        self.dwellTask = nil
        guard self.state.phase == .expanded, !self.state.isPinned else { return }
        self.lastCollapsedAt = Date()
        self.setPhase(.compact)
    }

    /// Single funnel for phase changes so the cached hit-box can never fall out of sync with the
    /// silhouette the user actually sees.
    private func setPhase(_ phase: IslandShellPhase) {
        withAnimation(IslandShellMotion.container(reduceMotion: self.state.reduceMotion)) {
            self.state.phase = phase
        }
        self.refreshHoverZone()
    }

    private func setPinned(_ pinned: Bool) {
        self.state.isPinned = pinned
        if !pinned, !self.isPointerInside {
            self.scheduleCollapse()
        }
    }

    private func cancelPendingWork() {
        self.dwellTask?.cancel()
        self.dwellTask = nil
        self.collapseTask?.cancel()
        self.collapseTask = nil
    }

    private func isFullscreen(now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(self.lastFullscreenCheckAt) >= 0.5 else {
            return self.cachedFullscreen
        }
        self.lastFullscreenCheckAt = now
        self.cachedFullscreen = NotchFullscreenDetector.isFullscreen(on: self.screen)
        return self.cachedFullscreen
    }

    // MARK: - Event plumbing

    private func installEventMonitors() {
        guard self.eventMonitors.isEmpty else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePointerActivity() }
        }) {
            self.eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            self?.handlePointerActivity()
            return event
        }) {
            self.eventMonitors.append(monitor)
        }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleClickOutside() }
        }) {
            self.eventMonitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard event.keyCode == 53, let self, self.state.phase == .expanded else { return event }
            self.collapseNow()
            return nil
        }) {
            self.eventMonitors.append(monitor)
        }
    }

    private func handleClickOutside() {
        guard self.state.phase == .expanded else { return }
        guard !self.hoverZone.contains(NSEvent.mouseLocation) else { return }
        self.collapseNow()
    }

    private func removeEventMonitors() {
        for monitor in self.eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        self.eventMonitors.removeAll()
    }

    /// Belt-and-braces exit detection: pointer moves are event driven, but a fast flick or a Space
    /// switch can drop the final move event, and a stuck-open panel would be worse than a 4 Hz timer.
    private func startPointerWatchdog() {
        guard self.pointerWatchdog == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handlePointerActivity() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.pointerWatchdog = timer
    }

    private func stopPointerWatchdog() {
        self.pointerWatchdog?.invalidate()
        self.pointerWatchdog = nil
    }
}
