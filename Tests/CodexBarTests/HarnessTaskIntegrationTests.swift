import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HarnessTaskIntegrationTests {
    @Test
    func `Harness events preserve source timestamp identity and bounded task title`() throws {
        let provider = try #require(AgentTaskProvider(rawValue: "deepseekHarness"))
        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": "h1", "turn_id": "1", "hook_event_name": "UserPromptSubmit",
            "timestamp": "2026-10-21T08:00:00.123Z", "task_title": "Harness task",
            "harness_event_seq": 3, "harness_event_type": "turn/start",
        ])
        let event = try #require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: provider, payload: payload), receivedAt: .distantFuture))
        #expect(event.source.rawValue == "harnessBridge")
        #expect(event.taskTitle == "Harness task")
        #expect(abs(event.occurredAt.timeIntervalSince1970 - 1_792_569_600.123) < 0.001)
    }

    @Test @MainActor
    func `Harness completion enters the existing island reminder once and clears automatically`() async throws {
        let provider = try #require(AgentTaskProvider(rawValue: "deepseekHarness"))
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in 0.03 })
        let start = AgentTaskEvent(
            id: "h-start",
            provider: provider,
            sessionID: "h1",
            turnID: "1",
            kind: .turnStarted,
            occurredAt: Date(timeIntervalSince1970: 100),
            projectPath: "/project",
            transcriptPath: nil,
            taskTitle: "Harness task",
            source: .hook)
        let end = AgentTaskEvent(
            id: "h-end",
            provider: provider,
            sessionID: "h1",
            turnID: "1",
            kind: .turnCompleted,
            occurredAt: Date(timeIntervalSince1970: 101),
            projectPath: "/project",
            transcriptPath: nil,
            taskTitle: "Harness task",
            source: .hook)
        store.receive(start)
        #expect(store.aggregate(for: provider).status == .running)
        store.receive(end)
        store.receive(end)
        #expect(store.pendingAttentionCount == 1)
        let content = IslandContent(
            card: nil,
            aggregates: [provider: store.aggregate(for: provider)],
            attention: store.currentAttention,
            hidePersonalInfo: false)
        #expect(content.cards.first?.chips.first == "DeepSeek Harness")
        #expect(content.leadStatus == .completed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.currentAttention == nil)
        #expect(store.aggregate(for: provider).status == .idle)
    }
}
