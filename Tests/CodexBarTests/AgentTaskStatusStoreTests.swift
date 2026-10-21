import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AgentTaskStatusStoreTests {
    @Test
    func `identical Claude stop payloads complete separate turns`() throws {
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in nil })
        let payload = Data(#"{"session_id":"claude-session","hook_event_name":"Stop"}"#.utf8)
        store.receive(.fixture(kind: .turnStarted, provider: .claude, sessionID: "claude-session", turnID: nil))
        try store.receive(#require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .claude, payload: payload),
            receivedAt: Date(timeIntervalSince1970: 101))))
        #expect(store.aggregate(for: .claude).status == .completed)

        store.receive(.fixture(
            kind: .turnStarted,
            provider: .claude,
            sessionID: "claude-session",
            turnID: nil,
            at: Date(timeIntervalSince1970: 102)))
        try store.receive(#require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .claude, payload: payload),
            receivedAt: Date(timeIntervalSince1970: 103))))

        #expect(store.aggregate(for: .claude).status == .completed)
    }

    @Test
    func `same turn rollout completion overrides a later tool receipt`() {
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in nil })
        store.receive(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1"))
        store.receive(.fixture(
            kind: .toolCompleted,
            sessionID: "a",
            turnID: "t1",
            at: Date(timeIntervalSince1970: 102)))
        store.receive(AgentTaskEvent(
            id: "codex:rollout:a:t1:task_complete",
            provider: .codex,
            sessionID: "a",
            turnID: "t1",
            kind: .turnCompleted,
            occurredAt: Date(timeIntervalSince1970: 101),
            projectPath: nil,
            transcriptPath: nil,
            taskTitle: nil,
            source: .codexAppServer))

        #expect(store.aggregate(for: .codex).status == .completed)
        #expect(store.currentAttention?.status == .completed)
    }

    @Test
    func `recovery restores an existing running task without a hook`() async throws {
        let store = AgentTaskStatusStore()
        store.startRunningTaskRecovery { [.fixture(kind: .turnStarted, sessionID: "existing", turnID: "turn")] }
        defer { store.stopCompletionMonitoring() }
        for _ in 0..<50 {
            if !store.aggregate(for: .codex).sessions.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.aggregate(for: .codex).sessions.first?.sessionID == "existing")
        #expect(store.aggregate(for: .codex).status == .running)
        #expect(store.currentAttention == nil)
    }

    @Test
    func `rollout completion repairs a missing stop hook and ignores an older turn`() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = AgentTaskSessionState(
            provider: .codex,
            sessionID: "a",
            turnID: nil,
            status: .running,
            updatedAt: Date(timeIntervalSince1970: 100),
            projectPath: "/repo",
            transcriptPath: url.path,
            taskTitle: nil)
        let complete = #"{"timestamp":"1970-01-01T00:01:41.000Z","type":"event_msg","#
            + #""payload":{"type":"task_complete","turn_id":"t1"}}"#
        try (complete + "\n").write(to: url, atomically: true, encoding: .utf8)
        let event = try #require(CodexTaskCompletionReader.read(for: state))
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in nil })
        store.receive(.fixture(
            kind: .turnStarted,
            sessionID: "a",
            turnID: nil,
            transcriptPath: url.path))
        #expect(event.kind == .turnCompleted)
        for _ in 0..<50 {
            if store.aggregate(for: .codex).status == .completed { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.aggregate(for: .codex).status == .completed)
        store.stopCompletionMonitoring()

        let started = #"{"timestamp":"1970-01-01T00:01:42.000Z","type":"event_msg","#
            + #""payload":{"type":"task_started","turn_id":"t2"}}"#
        try (complete + "\n" + started + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(CodexTaskCompletionReader.read(for: state) == nil)
        let interrupted = #"{"timestamp":"1970-01-01T00:01:43.000Z","type":"event_msg","#
            + #""payload":{"type":"turn_aborted","turn_id":"t2"}}"#
        try (interrupted + "\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(CodexTaskCompletionReader.read(for: state)?.kind == .turnInterrupted)
        var newerState = state
        newerState.turnStartedAt = Date(timeIntervalSince1970: 104)
        #expect(CodexTaskCompletionReader.read(for: newerState) == nil)
    }

    @Test
    func `completed attention dismisses itself and leaves no active session`() async throws {
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in 0.01 })
        store.receive(.fixture(kind: .turnCompleted, sessionID: "a", turnID: "t1"))

        for _ in 0..<50 {
            if store.currentAttention == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.currentAttention == nil)
        #expect(store.aggregate(for: .codex).status == .idle)
    }

    @Test
    func `unrelated task updates do not postpone completed task dismissal`() async throws {
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in 0.4 })
        store.receive(.fixture(kind: .turnCompleted, sessionID: "finished", turnID: "t1"))
        try await Task.sleep(for: .milliseconds(250))
        store.receive(.fixture(kind: .turnStarted, sessionID: "other", turnID: "t2"))
        try await Task.sleep(for: .milliseconds(250))

        #expect(store.currentAttention == nil)
        #expect(store.aggregate(for: .codex).sessions.first(where: { $0.sessionID == "finished" })?.status == .idle)
    }

    @Test
    func `completed tasks expire behind a persistent failure or approval`() async throws {
        for kind in [AgentTaskEventKind.turnFailed, .approvalRequested] {
            let store = AgentTaskStatusStore(attentionDismissDelay: { $0 == .completed ? 0.01 : nil })
            store.receive(.fixture(kind: kind, sessionID: "blocked", turnID: "t1"))
            store.receive(.fixture(kind: .turnCompleted, sessionID: "finished", turnID: "t2"))

            for _ in 0..<50 {
                if store.aggregate(for: .codex).sessions.first(where: { $0.sessionID == "finished" })?.status == .idle {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }

            #expect(store.aggregate(for: .codex).sessions.first(where: { $0.sessionID == "finished" })?.status == .idle)
            #expect(store.currentAttention?.event.sessionID == "blocked")
            #expect(store.pendingAttentionCount == 1)
            store.dismissCurrentAttention()
        }
    }

    @Test
    func `completed tasks share the same dwell period instead of waiting in sequence`() async throws {
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in 0.1 })
        for index in 0..<6 {
            store.receive(.fixture(kind: .turnCompleted, sessionID: "finished-\(index)", turnID: "t1"))
        }
        try await Task.sleep(for: .milliseconds(350))

        #expect(store.pendingAttentionCount == 0)
        #expect(store.aggregate(for: .codex).sessions.allSatisfy { $0.status == .idle })
        while store.currentAttention != nil {
            store.dismissCurrentAttention()
        }
    }

    @Test
    func `a resumed task clears its previous failure attention`() {
        let store = AgentTaskStatusStore()
        store.receive(.fixture(kind: .turnFailed, sessionID: "a", turnID: "old"))
        store.receive(.fixture(
            kind: .turnStarted,
            sessionID: "a",
            turnID: "new",
            at: Date(timeIntervalSince1970: 101)))

        #expect(store.currentAttention == nil)
        #expect(store.pendingAttentionCount == 0)
        #expect(store.aggregate(for: .codex).status == .running)
    }

    @Test
    func `a new turn clears an old approval while preserving another session approval`() {
        let store = AgentTaskStatusStore()
        store.receive(.fixture(kind: .approvalRequested, sessionID: "a", turnID: "old"))
        store.receive(.fixture(kind: .approvalRequested, sessionID: "b", turnID: "other"))
        store.receive(.fixture(
            kind: .turnStarted,
            sessionID: "a",
            turnID: "new",
            at: Date(timeIntervalSince1970: 101)))

        #expect(store.currentAttention?.event.sessionID == "b")
        #expect(store.pendingAttentionCount == 1)
        #expect(store.aggregate(for: .codex).sessions.first(where: { $0.sessionID == "a" })?.status == .running)
    }

    @Test
    func `a rejected event cannot create attention for an older turn`() {
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in nil })
        store.receive(.fixture(kind: .turnStarted, sessionID: "a", turnID: "new"))
        store.receive(.fixture(
            kind: .approvalRequested,
            sessionID: "a",
            turnID: "old",
            at: Date(timeIntervalSince1970: 99)))

        #expect(store.currentAttention == nil)
        #expect(store.aggregate(for: .codex).status == .running)
    }

    @Test
    func `late events from another turn cannot clear the current approval`() {
        for kind in [AgentTaskEventKind.toolCompleted, .turnCompleted, .approvalRequested] {
            let store = AgentTaskStatusStore(attentionDismissDelay: { _ in nil })
            store.receive(.fixture(kind: .approvalRequested, sessionID: "a", turnID: "current"))
            store.receive(.fixture(
                kind: kind,
                sessionID: "a",
                turnID: "old",
                at: Date(timeIntervalSince1970: 101)))

            #expect(store.currentAttention?.event.turnID == "current")
            #expect(store.pendingAttentionCount == 1)
            #expect(store.aggregate(for: .codex).status == .needsApproval)
            #expect(store.aggregate(for: .codex).sessions.first?.turnID == "current")
        }
    }

    @Test
    func `tool hooks with a missing turn id still resolve the matching approval`() {
        let turnIDs: [(String?, String?)] = [("current", nil), (nil, "current")]
        for (approvalTurnID, toolTurnID) in turnIDs {
            let store = AgentTaskStatusStore()
            store.receive(.fixture(kind: .approvalRequested, sessionID: "a", turnID: approvalTurnID))
            store.receive(.fixture(
                kind: .toolCompleted,
                sessionID: "a",
                turnID: toolTurnID,
                at: Date(timeIntervalSince1970: 101)))

            #expect(store.currentAttention == nil)
            #expect(store.aggregate(for: .codex).status == .running)
            #expect(store.aggregate(for: .codex).sessions.first?.turnID == "current")
        }
    }

    @Test
    func `an old completion deadline cannot clear a newer failure`() async throws {
        let store = AgentTaskStatusStore(attentionDismissDelay: { $0 == .completed ? 0.01 : nil })
        store.receive(.fixture(kind: .turnCompleted, sessionID: "a", turnID: "old"))
        store.receive(.fixture(
            kind: .turnStarted,
            sessionID: "a",
            turnID: "new",
            at: Date(timeIntervalSince1970: 101)))
        store.receive(.fixture(
            kind: .turnFailed,
            sessionID: "a",
            turnID: "new",
            at: Date(timeIntervalSince1970: 102)))
        try await Task.sleep(for: .milliseconds(100))

        #expect(store.aggregate(for: .codex).status == .failed)
        #expect(store.currentAttention?.event.turnID == "new")
        #expect(store.pendingAttentionCount == 1)
    }

    @Test
    func `running changes only the light while approval and completion enqueue attention`() {
        let store = AgentTaskStatusStore()
        store.receive(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1"))
        #expect(store.aggregate(for: .codex).status == .running)
        #expect(store.currentAttention == nil)

        store.receive(.fixture(kind: .turnCompleted, sessionID: "a", turnID: "t1"))
        #expect(store.currentAttention?.status == .completed)

        store.receive(.fixture(kind: .approvalRequested, sessionID: "b", turnID: "t2"))
        #expect(store.currentAttention?.status == .needsApproval)
        #expect(store.pendingAttentionCount == 2)
    }

    @Test
    func `duplicate event is delivered once`() {
        let store = AgentTaskStatusStore()
        let event = AgentTaskEvent.fixture(kind: .turnCompleted, sessionID: "a", turnID: "t1")
        store.receive(event)
        store.receive(event)
        #expect(store.pendingAttentionCount == 1)
    }

    @Test
    func `tool completion clears matching approval and restores running`() {
        let store = AgentTaskStatusStore()
        store.receive(.fixture(kind: .approvalRequested, sessionID: "a", turnID: "t1"))
        #expect(store.currentAttention?.status == .needsApproval)

        store.receive(.fixture(
            kind: .toolCompleted,
            sessionID: "a",
            turnID: "t1",
            at: Date(timeIntervalSince1970: 101)))

        #expect(store.currentAttention == nil)
        #expect(store.aggregate(for: .codex).status == .running)
    }

    @Test
    func `dismissing terminal attention returns provider light to idle`() {
        let store = AgentTaskStatusStore()
        store.receive(.fixture(kind: .turnCompleted, sessionID: "a", turnID: "t1"))

        store.dismissCurrentAttention()

        #expect(store.currentAttention == nil)
        #expect(store.aggregate(for: .codex).status == .idle)
    }
}
