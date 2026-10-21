import Foundation
import Testing
@testable import CodexBarCore

struct AgentTaskEventNormalizerTests {
    @Test
    func `legacy envelopes without an event id do not permanently deduplicate payloads`() throws {
        let payload = Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8)
        let encoded = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "provider": "claude",
            "payload": payload.base64EncodedString(),
        ])
        let envelope = try JSONDecoder().decode(AgentTaskWireEnvelope.self, from: encoded)
        #expect(envelope.eventID == nil)
        let first = try #require(AgentTaskEventNormalizer.normalize(
            envelope,
            receivedAt: Date(timeIntervalSince1970: 100)))
        let second = try #require(AgentTaskEventNormalizer.normalize(
            envelope,
            receivedAt: Date(timeIntervalSince1970: 200)))
        #expect(first.id != second.id)
    }

    @Test
    func `separate hook invocations with identical payloads have distinct identities`() throws {
        let payload = Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8)
        let first = try #require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .claude, payload: payload),
            receivedAt: Date(timeIntervalSince1970: 100)))
        let second = try #require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .claude, payload: payload),
            receivedAt: Date(timeIntervalSince1970: 200)))

        #expect(first.id != second.id)
    }

    @Test
    func `codex interrupt ends the running turn`() throws {
        let payload = Data(#"{"session_id":"s2","hook_event_name":"Interrupt"}"#.utf8)
        let event = try #require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .codex, payload: payload),
            receivedAt: .now))
        #expect(event.kind == .turnInterrupted)
    }

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
    func `retransmitting the same envelope preserves its event identity`() throws {
        let payload = Data(
            #"{"session_id":"s2","turn_id":"t2","hook_event_name":"Stop"}"#.utf8)
        let envelope = AgentTaskWireEnvelope(schemaVersion: 1, provider: .codex, payload: payload)
        let first = try #require(AgentTaskEventNormalizer.normalize(
            envelope,
            receivedAt: Date(timeIntervalSince1970: 1)))
        let second = try #require(AgentTaskEventNormalizer.normalize(
            envelope,
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
