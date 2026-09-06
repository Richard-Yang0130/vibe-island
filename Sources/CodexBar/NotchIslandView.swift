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

// MARK: - Provider lights

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
    var requiresUserAction: Bool {
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

/// Severity-driven accent ramp used by the usage strip. The island is pure black so it fuses with
/// the physical notch; every bit of color comes from these thresholds.
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
}

// MARK: - Actions

struct NotchIslandActions {
    var refresh: @MainActor () -> Void
    var decideApproval: @MainActor (IslandApprovalRequest, AgentTaskApprovalAction) -> Void
    var settings: @MainActor () -> Void
    var selectProvider: @MainActor (UsageProvider) -> Void
    var togglePinned: @MainActor () -> Void
    var toggleExpanded: @MainActor () -> Void
    var openTask: @MainActor (IslandSessionCard) -> Void
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
                content: self.state.islandContent,
                reduceMotion: self.state.reduceMotion,
                actions: IslandShellActions(
                    toggleExpanded: self.actions.toggleExpanded,
                    hoverEntered: self.actions.hoverEntered,
                    openSession: self.actions.openTask,
                    dismiss: self.actions.toggleExpanded,
                    decide: self.actions.decideApproval,
                    refresh: self.actions.refresh,
                    settings: self.actions.settings,
                    togglePinned: self.actions.togglePinned,
                    selectProvider: self.actions.selectProvider,
                    providers: self.state.enabledProviders,
                    pinned: self.state.isPinned))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .offset(x: self.state.centerOffset)
    }
}
