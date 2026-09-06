import CodexBarCore
import Foundation

// MARK: - Duration

enum IslandDuration {
    /// Compact duration in the prototype's vocabulary: `27m`, `1h04`, `5h`, `2d3h`.
    ///
    /// Monospaced digits plus a fixed shape keep the right-hand column of the session list aligned;
    /// a free-form "1 hour 4 minutes" would make the list ragged at this density.
    static func compact(_ interval: TimeInterval) -> String? {
        guard interval.isFinite, interval >= 0 else { return nil }
        let totalMinutes = Int(interval / 60)
        guard totalMinutes >= 1 else { return nil }
        if totalMinutes < 60 {
            return "\(totalMinutes)m"
        }
        let totalHours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if totalHours < 24 {
            return minutes == 0 ? "\(totalHours)h" : String(format: "%dh%02d", totalHours, minutes)
        }
        let days = totalHours / 24
        let hours = totalHours % 24
        return hours == 0 ? "\(days)d" : "\(days)d\(hours)h"
    }
}

// MARK: - Usage strip

struct IslandUsageMetric: Equatable, Identifiable {
    let id: String
    /// Window label such as `5h` or `7d`.
    let window: String
    let percentText: String
    let resetText: String?
    let usedFraction: Double
}

/// Top strip of every expanded scene. Nil when there is no real usage data — the island shows
/// nothing rather than a plausible-looking placeholder number.
struct IslandUsageStrip: Equatable {
    let providerName: String
    let metrics: [IslandUsageMetric]

    /// The single reading the compact island can afford to show.
    ///
    /// Only the percentage: a compact wing has room for about four glyphs, and real provider
    /// window labels are localized words ("每周"), not the two-character "5h" the prototype assumed.
    var compactReading: IslandUsageMetric? {
        self.metrics.first
    }

    init(providerName: String, metrics: [IslandUsageMetric]) {
        self.providerName = providerName
        self.metrics = metrics
    }

    init?(card: UsageMenuCardView.Model?) {
        guard let card else { return nil }
        // One window only. The strip is a glance, not a dashboard: a second metric doubles the
        // width and is what pushed the real localized labels into ellipses.
        let metrics = card.metrics.prefix(1).map { metric in
            IslandUsageMetric(
                id: metric.id,
                window: metric.title,
                percentText: metric.percentLabel,
                resetText: metric.resetText,
                usedFraction: NotchPalette.usedFraction(for: metric))
        }
        guard !metrics.isEmpty else { return nil }
        self.providerName = card.providerName
        self.metrics = Array(metrics)
    }
}

// MARK: - Session card

struct IslandSessionCard: Equatable, Identifiable {
    let id: String
    let sessionID: String
    let provider: AgentTaskProvider
    let status: AgentTaskStatus
    let title: String
    /// The user's goal line, or the completion hint. Suppressed when personal info is hidden.
    let subtitle: String?
    /// Agent, then host application when we could resolve one.
    let chips: [String]
    let duration: String?
    var companionIndex = 0
    var statusUpdatedAt: Date?

    /// Only finished sessions advertise the jump affordance; jumping into a running turn is a way
    /// to steal focus from the user for no reason.
    var isJumpTarget: Bool {
        self.status == .completed
    }

    init(
        id: String,
        sessionID: String? = nil,
        provider: AgentTaskProvider,
        status: AgentTaskStatus,
        title: String,
        subtitle: String?,
        chips: [String],
        duration: String?,
        companionIndex: Int = 0)
    {
        self.id = id
        self.sessionID = sessionID ?? id
        self.provider = provider
        self.status = status
        self.title = title
        self.subtitle = subtitle
        self.chips = chips
        self.duration = duration
        self.companionIndex = companionIndex
    }

    init(
        session: AgentTaskSessionState,
        host: String?,
        hidePersonalInfo: Bool,
        now: Date)
    {
        self.id = "\(session.provider.rawValue):\(session.sessionID)"
        self.sessionID = session.sessionID
        self.provider = session.provider
        self.status = session.status
        self.statusUpdatedAt = session.updatedAt

        let projectName = session.projectPath
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0 == "/" ? nil : $0 }
        if hidePersonalInfo {
            self.title = session.status.displayName
            self.subtitle = nil
        } else {
            self.title = session.taskTitle
                ?? projectName
                ?? IslandAgentColor.displayName(for: session.provider)
            self.subtitle = session.status == .completed ? L("agent_task_open") : nil
        }

        var chips = [IslandAgentColor.displayName(for: session.provider)]
        if let host, !hidePersonalInfo { chips.append(host) }
        self.chips = chips
        self.duration = IslandDuration.compact(now.timeIntervalSince(session.updatedAt))
    }
}

// MARK: - Attention detail

