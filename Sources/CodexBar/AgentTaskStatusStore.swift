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
}

@MainActor
@Observable
final class AgentTaskStatusStore {
    private var reducer = AgentTaskReducer()
    private var seenEventIDs = Set<String>()
    private var harnessDisconnectedSessions = Set<String>()
    private var attentionQueue: [AgentTaskAttention] = []
    @ObservationIgnored private let attentionDismissDelay: (AgentTaskAttention) -> TimeInterval?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var completionMonitorTask: Task<Void, Never>?
    @ObservationIgnored private var attentionDismissTasks: [String: Task<Void, Never>] = [:]

    private(set) var currentAttention: AgentTaskAttention?
    private(set) var lastEventAtByProvider: [AgentTaskProvider: Date] = [:]
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    init(attentionDismissDelay: ((AgentTaskStatus) -> TimeInterval?)? = nil) {
        self.attentionDismissDelay = { attention in
            if let attentionDismissDelay { return attentionDismissDelay(attention.status) }
            return NotchAttentionPolicy.dismissAfter(status: attention.status, provider: attention.event.provider)
        }
    }

    var pendingAttentionCount: Int {
        (self.currentAttention == nil ? 0 : 1) + self.attentionQueue.count
    }

    func receive(_ event: AgentTaskEvent) {
        guard self.seenEventIDs.insert(event.id).inserted else { return }
        guard self.reducer.apply(event) else { return }
        self.removeAttention { $0.event.provider == event.provider && $0.event.sessionID == event.sessionID }
        self.lastEventAtByProvider[event.provider] = event.occurredAt
        self.startCompletionMonitoringIfNeeded()
        if let attention = AgentTaskAttention(event: event) {
            self.enqueue(attention)
            self.scheduleDismissal(for: attention)
        }
        self.onChange?()
    }

    func startRunningTaskRecovery(
        read: @escaping @Sendable () -> [AgentTaskEvent] = { CodexThreadMetadataReader().runningTaskEvents() },
        readHarness: @escaping @Sendable () -> HarnessTaskSnapshot? = { nil })
    {
        guard self.recoveryTask == nil else { return }
        self.recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                let events = await Task.detached(priority: .utility, operation: read).value
                guard !Task.isCancelled else { return }
                for event in events {
                    self?.receive(event)
                }
                let harness = await Task.detached(priority: .utility, operation: readHarness).value
                guard !Task.isCancelled else { return }
                self?.synchronizeHarness(snapshot: harness)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func synchronizeHarness(snapshot: HarnessTaskSnapshot?, now: Date = Date()) {
        let events = snapshot?.taskEvents(now: now) ?? []
        let disconnected = self.harnessDisconnectedSessions
        for event in events where disconnected.contains(event.sessionID) {
            self.seenEventIDs.remove(event.id)
        }
        for event in events {
            self.receive(event)
        }
        let liveIDs = Set(events.map(\.sessionID))
        self.harnessDisconnectedSessions.subtract(liveIDs)
        for session in self.reducer.aggregate(for: .deepseekHarness).sessions {
            guard session.status == .running || session.status == .needsApproval,
                  snapshot == nil || !liveIDs.contains(session.sessionID)
            else { continue }
            self.harnessDisconnectedSessions.insert(session.sessionID)
            self.receive(AgentTaskEvent(
                id: "harness-disconnected:\(UUID().uuidString)",
                provider: .deepseekHarness,
                sessionID: session.sessionID,
                turnID: session.turnID,
                kind: .connectionLost,
                occurredAt: now,
                projectPath: session.projectPath,
                transcriptPath: nil,
                taskTitle: session.taskTitle,
                source: .harnessBridge))
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
                          current.containsCurrentTurn(at: event.occurredAt, turnID: event.turnID)
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
        self.acknowledgeTerminal(for: dismissed)
        self.removeAttention { $0.id == dismissed.id }
        self.onChange?()
    }

    private func scheduleDismissal(for attention: AgentTaskAttention) {
        guard let delay = self.attentionDismissDelay(attention) else { return }
        // A task's completion dwell is independent of which attention is currently presented.
        self.attentionDismissTasks[attention.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.attentionDismissTasks.removeValue(forKey: attention.id)
            self.acknowledgeTerminal(for: attention)
            self.removeAttention { $0.id == attention.id }
            self.onChange?()
        }
    }

    private func acknowledgeTerminal(for attention: AgentTaskAttention) {
        let event = attention.event
        guard let state = self.reducer.session(provider: event.provider, sessionID: event.sessionID),
              state.status == attention.status, state.updatedAt == event.occurredAt,
              event.turnID == nil || state.turnID == event.turnID
        else { return }
        self.reducer.acknowledgeTerminal(provider: event.provider, sessionID: event.sessionID)
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

    private func removeAttention(where matches: (AgentTaskAttention) -> Bool) {
        if let attention = self.currentAttention, matches(attention) {
            self.attentionDismissTasks.removeValue(forKey: attention.id)?.cancel()
            self.currentAttention = nil
        }
        self.attentionQueue.removeAll { attention in
            guard matches(attention) else { return false }
            self.attentionDismissTasks.removeValue(forKey: attention.id)?.cancel()
            return true
        }
        if self.currentAttention == nil { self.promoteNextAttention() }
    }
}
