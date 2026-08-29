import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct AgentTaskFocusResolverTests {
    @Test
    func `exact session id wins over path fallback`() {
        let event = AgentTaskEvent.fixture(
            kind: .approvalRequested,
            sessionID: "exact",
            turnID: "turn",
            projectPath: "/repo")
        let sessions = [
            AgentSession.fixture(id: "other", provider: .codex, cwd: "/repo"),
            AgentSession.fixture(id: "exact", provider: .codex, cwd: "/elsewhere"),
        ]

        #expect(AgentTaskFocusResolver.resolve(event: event, sessions: sessions)?.id == "exact")
    }

    @Test
    func `provider mismatch never focuses a same path session`() {
        let event = AgentTaskEvent.fixture(
            kind: .turnCompleted,
            provider: .claude,
            sessionID: "x",
            turnID: nil,
            projectPath: "/repo")
        let sessions = [AgentSession.fixture(id: "x", provider: .codex, cwd: "/repo")]

        #expect(AgentTaskFocusResolver.resolve(event: event, sessions: sessions) == nil)
    }

    @Test
    func `transcript match precedes live cwd fallback`() {
        let event = AgentTaskEvent.fixture(
            kind: .turnCompleted,
            sessionID: "missing",
            turnID: nil,
            projectPath: "/repo",
            transcriptPath: "/logs/exact.jsonl")
        let sessions = [
            AgentSession.fixture(id: "cwd", provider: .codex, cwd: "/repo"),
            AgentSession.fixture(
                id: "transcript",
                provider: .codex,
                cwd: "/other",
                transcriptPath: "/logs/exact.jsonl",
                pid: nil),
        ]

        #expect(AgentTaskFocusResolver.resolve(event: event, sessions: sessions)?.id == "transcript")
    }

    @Test
    @MainActor
    func `intake rejects malformed payload without updating status`() {
        let store = AgentTaskStatusStore()
        let malformed = AgentTaskWireEnvelope(
            schemaVersion: AgentTaskWireEnvelope.currentSchemaVersion,
            provider: .claude,
            payload: Data(#"{"hook_event_name":"Stop"}"#.utf8))

        #expect(!AgentTaskEventIntake.receive(malformed, at: .now, into: store))
        #expect(store.aggregate(for: .claude).status == .idle)
    }

    @Test
    @MainActor
    func `intake delivers a valid normalized event`() {
        let store = AgentTaskStatusStore()
        let valid = AgentTaskWireEnvelope(
            schemaVersion: AgentTaskWireEnvelope.currentSchemaVersion,
            provider: .claude,
            payload: Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8))

        #expect(AgentTaskEventIntake.receive(valid, at: Date(timeIntervalSince1970: 10), into: store))
        #expect(store.aggregate(for: .claude).status == .completed)
    }
}

extension AgentSession {
    static func fixture(
        id: String,
        provider: AgentSession.Provider,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int32? = 42)
        -> AgentSession
    {
        AgentSession(
            id: id,
            provider: provider,
            source: .cli,
            state: .active,
            pid: pid,
            cwd: cwd,
            projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            startedAt: nil,
            lastActivityAt: .now,
            transcriptPath: transcriptPath,
            host: "test")
    }
}
