import CodexBarCore
import Foundation
import Observation

/// One permission request waiting on the user.
struct AgentTaskPendingApproval: Identifiable, Equatable {
    let id: String
    let provider: AgentTaskProvider
    let toolName: String
    let toolSummary: String?
    let projectPath: String?
    let sessionID: String
    let actions: [AgentTaskApprovalAction]
    let receivedAt: Date

    fileprivate let permissionSuggestionsJSON: Data?

    init(request: AgentTaskApprovalRequest, payload: AgentTaskApprovalPayload, now: Date) {
        self.id = request.requestID
        self.provider = request.provider
        self.toolName = payload.toolName
        self.toolSummary = payload.toolSummary
        self.projectPath = payload.projectPath
        self.sessionID = payload.sessionID
        self.actions = AgentTaskApprovalCapability.actions(
            provider: request.provider,
            hasPermissionSuggestions: payload.hasPermissionSuggestions)
        self.receivedAt = now
        self.permissionSuggestionsJSON = payload.permissionSuggestionsJSON
    }
}

/// Owns the lifecycle of pending permission requests: identity, idempotency, and the deadline
/// after which we stop holding the agent hostage.
///
/// Every path that does not produce an explicit decision returns `nil`, which the helper turns
/// into silence, which both agents read as "no decision" and fall back to their own approval flow.
/// That is the fail-open behaviour the whole feature rests on.
@MainActor
@Observable
final class AgentTaskApprovalStore {
    private(set) var pending: [AgentTaskPendingApproval] = []

    /// Master switch. Off means we never answer, so a half-configured install behaves exactly like
    /// the app did before approvals existed.
    var isEnabled = false

    /// Message sent back to the agent when the user denies from the island.
    var denyMessage: String = "Denied from CodexBar"

    /// Fired whenever `pending` changes, so the notch surfaces can redraw without polling.
    @ObservationIgnored
    var onChange: (@MainActor () -> Void)?

    @ObservationIgnored
    private var waiters: [String: [CheckedContinuation<AgentTaskApprovalDecision?, Never>]] = [:]
    @ObservationIgnored
    private var timeoutTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var recentDecisions: [String: RecentDecision] = [:]

    private struct RecentDecision {
        let decision: AgentTaskApprovalDecision?
    }

    /// How long a decision keeps answering duplicates of the same request.
    ///
    /// Request identity is a digest of the hook payload, so "the same request" and "the same
    /// command run twice" are indistinguishable. A short window absorbs a hook that fires twice
    /// for one prompt without letting a command the user re-runs a minute later silently inherit
    /// an earlier allow.
    static let duplicateWindow: Double = 5

    var current: AgentTaskPendingApproval? {
        self.pending.first
    }

    /// Called by the socket server. Suspends until the user decides or the deadline passes.
    func handle(
        _ request: AgentTaskApprovalRequest,
        now: Date = Date(),
        timeout: Double = AgentTaskApprovalTimeouts.decisionSeconds)
        async -> AgentTaskApprovalDecision?
    {
        guard self.isEnabled,
              let payload = AgentTaskApprovalPayload(hookPayload: request.payload)
        else { return nil }

        // Already answered moments ago: hand back the same decision rather than asking twice.
        if let recent = self.recentDecisions[request.requestID] {
            return recent.decision
        }

        // A retried or duplicated hook invocation carries the same identity. Attach it to the card
        // already on screen instead of stacking a second one; both callers get the same answer.
        if !self.pending.contains(where: { $0.id == request.requestID }) {
            self.pending.append(AgentTaskPendingApproval(request: request, payload: payload, now: now))
            self.scheduleTimeout(id: request.requestID, seconds: timeout)
            self.onChange?()
        }

        return await withCheckedContinuation { continuation in
            self.waiters[request.requestID, default: []].append(continuation)
        }
    }

    /// The user pressed a button on the island.
    func resolve(id: String, action: AgentTaskApprovalAction) {
        guard let request = self.pending.first(where: { $0.id == id }) else { return }
        let decision = AgentTaskApprovalCapability.decision(
            for: action,
            provider: request.provider,
            permissionSuggestionsJSON: request.permissionSuggestionsJSON,
            denyMessage: self.denyMessage)
        self.finish(id: id, decision: decision)
    }

    /// Dismissed without deciding: the agent falls back to asking in the terminal.
    func dismiss(id: String) {
        self.finish(id: id, decision: nil)
    }

    /// Drops every pending request, answering each with "no decision". Used when approvals are
    /// switched off or the app is shutting down, so no agent is left blocked on a dead island.
    func drain() {
        for request in self.pending {
            self.finish(id: request.id, decision: nil)
        }
    }

    private func scheduleTimeout(id: String, seconds: Double) {
        self.timeoutTasks[id]?.cancel()
        self.timeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.finish(id: id, decision: nil)
        }
    }

    private func finish(id: String, decision: AgentTaskApprovalDecision?) {
        self.timeoutTasks[id]?.cancel()
        self.timeoutTasks[id] = nil
        self.recentDecisions[id] = RecentDecision(decision: decision)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.duplicateWindow))
            self?.recentDecisions[id] = nil
        }
        self.pending.removeAll { $0.id == id }
        let waiters = self.waiters.removeValue(forKey: id) ?? []
        for waiter in waiters {
            waiter.resume(returning: decision)
        }
        self.onChange?()
    }
}
