import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

struct AgentTaskEventBridgeTests {
    @Test
    func `agent event command stays hidden from root help`() {
        #expect(!CodexBarCLI.rootHelp(version: "test").contains("agent-event"))
        #expect(CodexBarCLI.agentEventHelp(version: "test").contains("--managed-by"))
    }

    @Test
    func `bridge wraps stdin and sends it once`() async throws {
        let capture = AgentTaskBridgeDataCapture()

        let success = await CodexBarCLI.forwardAgentEvent(
            provider: .claude,
            stdin: Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8),
            send: { data, _ in
                await capture.record(data)
                return true
            })

        #expect(success)
        let sent = await capture.value
        let envelope = try JSONDecoder().decode(AgentTaskWireEnvelope.self, from: #require(sent))
        #expect(envelope.provider == .claude)
    }

    @Test
    func `bridge reports success to hook when receiver is unavailable`() async {
        let startedAt = ContinuousClock.now
        let success = await CodexBarCLI.forwardAgentEvent(
            provider: .codex,
            stdin: Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8),
            send: { _, _ in false })

        #expect(success)
        #expect(startedAt.duration(to: .now) < .seconds(1))
    }

    @Test
    @MainActor
    func `socket forwards exactly one envelope`() async throws {
        let path = "/tmp/codexbar-agent-task-\(UUID().uuidString).sock"
        let capture = AgentTaskBridgeEnvelopeCapture()
        let server = AgentTaskEventSocketServer(path: path) { envelope in
            capture.record(envelope)
        }
        try await server.start()
        defer { server.stop() }

        let envelope = AgentTaskWireEnvelope(
            schemaVersion: AgentTaskWireEnvelope.currentSchemaVersion,
            provider: .codex,
            payload: Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8))
        let encoded = try JSONEncoder().encode(envelope)

        #expect(await AgentTaskBridgeClient.send(encoded, path))
        for _ in 0..<50 where capture.envelope == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capture.count == 1)
        #expect(capture.envelope == envelope)
    }
}

private actor AgentTaskBridgeDataCapture {
    private(set) var value: Data?

    func record(_ data: Data) {
        self.value = data
    }
}

@MainActor
private final class AgentTaskBridgeEnvelopeCapture {
    private(set) var count = 0
    private(set) var envelope: AgentTaskWireEnvelope?

    func record(_ envelope: AgentTaskWireEnvelope) {
        self.count += 1
        self.envelope = envelope
    }
}
