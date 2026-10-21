import Foundation

public enum AgentTaskProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case deepseekHarness
}

public enum AgentTaskEventSource: String, Codable, Sendable {
    case hook
    case codexAppServer
    case harnessBridge
}

public enum AgentTaskEventKind: String, Codable, Sendable {
    case sessionStarted
    case turnStarted
    case toolCompleted
    case approvalRequested
    case turnCompleted
    case turnFailed
    case turnInterrupted
    case sessionEnded
    case connectionLost
}

public enum AgentTaskStatus: String, Codable, Sendable {
    case idle
    case running
    case needsApproval
    case completed
    case failed
    case interrupted
    case disconnected

    public var priority: Int {
        switch self {
        case .needsApproval: 7
        case .failed: 6
        case .running: 5
        case .interrupted: 4
        case .completed: 3
        case .disconnected: 2
        case .idle: 1
        }
    }
}

public struct AgentTaskEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: AgentTaskProvider
    public let sessionID: String
    public let turnID: String?
    public let kind: AgentTaskEventKind
    public let occurredAt: Date
    public let projectPath: String?
    public let transcriptPath: String?
    public let taskTitle: String?
    public let source: AgentTaskEventSource
    public let sequence: Int?

    public init(
        id: String,
        provider: AgentTaskProvider,
        sessionID: String,
        turnID: String?,
        kind: AgentTaskEventKind,
        occurredAt: Date,
        projectPath: String?,
        transcriptPath: String?,
        taskTitle: String?,
        source: AgentTaskEventSource,
        sequence: Int? = nil)
    {
        self.id = id
        self.provider = provider
        self.sessionID = sessionID
        self.turnID = turnID
        self.kind = kind
        self.occurredAt = occurredAt
        self.projectPath = projectPath
        self.transcriptPath = transcriptPath
        self.taskTitle = taskTitle
        self.source = source
        self.sequence = sequence
    }
}

public struct AgentTaskSessionState: Equatable, Sendable {
    public let provider: AgentTaskProvider
    public let sessionID: String
    public var turnID: String?
    public var status: AgentTaskStatus
    public var updatedAt: Date
    public var turnStartedAt: Date
    public var projectPath: String?
    public var transcriptPath: String?
    public var taskTitle: String?

    public init(
        provider: AgentTaskProvider,
        sessionID: String,
        turnID: String?,
        status: AgentTaskStatus,
        updatedAt: Date,
        projectPath: String?,
        transcriptPath: String?,
        taskTitle: String?,
        turnStartedAt: Date? = nil)
    {
        self.provider = provider
        self.sessionID = sessionID
        self.turnID = turnID
        self.status = status
        self.updatedAt = updatedAt
        self.turnStartedAt = turnStartedAt ?? updatedAt
        self.projectPath = projectPath
        self.transcriptPath = transcriptPath
        self.taskTitle = taskTitle
    }

    public func containsCurrentTurn(at date: Date, turnID: String?) -> Bool {
        date >= self.turnStartedAt && (self.turnID == nil || self.turnID == turnID)
    }
}

public struct AgentTaskProviderAggregate: Equatable, Sendable {
    public let provider: AgentTaskProvider
    public let status: AgentTaskStatus
    public let sessions: [AgentTaskSessionState]

    public init(
        provider: AgentTaskProvider,
        status: AgentTaskStatus,
        sessions: [AgentTaskSessionState])
    {
        self.provider = provider
        self.status = status
        self.sessions = sessions
    }
}
