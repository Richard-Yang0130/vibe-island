import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AgentTaskStatusStoreTests {
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
        newerState.updatedAt = Date(timeIntervalSince1970: 104)
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