/// What the island can say about a blocked session using telemetry alone.
///
/// This is the fallback view. Telemetry events go through `AgentTaskEventNormalizer`, which keeps
/// only `session_id`, the hook name, `cwd` and `transcript_path` — enough to say *who* is blocked
/// and *where*, not enough to decide anything. So this offers the one action that always works:
/// jump to the terminal and answer there.
///
/// When the user opts into approvals, the blocking `PermissionRequest` hook supplies the tool and
/// its input, and `IslandApprovalRequest` takes over with real decision buttons.
struct IslandAttentionDetail: Equatable {
    var companionIndex = 0
    let provider: AgentTaskProvider
    let status: AgentTaskStatus
    let title: String
    /// Project path, suppressed when personal info is hidden.
    let project: String?
    let sessionID: String

    init(
        provider: AgentTaskProvider,
        status: AgentTaskStatus,
        title: String,
        project: String?,
        sessionID: String)
    {
        self.provider = provider
        self.status = status
        self.title = title
        self.project = project
        self.sessionID = sessionID
    }

    init?(attention: AgentTaskAttention?, hidePersonalInfo: Bool) {
        guard let attention, attention.status.requiresUserAction else { return nil }
        let event = attention.event
        self.provider = event.provider
        self.status = attention.status
        self.sessionID = event.sessionID
        let projectName = event.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        self.title = hidePersonalInfo
            ? attention.status.displayName
            : (event.taskTitle ?? projectName ?? IslandAgentColor.displayName(for: event.provider))
        self.project = hidePersonalInfo ? nil : event.projectPath
    }
}

// MARK: - Approval request

/// A permission request the island can actually decide, as opposed to merely report.
///
/// This is the payload-rich cousin of `IslandAttentionDetail`: it exists only when the blocking
/// `PermissionRequest` hook is installed, so it knows the tool and the command, and it carries the
/// action set this provider can honour.
struct IslandApprovalRequest: Equatable, Identifiable {
    var companionIndex = 0
    var sessionID: String?
    let id: String
    let provider: AgentTaskProvider
    let toolName: String
    let toolSummary: String?
    let projectPath: String?
    let actions: [AgentTaskApprovalAction]

    init(
        id: String,
        provider: AgentTaskProvider,
        toolName: String,
        toolSummary: String?,
        projectPath: String?,
        actions: [AgentTaskApprovalAction])
    {
        self.id = id
        self.provider = provider
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.projectPath = projectPath
        self.actions = actions
    }

    init(pending: AgentTaskPendingApproval, hidePersonalInfo: Bool) {
        self.id = pending.id
        self.sessionID = pending.sessionID
        self.provider = pending.provider
        self.toolName = pending.toolName
        self.toolSummary = hidePersonalInfo ? nil : pending.toolSummary
        self.projectPath = hidePersonalInfo ? nil : pending.projectPath
        self.actions = pending.actions
    }
}

// MARK: - Content

/// Everything the island renders, derived from real stores. Pure value type: no AppKit, no views,
/// no store access — so the whole mapping is unit-testable.
struct IslandContent: Equatable {
    let usage: IslandUsageStrip?
    let cards: [IslandSessionCard]
    let attention: IslandAttentionDetail?
    /// Present only when a blocking permission request is waiting on the user.
    let approval: IslandApprovalRequest?
    /// Short line shown next to the sprites in the compact strip.
    let compactLabel: String
    let sessionCount: Int
    /// Which agent the compact strip speaks for.
    let leadProvider: AgentTaskProvider
    let leadStatus: AgentTaskStatus
    /// Confirmation text for the `ack` strip.
    let acknowledgement: String?

    static let empty = IslandContent(
        usage: nil,
        cards: [],
        attention: nil,
        approval: nil,
        compactLabel: L("agent_task_none"),
        sessionCount: 0,
        leadProvider: .claude,
        leadStatus: .idle,
        acknowledgement: nil)

    init(
        usage: IslandUsageStrip?,
        cards: [IslandSessionCard],
        attention: IslandAttentionDetail?,
        approval: IslandApprovalRequest? = nil,
        compactLabel: String,
        sessionCount: Int,
        leadProvider: AgentTaskProvider,
        leadStatus: AgentTaskStatus,
        acknowledgement: String?)
    {
        self.usage = usage
        self.cards = cards
        self.attention = attention
        self.approval = approval
        self.compactLabel = compactLabel
        self.sessionCount = sessionCount
        self.leadProvider = leadProvider
        self.leadStatus = leadStatus
        self.acknowledgement = acknowledgement
    }

