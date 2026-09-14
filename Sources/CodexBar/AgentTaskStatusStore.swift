import CodexBarCore
import Foundation
import Observation

struct AgentTaskAttention: Equatable, Identifiable, Sendable {
    let id: String
    let event: AgentTaskEvent
    let status: AgentTaskStatus

    var priority: Int {
        self.status.priority
    }

    init?(event: AgentTaskEvent) {
        let status: AgentTaskStatus
        switch event.kind {
        case .approvalRequested: status = .needsApproval
        case .turnCompleted: status = .completed
        case .turnFailed: status = .failed
        case .turnInterrupted: status = .interrupted
        case .connectionLost: status = .disconnected
        case .sessionStarted, .turnStarted, .toolCompleted, .sessionEnded:
            return nil
        }
        self.id = event.id
        self.event = event
        self.status = status
    }

    func matches(_ event: AgentTaskEvent) -> Bool {
        guard self.event.provider == event.provider,
              self.event.sessionID == event.sessionID
        else { return false }
        guard let attentionTurnID = self.event.turnID, let eventTurnID = event.turnID else {
            return true
        }
        return attentionTurnID == eventTurnID
    }
}

@MainActor
@Observable
final class AgentTaskStatusStore {
    private var reducer = AgentTaskReducer()
    private var seenEventIDs = Set<String>()
    private var attentionQueue: [AgentTaskAttention] = []
    @ObservationIgnored private let attentionDismissDelay: (AgentTaskStatus) -> TimeInterval?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var completionMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var attentionDismissTask: Task<Void, Never>?

    private(set) var currentAttention: AgentTaskAttention?
    private(set) var lastEventAtByProvider: [AgentTaskProvider: Date] = [:]
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(attentionDismissDelay: @escaping (AgentTaskStatus) -> TimeInterval? = NotchAttentionPolicy.dismissAfter) {
        self.attentionDismissDelay = attentionDismissDelay
    }

    var pendingAttentionCount: Int {
        (self.currentAttention == nil ? 0 : 1) + self.attentionQueue.count
    }

    func receive(_ event: AgentTaskEvent) {
        guard self.seenEventIDs.insert(event.id).inserted else { return }
        self.clearResolvedApproval(for: event)
        self.reducer.apply(event)
        self.lastEventAtByProvider[event.provider] = event.occurredAt
        self.startCompletionMonitoringIfNeeded()
        if let attention = AgentTaskAttention(event: event) {
            self.enqueue(attention)
        }
        self.scheduleCurrentAttentionDismissal()
        self.onChange?()
    }

    func startRunningTaskRecovery(
        read: @escaping @Sendable () -> [AgentTaskEvent] = { CodexThreadMetadataReader().runningTaskEvents() })
    {
        guard self.recoveryTask == nil else { return }
        self.recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                let events = await Task.detached(priority: .utility, operation: read).value
                guard !Task.isCancelled else { return }
                for event in events {
                    self?.receive(event)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopCompletionMonitoring() {
        self.recoveryTask?.cancel()
        self.recoveryTask = nil
        self.completionMonitorTask?.cancel()
        self.completionMonitorTask = nil
    }

    private var codexSessionsAwaitingCompletion: [AgentTaskSessionState] {
        self.reducer.aggregate(for: .codex).sessions.filter {
            ($0.status == .running || $0.status == .needsApproval) && $0.transcriptPath != nil
        }
    }

    private func startCompletionMonitoringIfNeeded() {
        guard self.completionMonitorTask == nil, !self.codexSessionsAwaitingCompletion.isEmpty else { return }
        self.completionMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let sessions = self?.codexSessionsAwaitingCompletion else { return }
                if sessions.isEmpty { break }
                let events = await Task.detached(priority: .utility) {
                    sessions.compactMap { CodexTaskCompletionReader.read(for: $0) }
                }.value
                guard !Task.isCancelled else { return }
                for event in events {
                    guard let current = self?.reducer.session(provider: .codex, sessionID: event.sessionID),
                          current.status == .running || current.status == .needsApproval,
                          event.occurredAt >= current.updatedAt
                    else { continue }
                    self?.receive(event)
                }
            }
            self?.completionMonitorTask = nil
        }
    }

    func aggregate(for provider: AgentTaskProvider) -> AgentTaskProviderAggregate {
        self.reducer.aggregate(for: provider)
    }

    func dismissCurrentAttention() {
        guard let dismissed = self.currentAttention else { return }
        if dismissed.status != .needsApproval {
            self.reducer.acknowledgeTerminal(
                provider: dismissed.event.provider,
                sessionID: dismissed.event.sessionID)
        }
        self.currentAttention = nil
        self.promoteNextAttention()
        self.scheduleCurrentAttentionDismissal()
        self.onChange?()
    }

    private func scheduleCurrentAttentionDismissal() {
        self.attentionDismissTask?.cancel()
        guard let attention = self.currentAttention,
              let delay = self.attentionDismissDelay(attention.status)
        else { return }
        self.attentionDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self?.currentAttention?.id == attention.id else { return }
            self?.dismissCurrentAttention()
        }
    }

    private func enqueue(_ attention: AgentTaskAttention) {
        guard let current = self.currentAttention else {
            self.currentAttention = attention
            return
        }
        if attention.priority > current.priority {
            self.attentionQueue.insert(current, at: 0)
            self.currentAttention = attention
            return
        }
        let insertionIndex = self.attentionQueue.firstIndex { $0.priority < attention.priority }
            ?? self.attentionQueue.endIndex
        self.attentionQueue.insert(attention, at: insertionIndex)
    }

    private func promoteNextAttention() {
        self.currentAttention = self.attentionQueue.isEmpty ? nil : self.attentionQueue.removeFirst()
    }

    private func clearResolvedApproval(for event: AgentTaskEvent) {
        switch event.kind {
        case .toolCompleted, .turnCompleted, .turnFailed, .turnInterrupted, .sessionEnded, .connectionLost:
            break
        case .sessionStarted, .turnStarted, .approvalRequested:
            return
        }
        if self.currentAttention?.status == .needsApproval,
           self.currentAttention?.matches(event) == true
        {
            self.currentAttention = nil
            self.promoteNextAttention()
        }
        self.attentionQueue.removeAll { $0.status == .needsApproval && $0.matches(event) }
    }
}
