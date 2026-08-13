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
}

// MARK: - Phase

/// Three-step reveal: invisible until the pointer arrives, a menu-bar-height teaser on approach,
/// then the full panel once the pointer settles.
enum NotchPhase: Equatable {
    case dormant
    case peek
    case expanded
}

// MARK: - Geometry

struct NotchBarLayout: Equatable {
    /// The hardware cut-out, in screen coordinates.
    let notchRect: CGRect
    /// Window footprint while asleep — just the notch plus a sliver of grab area below it.
    let dormantFrame: CGRect
    /// Window footprint while open. Everything outside the island silhouette stays transparent,
    /// so clicks in the margins fall through to the apps underneath.
    let stageFrame: CGRect
}

enum NotchGeometry {
    /// How far each wing extends past the notch while peeking.
    static let peekWingWidth: CGFloat = 116
    static let expandedBodyWidth: CGFloat = 428
    static let shoulderRadius: CGFloat = 13
    static let peekBottomRadius: CGFloat = 15
    static let expandedBottomRadius: CGFloat = 26
    static let stageHeight: CGFloat = 520
    /// Slack on both sides of the stage window so the island's drop shadow is not clipped.
    static let stageSideMargin: CGFloat = 44
    /// Extra pointer-catching width/height around the sleeping notch.
    static let dormantSideGrab: CGFloat = 20
    static let dormantBottomGrab: CGFloat = 8
    /// Forgiveness margin so a slightly wandering pointer does not collapse the panel.
    static let hoverGrace: CGFloat = 16

    static var stageWidth: CGFloat {
        self.expandedBodyWidth + self.shoulderRadius * 2 + self.stageSideMargin * 2
    }

    static func layout(
        screenFrame: CGRect,
        leftArea: CGRect?,
        rightArea: CGRect?,
        stageWidth: CGFloat = Self.stageWidth,
        stageHeight: CGFloat = Self.stageHeight)
        -> NotchBarLayout?
    {
        guard let leftArea, let rightArea else { return nil }
        let notchMinX = leftArea.maxX
        let notchMaxX = rightArea.minX
        let notchMinY = max(leftArea.minY, rightArea.minY)
        let notchMaxY = min(leftArea.maxY, rightArea.maxY)
        guard notchMaxX > notchMinX, notchMaxY > notchMinY else { return nil }

        let notchRect = CGRect(
            x: notchMinX,
            y: notchMinY,
            width: notchMaxX - notchMinX,
            height: notchMaxY - notchMinY)

        let dormantWidth = min(notchRect.width + self.dormantSideGrab * 2, screenFrame.width)
        let dormantHeight = min(notchRect.height + self.dormantBottomGrab, screenFrame.height)
        let dormantFrame = CGRect(
            x: self.clampedOriginX(center: notchRect.midX, width: dormantWidth, screenFrame: screenFrame),
            y: screenFrame.maxY - dormantHeight,
            width: dormantWidth,
            height: dormantHeight)

        let clampedStageWidth = min(stageWidth, screenFrame.width)
        let clampedStageHeight = min(stageHeight, screenFrame.height)
        let stageFrame = CGRect(
            x: self.clampedOriginX(center: notchRect.midX, width: clampedStageWidth, screenFrame: screenFrame),
            y: screenFrame.maxY - clampedStageHeight,
            width: clampedStageWidth,
            height: clampedStageHeight)

        return NotchBarLayout(notchRect: notchRect, dormantFrame: dormantFrame, stageFrame: stageFrame)
    }

    private static func clampedOriginX(center: CGFloat, width: CGFloat, screenFrame: CGRect) -> CGFloat {
        min(max(center - width / 2, screenFrame.minX), screenFrame.maxX - width)
    }

    static func layout(on screen: NSScreen) -> NotchBarLayout? {
        self.layout(
            screenFrame: screen.frame,
            leftArea: screen.auxiliaryTopLeftArea,
            rightArea: screen.auxiliaryTopRightArea)
    }

    /// Finds the physical notched display even when an external display owns the menu bar.
    static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first(where: { self.layout(on: $0) != nil })
    }
}

