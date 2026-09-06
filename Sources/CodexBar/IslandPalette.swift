import CodexBarCore
import SwiftUI

/// Semantic status colors. This is a state machine, not a theme — each color means one thing and
/// only one thing, so a user learns the mapping once and reads it everywhere.
///
/// Values are literal components on purpose. Anything that resolves through the environment
/// (semantic colors, appearance-dependent assets) can silently render near-black on the island's
/// pure-black body, which reads as "the sprite disappeared".
enum IslandStatusColor: Equatable {
    /// Idle, finished, safe to continue.
    case idle
    /// Running a turn or a tool call.
    case working
    /// Waiting for a permission decision.
    case alert
    /// Waiting for an answer.
    case question
    /// Ended, interrupted, or unavailable.
    case ended
    /// Failed, or an action that gives up control.
    case danger
    /// No semantics — plain chrome.
    case neutral

    var color: Color {
        let rgb = self.components
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    var components: (Double, Double, Double) {
        switch self {
        case .idle: (0x22 / 255, 0xC5 / 255, 0x5E / 255)
        case .working: (0x3B / 255, 0x82 / 255, 0xF6 / 255)
        case .alert: (0xF9 / 255, 0x73 / 255, 0x16 / 255)
        case .question: (0x06 / 255, 0xB6 / 255, 0xD4 / 255)
        case .ended: (0x73 / 255, 0x73 / 255, 0x73 / 255)
        case .danger: (0xDC / 255, 0x26 / 255, 0x26 / 255)
        case .neutral: (1, 1, 1)
        }
    }
}

/// Per-agent brand color for the identity sprite slot.
enum IslandAgentColor {
    static func color(for provider: AgentTaskProvider) -> Color {
        switch provider {
        case .claude: Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex: Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255)
        }
    }

    static func displayName(for provider: AgentTaskProvider) -> String {
        switch provider {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// Quota health, which is deliberately independent of session status: a session can be running
/// happily while the account is nearly out of quota.
enum IslandQuotaColor {
    static func color(usedFraction: Double) -> Color {
        if usedFraction < NotchPalette.warningThreshold {
            return IslandStatusColor.idle.color
        }
        if usedFraction < NotchPalette.criticalThreshold {
            return IslandStatusColor.alert.color
        }
        return Color(red: 0xEF / 255, green: 0x44 / 255, blue: 0x44 / 255)
    }
}

extension AgentTaskStatus {
    /// Status color used by the sprite slot, the card dot and the compact label.
    var islandColor: IslandStatusColor {
        switch self {
        case .idle: .idle
        case .running: .working
        case .needsApproval: .alert
        case .completed: .idle
        case .failed: .danger
        case .interrupted, .disconnected: .ended
        }
    }
}