    /// Builds the island's content from a controller snapshot.
    ///
    /// `hosts` maps a session id to the terminal application hosting it, when the focus resolver
    /// could identify one; unresolved sessions simply lose the host chip.
    init(
        card: UsageMenuCardView.Model?,
        aggregates: [AgentTaskProvider: AgentTaskProviderAggregate],
        attention: AgentTaskAttention?,
        approval: AgentTaskPendingApproval? = nil,
        hosts: [String: String] = [:],
        hidePersonalInfo: Bool,
        acknowledgement: String? = nil,
        now: Date = Date())
    {
        let sessions = aggregates.values
            .flatMap(\.sessions)
            .filter { $0.status != .idle }
            // Most urgent first, then most recently active — the same ordering the compact strip
            // speaks for, so the lead sprite always matches the top card.
            .sorted {
                $0.status.priority == $1.status.priority
                    ? $0.updatedAt > $1.updatedAt
                    : $0.status.priority > $1.status.priority
            }

        self.usage = IslandUsageStrip(card: card)
        self.cards = sessions.map {
            IslandSessionCard(
                session: $0,
                host: hosts["\($0.provider.rawValue):\($0.sessionID)"],
                hidePersonalInfo: hidePersonalInfo,
                now: now)
        }
        self.attention = IslandAttentionDetail(attention: attention, hidePersonalInfo: hidePersonalInfo)
        self.approval = approval.map {
            IslandApprovalRequest(pending: $0, hidePersonalInfo: hidePersonalInfo)
        }
        self.sessionCount = sessions.count
        let lead = sessions.first
        self.leadProvider = lead?.provider ?? attention?.event.provider ?? .claude
        self.leadStatus = lead?.status ?? .idle
        self.compactLabel = self.leadStatus.displayName
        self.acknowledgement = acknowledgement
    }
}

extension IslandContent {
    @MainActor
    func assigningCompanions(using store: IslandCompanionAssignments = .shared) -> IslandContent {
        var keys = self.cards.map(\.id)
        if let attention { keys.append("\(attention.provider.rawValue):\(attention.sessionID)") }
        if let approval, let sessionID = approval.sessionID {
            keys.append("\(approval.provider.rawValue):\(sessionID)")
        }
        let assignments = store.assign(keys: keys)
        let cards = self.cards.map { card in
            var card = card
            card.companionIndex = assignments[card.id] ?? 0
            return card
        }
        var attention = self.attention
        if let detail = attention {
            attention?.companionIndex = assignments["\(detail.provider.rawValue):\(detail.sessionID)"] ?? 0
        }
        var approval = self.approval
        if let request = approval, let sessionID = request.sessionID {
            approval?.companionIndex = assignments["\(request.provider.rawValue):\(sessionID)"] ?? 0
        }
        return IslandContent(
            usage: self.usage,
            cards: cards,
            attention: attention,
            approval: approval,
            compactLabel: self.compactLabel,
            sessionCount: self.sessionCount,
            leadProvider: self.leadProvider,
            leadStatus: self.leadStatus,
            acknowledgement: self.acknowledgement)
    }

    /// Same content, carrying a confirmation line for the `ack` strip.
    func acknowledging(_ text: String) -> IslandContent {
        IslandContent(
            usage: self.usage,
            cards: self.cards,
            attention: self.attention,
            approval: self.approval,
            compactLabel: self.compactLabel,
            sessionCount: self.sessionCount,
            leadProvider: self.leadProvider,
            leadStatus: self.leadStatus,
            acknowledgement: text)
    }
}

// MARK: - Fixture bridge

extension IslandContent {
    /// Renders the frozen reference fixture through the exact same views production uses, so a
    /// regression screenshot exercises the real layout rather than a parallel mock tree.
    static func fixture(_ fixture: IslandShellFixture = .reference, scene: IslandScene) -> IslandContent {
        let sessions = [fixture.primary] + fixture.secondary
        let cards = sessions.enumerated().map { index, session in
            IslandSessionCard(
                id: session.id,
                provider: session.agent == "Codex" ? .codex : .claude,
                status: scene == .done
                    ? .completed
                    : (scene == .approval && index == 0 ? .needsApproval : session.tone.status),
                title: session.title,
                subtitle: session.status ?? session.prompt,
                chips: [session.agent, session.host],
                duration: session.duration,
                companionIndex: index)
        }
        return IslandContent(
            usage: IslandUsageStrip(
                providerName: "Claude",
                // One window, matching what the real card path produces.
                metrics: [
                    IslandUsageMetric(
                        id: "5h",
                        window: "5h",
                        percentText: "11%",
                        resetText: "4h1m",
                        usedFraction: 0.11),
                ]),
            cards: cards,
            attention: scene == .approval || scene == .ask
                ? IslandAttentionDetail(
                    provider: scene == .ask ? .codex : .claude,
                    status: .needsApproval,
                    title: scene == .ask ? "backend server" : "fix auth bug",
                    project: "/Users/dev/vibe-island",
                    sessionID: "fixture")
                : nil,
            approval: scene == .approval
                ? IslandApprovalRequest(
                    id: "fixture",
                    provider: .claude,
                    toolName: "Bash",
                    toolSummary: "rm -rf node_modules && npm install",
                    projectPath: "/Users/dev/vibe-island",
                    actions: AgentTaskApprovalCapability.actions(
                        provider: .claude,
                        hasPermissionSuggestions: true))
                : nil,
            compactLabel: fixture.compactTitle,
            sessionCount: fixture.sessionCount,
            leadProvider: .claude,
            leadStatus: cards.first?.status ?? .running,
            acknowledgement: scene == .ack ? "Allow All — Write" : nil)
    }
}

extension IslandShellTone {
    var status: AgentTaskStatus {
        switch self {
        case .idle: .idle
        case .working: .running
        }
    }
}
