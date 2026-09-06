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
    private var terminalSessions = Set<SessionKey>()
    private var terminalTurns = Set<TurnKey>()

    public init() {}

    public mutating func apply(_ event: AgentTaskEvent) {
        let sessionKey = SessionKey(provider: event.provider, sessionID: event.sessionID)
        if event.kind == .sessionEnded {
            self.sessions.removeValue(forKey: sessionKey)
            self.terminalSessions.remove(sessionKey)
            self.terminalTurns = self.terminalTurns.filter { $0.session != sessionKey }
            return
        }

        if let existing = self.sessions[sessionKey], event.occurredAt < existing.updatedAt {
            return
        }

        // Async hooks can arrive after Stop, and Codex hooks do not always include a turn ID.
        if event.kind == .toolCompleted,
           let existing = self.sessions[sessionKey],
           self.terminalSessions.contains(sessionKey),
           event.turnID == nil || event.turnID == existing.turnID
        {
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

        switch event.kind {
        case .turnCompleted, .turnFailed, .turnInterrupted:
            self.terminalSessions.insert(sessionKey)
        case .turnStarted, .sessionStarted:
            self.terminalSessions.remove(sessionKey)
        default:
            break
        }

        let previous = self.sessions[sessionKey]
        let startsTurn = event.kind == .turnStarted || event.kind == .sessionStarted
        self.sessions[sessionKey] = AgentTaskSessionState(
            provider: event.provider,
            sessionID: event.sessionID,
            turnID: event.turnID ?? (startsTurn ? nil : previous?.turnID),
            status: status,
            updatedAt: event.occurredAt,
            projectPath: event.projectPath ?? previous?.projectPath,
            transcriptPath: event.transcriptPath ?? previous?.transcriptPath,
            taskTitle: event.taskTitle ?? (startsTurn ? nil : previous?.taskTitle))
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
