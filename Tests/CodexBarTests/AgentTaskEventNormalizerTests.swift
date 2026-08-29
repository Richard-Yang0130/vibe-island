import Foundation
import Testing
@testable import CodexBarCore

struct AgentTaskEventNormalizerTests {
    @Test
    func `claude permission payload keeps identity and drops command text`() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": "s1",
            "hook_event_name": "PermissionRequest",
            "cwd": "/repo",
            "tool_input": ["command": "private command"],
        ])
        let event = try #require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .claude, payload: payload),
            receivedAt: Date(timeIntervalSince1970: 200)))

        #expect(event.kind == .approvalRequested)
        #expect(event.sessionID == "s1")
        #expect(event.projectPath == "/repo")
        #expect(event.taskTitle == nil)
        #expect(!String(describing: event).contains("private command"))
    }

    @Test
    func `codex stop remains a completed turn without a failure signal`() throws {
        let payload = Data(
            #"{"session_id":"s2","turn_id":"t2","hook_event_name":"Stop"}"#.utf8)
        let event = try #require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .codex, payload: payload),
            receivedAt: .now))

        #expect(event.kind == .turnCompleted)
        #expect(event.turnID == "t2")
    }

    @Test
    func `same provider payload produces a stable event id`() throws {
        let payload = Data(
            #"{"session_id":"s2","turn_id":"t2","hook_event_name":"Stop"}"#.utf8)
        let first = try #require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .codex, payload: payload),
            receivedAt: Date(timeIntervalSince1970: 1)))
        let second = try #require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .codex, payload: payload),
            receivedAt: Date(timeIntervalSince1970: 2)))

        #expect(first.id == second.id)
    }

    @Test
    func `unknown and oversized payloads are rejected`() {
        #expect(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(
                schemaVersion: 1,
                provider: .codex,
                payload: Data(#"{"session_id":"s1","hook_event_name":"Unknown"}"#.utf8)),
            receivedAt: .now) == nil)
        #expect(!AgentTaskWireEnvelope.acceptsPayload(Data(repeating: 0, count: 65537)))
    }
}
