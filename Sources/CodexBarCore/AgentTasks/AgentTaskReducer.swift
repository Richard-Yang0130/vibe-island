import Foundation

public struct AgentTaskReducer: Sendable {
    private struct SessionKey: Hashable, Sendable {
        let provider: AgentTaskProvider
        let sessionID: String
    }

    private struct TurnKey: Hashable, Sendable {
        let session: SessionKey
        let turnID: String
    }

    private var sessions: [SessionKey: AgentTaskSessionState] = [:]
    private var terminalTurns = Set<TurnKey>()

    public init() {}

    public mutating func apply(_ event: AgentTaskEvent) {
        let sessionKey = SessionKey(provider: event.provider, sessionID: event.sessionID)
        if event.kind == .sessionEnded {
            self.sessions.removeValue(forKey: sessionKey)
            self.terminalTurns = self.terminalTurns.filter { $0.session != sessionKey }
            return
        }

        if let existing = self.sessions[sessionKey], event.occurredAt < existing.updatedAt {
            return
        }

        let turnKey = event.turnID.map { TurnKey(session: sessionKey, turnID: $0) }
        if let turnKey,
           self.terminalTurns.contains(turnKey),
           event.kind == .turnStarted || event.kind == .toolCompleted || event.kind == .approvalRequested
        {
            return
        }

        let status: AgentTaskStatus = switch event.kind {
        case .sessionStarted: .idle
        case .turnStarted, .toolCompleted: .running
        case .approvalRequested: .needsApproval
        case .turnCompleted: .completed
        case .turnFailed: .failed
        case .turnInterrupted: .interrupted
        case .connectionLost: .disconnected
        case .sessionEnded: .idle
        }

        if let turnKey,
           event.kind == .turnCompleted || event.kind == .turnFailed || event.kind == .turnInterrupted
        {
            self.terminalTurns.insert(turnKey)
        }

        self.sessions[sessionKey] = AgentTaskSessionState(
            provider: event.provider,
            sessionID: event.sessionID,
            turnID: event.turnID,
            status: status,
            updatedAt: event.occurredAt,
            projectPath: event.projectPath,
            transcriptPath: event.transcriptPath,
            taskTitle: event.taskTitle)
    }

    public func session(provider: AgentTaskProvider, sessionID: String) -> AgentTaskSessionState? {
        self.sessions[SessionKey(provider: provider, sessionID: sessionID)]
    }

    public mutating func acknowledgeTerminal(provider: AgentTaskProvider, sessionID: String) {
        let key = SessionKey(provider: provider, sessionID: sessionID)
        guard var state = self.sessions[key] else { return }
        switch state.status {
        case .completed, .failed, .interrupted, .disconnected:
            state.status = .idle
            self.sessions[key] = state
        case .idle, .running, .needsApproval:
            break
        }
    }

    public func aggregate(for provider: AgentTaskProvider) -> AgentTaskProviderAggregate {
        let matches = self.sessions.values
            .filter { $0.provider == provider }
            .sorted { lhs, rhs in
                if lhs.status.priority != rhs.status.priority {
                    return lhs.status.priority > rhs.status.priority
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        return AgentTaskProviderAggregate(
            provider: provider,
            status: matches.first?.status ?? .idle,
            sessions: matches)
    }
}