enum NotchMouseEventPolicy {
    static func ignoresMouseEvents(pointerLocation: CGPoint, hoverZone: CGRect) -> Bool {
        !hoverZone.contains(pointerLocation)
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

// MARK: - State

@MainActor
@Observable
final class NotchBarState {
    var phase: NotchPhase = .dormant
    var pill: NotchPillContent?
    var selectedProvider: UsageProvider = .codex
    var enabledProviders: [UsageProvider] = []
    var card: UsageMenuCardView.Model?
    var notchSize = CGSize(width: 180, height: 32)
    /// Horizontal correction so the island stays centered on the notch even when the host window
    /// had to be clamped to the screen edge.
    var centerOffset: CGFloat = 0
    var isPinned = false
}

// MARK: - NotchBarState + derived layout

extension NotchBarState {
    var plan: NotchDetailPlan {
        NotchDetailPlan(card: self.card)
    }

    var bodyWidth: CGFloat {
        switch self.phase {
        case .dormant:
            self.notchSize.width
        case .peek:
            self.notchSize.width + NotchGeometry.peekWingWidth * 2
        case .expanded:
            max(NotchGeometry.expandedBodyWidth, self.notchSize.width + NotchGeometry.peekWingWidth)
        }
    }

    var shoulderRadius: CGFloat {
        self.phase == .dormant ? 0 : NotchGeometry.shoulderRadius
    }

    var bottomRadius: CGFloat {
        switch self.phase {
        case .dormant: 0
        case .peek: NotchGeometry.peekBottomRadius
        case .expanded: NotchGeometry.expandedBottomRadius
        }
    }

    var totalWidth: CGFloat {
        self.bodyWidth + self.shoulderRadius * 2
    }

    var islandHeight: CGFloat {
        self.phase == .expanded
            ? self.notchSize.height + self.plan.height
            : self.notchSize.height
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
    private let makeContent: @MainActor () -> NotchBarContentSnapshot
    private let onRefresh: @MainActor () -> Void
    private let onSettings: @MainActor () -> Void
    private let onSelectProvider: @MainActor (UsageProvider) -> Void
    private let refreshMonitor: MenuCardRefreshMonitor?
    private let state = NotchBarState()
    private let panel: NotchBarPanel
    private var layout: NotchBarLayout?
    private var eventMonitors: [Any] = []
    private var pointerWatchdog: Timer?
    private var dwellTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var isPointerInside = false
    private var hoverZone: CGRect = .zero
    private var greetingTask: Task<Void, Never>?
    private var hasGreeted = false

    /// Delay before a hovering pointer promotes the teaser into the full panel.
    private static let dwellInterval: Double = 0.2
    /// Grace period before an exited pointer closes the panel.
    private static let collapseDelay: Double = 0.32

    var isActive: Bool {
        self.layout != nil
    }

    var isExpanded: Bool {
        self.state.phase == .expanded
    }

    init(
        refreshMonitor: MenuCardRefreshMonitor?,
        makeContent: @escaping @MainActor () -> NotchBarContentSnapshot,
        onRefresh: @escaping @MainActor () -> Void,
        onSettings: @escaping @MainActor () -> Void,
        onSelectProvider: @escaping @MainActor (UsageProvider) -> Void)
    {
        self.refreshMonitor = refreshMonitor
        self.makeContent = makeContent
        self.onRefresh = onRefresh
        self.onSettings = onSettings
        self.onSelectProvider = onSelectProvider
        self.panel = NotchBarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        super.init()
        self.configurePanel()
    }

    // MARK: - Setup

    private func configurePanel() {
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
            // Redundant entry signal: AppKit tracking areas still fire when a mouse-moved event is
            // dropped (fast flicks, Space switches). Exits stay owned by the pointer watchdog so a
            // transient SwiftUI hover glitch can never slam the panel shut under the pointer.
            hoverEntered: { [weak self] in self?.pointerDidEnter() })
    }

    // MARK: - Public API

    /// Re-evaluates whether a notched display is attached and shows/hides the island accordingly.
    func updateAvailability() {
        let screen = NotchGeometry.notchedScreen()
        guard let screen, let layout = NotchGeometry.layout(on: screen) else {
            self.deactivate()
            return
        }
        let isNewLayout = self.layout != layout
        self.layout = layout
        self.state.notchSize = layout.notchRect.size
        if isNewLayout {
            self.applyPanelFrame()
        }
        if !self.panel.isVisible {
            self.panel.orderFrontRegardless()
        }
        self.installEventMonitors()
        self.refreshPillContent()
        self.refreshHoverZone()
        self.presentGreetingIfNeeded()
    }

    /// A hidden control nobody knows about is a broken control. Once per launch the island peeks out
    /// of the notch and tucks itself back in, which both announces itself and teaches the gesture.
    private func presentGreetingIfNeeded() {
        guard !self.hasGreeted else { return }
        self.hasGreeted = true
        self.greetingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.7))
            guard !Task.isCancelled, let self, self.isActive, self.state.phase == .dormant else { return }
            self.openStage()
            self.setPhase(.peek, animation: NotchMotion.expanding)
            self.startPointerWatchdog()
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, !self.isPointerInside, !self.state.isPinned else { return }
            self.collapseNow()
        }
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
        }
        // Metric count drives the panel height, so the hit-box moves with the data.
        self.refreshHoverZone()
    }

    /// Used by the global hotkey and by clicks on the band.
    func toggle() {
        if self.state.phase == .expanded {
            self.setPinned(false)
            self.collapseNow()
        } else {
            self.setPinned(true)
            self.openStage()
            self.setPhase(.expanded, animation: NotchMotion.expanding)
            self.startPointerWatchdog()
        }
    }

    var expansionOriginInScreen: CGPoint? {
        self.layout.map { CGPoint(x: $0.notchRect.midX, y: $0.notchRect.midY) }
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

    // MARK: - Activation

    private func deactivate() {
        guard self.layout != nil || self.panel.isVisible else { return }
        self.cancelPendingWork()
        self.removeEventMonitors()
        self.stopPointerWatchdog()
        self.state.phase = .dormant
        self.state.isPinned = false
        self.isPointerInside = false
        self.layout = nil
        self.hoverZone = .zero
        self.panel.orderOut(nil)
    }

    private func applyPanelFrame() {
        guard let layout else { return }
        let frame = self.state.phase == .dormant ? layout.dormantFrame : layout.stageFrame
        self.panel.setFrame(frame, display: true)
        self.state.centerOffset = layout.notchRect.midX - frame.midX
    }

    /// Grows the host window to its full footprint *before* the island animates, so the expanding
    /// silhouette is never clipped by the window edge.
    private func openStage() {
        self.settleTask?.cancel()
        self.settleTask = nil
        guard let layout, self.panel.frame != layout.stageFrame else { return }
        self.panel.setFrame(layout.stageFrame, display: true)
        self.state.centerOffset = layout.notchRect.midX - layout.stageFrame.midX
    }

    /// Shrinks the window back to the notch once the collapse animation has finished, restoring
    /// click-through for everything below the menu bar.
    private func scheduleStageSettle() {
        self.settleTask?.cancel()
        self.settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NotchMotion.collapseSettleDelay))
            guard !Task.isCancelled, let self, self.state.phase == .dormant, let layout = self.layout else { return }
            self.panel.setFrame(layout.dormantFrame, display: true)
            self.state.centerOffset = layout.notchRect.midX - layout.dormantFrame.midX
            self.stopPointerWatchdog()
        }
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
        guard self.state.phase != .dormant else {
            self.hoverZone = layout.dormantFrame
            return
        }
        let width = self.state.totalWidth
        let height = self.state.islandHeight
        self.hoverZone = CGRect(
            x: layout.notchRect.midX - width / 2,
            y: layout.stageFrame.maxY - height,
            width: width,
            height: height)
            .insetBy(dx: -NotchGeometry.hoverGrace, dy: -NotchGeometry.hoverGrace)
    }

    private func updatePanelMouseEventPolicy(pointerLocation: CGPoint) {
        self.panel.ignoresMouseEvents = NotchMouseEventPolicy.ignoresMouseEvents(
            pointerLocation: pointerLocation,
            hoverZone: self.hoverZone)
    }

    private func pointerDidEnter() {
        self.collapseTask?.cancel()
        self.collapseTask = nil
        guard !self.isPointerInside else { return }
        self.isPointerInside = true
        if self.state.phase == .dormant {
            self.openStage()
            self.setPhase(.peek, animation: NotchMotion.expanding)
            self.startPointerWatchdog()
        }
        self.scheduleDwellExpansion()
    }

    private func pointerDidExit() {
        guard self.isPointerInside else { return }
        self.isPointerInside = false
        self.dwellTask?.cancel()
        self.dwellTask = nil
        guard !self.state.isPinned else { return }
        self.scheduleCollapse()
    }

    private func scheduleDwellExpansion() {
        guard self.state.phase == .peek, self.dwellTask == nil else { return }
        self.dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.dwellInterval))
            guard !Task.isCancelled, let self, self.isPointerInside, self.state.phase == .peek else { return }
            self.dwellTask = nil
            self.setPhase(.expanded, animation: NotchMotion.expanding)
        }
    }

    private func scheduleCollapse() {
        self.collapseTask?.cancel()
        self.collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.collapseDelay))
            guard !Task.isCancelled, let self, !self.isPointerInside, !self.state.isPinned else { return }
            self.collapseTask = nil
            self.collapseNow()
        }
    }

    private func collapseNow() {
        self.dwellTask?.cancel()
        self.dwellTask = nil
        guard self.state.phase != .dormant else { return }
        self.setPhase(.dormant, animation: NotchMotion.collapsing)
        self.scheduleStageSettle()
    }

    /// Single funnel for phase changes so the cached hit-box can never fall out of sync with the
    /// silhouette the user actually sees.
    private func setPhase(_ phase: NotchPhase, animation: Animation) {
        withAnimation(animation) {
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
        self.settleTask?.cancel()
        self.settleTask = nil
        self.greetingTask?.cancel()
        self.greetingTask = nil
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
            guard event.keyCode == 53, let self, self.state.phase != .dormant else { return event }
            self.setPinned(false)
            self.collapseNow()
            return nil
        }) {
            self.eventMonitors.append(monitor)
        }
    }

    private func handleClickOutside() {
        guard self.state.phase != .dormant else { return }
        guard !self.hoverZone.contains(NSEvent.mouseLocation) else { return }
        self.setPinned(false)
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
