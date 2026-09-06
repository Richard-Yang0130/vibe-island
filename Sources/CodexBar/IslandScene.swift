import CodexBarCore
import CoreGraphics

/// Every content state the island can show, and the single source of truth for its geometry.
///
/// The shell used to carry a three-value phase (`dormant/compact/expanded`), which could not
/// express "expanded, but showing an approval instead of the overview". Scenes replace it: the
/// geometry table below is keyed by scene, so adding a content state can never desync the
/// silhouette from what is rendered inside it.
enum IslandScene: String, Equatable, CaseIterable {
    /// No visible island — only the transparent hit area over the hardware notch.
    case dormant
    /// Ambient state. On notched hardware this is the bare cut-out plus edge status lights.
    case compact
    /// Session list: usage strip, primary session, secondary sessions.
    case overview
    /// A session is waiting for a permission decision.
    case approval
    /// A session is waiting for an answer.
    case ask
    /// Everything finished; cards become jump targets.
    case done
    /// Narrow confirmation strip that auto-falls back to `compact`.
    case ack

    /// Scenes that render the full expanded body. `dormant`/`compact`/`ack` do not.
    var isExpanded: Bool {
        switch self {
        case .overview, .approval, .ask, .done: true
        case .dormant, .compact, .ack: false
        }
    }

    /// True when the scene was raised because a session needs the user, so the collapse
    /// choreography must not quietly swallow it.
    var demandsAttention: Bool {
        switch self {
        case .approval, .ask: true
        case .dormant, .compact, .overview, .done, .ack: false
        }
    }
}

/// Per-scene geometry. Widths and heights follow the public Vibe Island baseline recorded in
/// `docs/vibe-island-interaction-research.md` §4.1.
enum IslandSceneMetrics {
    /// Content width for scenes that do not derive their width from the hardware anchor.
    static func bodyWidth(_ scene: IslandScene) -> CGFloat? {
        switch scene {
        case .dormant, .compact: nil
        case .overview, .done: 430
        case .approval: 430
        case .ask: 400
        case .ack: 280
        }
    }

    /// Height of one session row, and the chrome around the list.
    ///
    /// `IslandSessionCardView` pins itself to `sessionRowHeight`, so this arithmetic cannot drift
    /// from what actually renders. It did drift once: rows with a subtitle are taller than rows
    /// without, the estimate was between the two, and the quota strip ended up outside the
    /// silhouette.
    static let sessionRowHeight: CGFloat = 52
    static let sessionRowSpacing: CGFloat = 8
    /// Pane padding, the spacing above the quota strip, and the strip itself with its divider.
    static let listChromeHeight: CGFloat = 72
    static let toolbarHeight: CGFloat = 28
    /// The "click to jump" line that only the done scene carries.
    static let jumpHintHeight: CGFloat = 22
    /// Beyond this the list scrolls rather than growing into a wall of black.
    static let maxVisibleSessions = 6

    static func height(_ scene: IslandScene, cardCount: Int = 0) -> CGFloat? {
        switch scene {
        case .dormant, .compact:
            return nil
        // The session list grows to fit what is actually running: a fixed height either hides
        // sessions behind a "+N" or leaves a black gap when only one is live.
        case .overview, .done:
            let rows = min(max(cardCount, 1), self.maxVisibleSessions)
            return self.listChromeHeight + self.toolbarHeight
                + (scene == .done ? self.jumpHintHeight : 0)
                + CGFloat(rows) * self.sessionRowHeight
                + CGFloat(rows - 1) * self.sessionRowSpacing
        case .approval:
            return 245
        case .ask:
            return 215
        case .ack:
            return 42
        }
    }

    static func bottomRadius(_ scene: IslandScene) -> CGFloat {
        switch scene {
        case .dormant: 0
        case .compact: IslandShellMetrics.compactBottomRadius
        case .ack: IslandShellMetrics.compactBottomRadius
        case .overview, .approval, .ask, .done: IslandShellMetrics.expandedBottomRadius
        }
    }
}

/// Outer glow tint per scene.
///
/// Deliberately a glow and not a stroke: the island is a pure-black solid so it fuses with the
/// hardware notch, and any border would break the "grew out of the screen" read.
struct IslandGlow: Equatable {
    let color: IslandStatusColor
    let opacity: Double
    let radius: CGFloat

    static func of(_ scene: IslandScene) -> IslandGlow? {
        switch scene {
        case .dormant, .compact, .ack: nil
        case .overview: IslandGlow(color: .neutral, opacity: 0.05, radius: 15)
        case .approval: IslandGlow(color: .alert, opacity: 0.20, radius: 22)
        case .ask: IslandGlow(color: .question, opacity: 0.20, radius: 22)
        case .done: IslandGlow(color: .idle, opacity: 0.16, radius: 18)
        }
    }
}

/// Which scene the island should be showing, given what the agents are doing.
///
/// Pure decision table so the policy is testable without AppKit. The controller owns the timers;
/// this only answers "what should be on screen".
enum IslandScenePolicy {
    /// Scene to raise when new agent state arrives while the island is idle in `compact`.
    ///
    /// Ordinary `running` never interrupts — that is the whole point of the ambient state.
    static func autoRaise(for status: AgentTaskStatus?) -> IslandScene? {
        switch status {
        case .needsApproval: .approval
        case .failed, .interrupted, .disconnected: .overview
        case .completed: .done
        case .running, .idle, .none: nil
        }
    }

    /// A newly blocking request must be actionable even while another scene is already open.
    static func canPresentAttention(_ incoming: IslandScene?, from current: IslandScene) -> Bool {
        guard let incoming, current != .dormant else { return false }
        return current == .compact || incoming == .approval
    }

    /// Scene the user lands on when they open the island by hand.
    static func manualExpansion(for status: AgentTaskStatus?) -> IslandScene {
        switch status {
        case .needsApproval: .approval
        case .completed: .done
        case .running, .idle, .failed, .interrupted, .disconnected, .none: .overview
        }
    }

    static let completionDwell: Double = 2.2

    // Keep independent UI guards explicit so this pure policy can be tested without AppKit state.
    // swiftlint:disable:next function_parameter_count
    static func canAutomaticallyCollapse(
        scene: IslandScene,
        status: AgentTaskStatus?,
        hasPendingApproval: Bool,
        pointerInside: Bool,
        keyboardFocus: Bool,
        pinned: Bool,
        elapsed: Double) -> Bool
    {
        guard !pointerInside, !keyboardFocus, !pinned, !hasPendingApproval,
              !scene.demandsAttention else { return false }
        switch status {
        case .needsApproval, .failed, .interrupted, .disconnected: return false
        default: return scene != .done || elapsed >= self.completionDwell
        }
    }

    /// Seconds the acknowledgement strip stays up before falling back to `compact`.
    static let acknowledgementDwell: Double = 2.0
}

/// IDs are local to this controller lifetime; a refresh must not replay dismissed attention.
struct IslandPresentedAttention {
    private var ids: Set<String> = []

    mutating func markIfNew(_ id: String) -> Bool {
        self.ids.insert(id).inserted
    }
}
