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

    private(set) var currentAttention: AgentTaskAttention?
    private(set) var lastEventAtByProvider: [AgentTaskProvider: Date] = [:]
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    var pendingAttentionCount: Int {
        (self.currentAttention == nil ? 0 : 1) + self.attentionQueue.count
    }

    func receive(_ event: AgentTaskEvent) {
        guard self.seenEventIDs.insert(event.id).inserted else { return }
        self.clearResolvedApproval(for: event)
        self.reducer.apply(event)
        self.lastEventAtByProvider[event.provider] = event.occurredAt
        if let attention = AgentTaskAttention(event: event) {
            self.enqueue(attention)
        }
        self.onChange?()
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
        self.onChange?()
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
