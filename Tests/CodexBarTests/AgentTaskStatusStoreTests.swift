import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AgentTaskStatusStoreTests {
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
