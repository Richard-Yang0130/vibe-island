import Foundation
import Testing
@testable import CodexBarCore

struct AgentTaskReducerTests {
    @Test
    func `tool hooks retain the transcript needed to detect completion`() {
        var reducer = AgentTaskReducer()
        reducer.apply(.fixture(
            kind: .turnStarted,
            sessionID: "a",
            turnID: "t1",
            projectPath: "/repo",
            transcriptPath: "/rollout.jsonl",
            title: "Task"))
        reducer.apply(.fixture(
            kind: .toolCompleted,
            sessionID: "a",
            turnID: nil,
            at: Date(timeIntervalSince1970: 101)))
        let state = reducer.session(
            provider: .codex,
            sessionID: "a")
        #expect(state?.transcriptPath == "/rollout.jsonl")
        #expect(state?.projectPath == "/repo")
        #expect(state?.turnID == "t1")
    }

    @Test
    func `late tool hooks without turn ids cannot revive a completed turn`() {
        var reducer = AgentTaskReducer()
        reducer.apply(.fixture(
            kind: .sessionStarted,
            sessionID: "a",
            turnID: nil))
        reducer.apply(.fixture(
            kind: .toolCompleted,
            sessionID: "a",
            turnID: nil))
        #expect(reducer.session(
            provider: .codex,
            sessionID: "a")?.status == .running)
        reducer.apply(.fixture(
            kind: .turnCompleted,
            sessionID: "a",
            turnID: nil))
        reducer.apply(.fixture(
            kind: .toolCompleted,
            sessionID: "a",
            turnID: nil,
            at: Date(timeIntervalSince1970: 101)))
        #expect(reducer.session(
            provider: .codex,
            sessionID: "a")?.status == .completed)
        reducer.acknowledgeTerminal(
            provider: .codex,
            sessionID: "a")
        reducer.apply(.fixture(
            kind: .toolCompleted,
            sessionID: "a",
            turnID: nil,
            at: Date(timeIntervalSince1970: 102)))
        #expect(reducer.session(
            provider: .codex,
            sessionID: "a")?.status == .idle)
        reducer.apply(.fixture(
            kind: .turnStarted,
            sessionID: "a",
            turnID: nil,
            at: Date(timeIntervalSince1970: 103)))
        #expect(reducer.session(
            provider: .codex,
            sessionID: "a")?.status == .running)
    }

    @Test
    func `approval outranks running and terminal events cannot move backwards`() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducer = AgentTaskReducer()
        reducer.apply(.fixture(
            kind: .turnStarted,
            sessionID: "a",
            turnID: "t1",
            at: startedAt))
        reducer.apply(.fixture(
            kind: .approvalRequested,
            sessionID: "b",
            turnID: "t2",
            at: startedAt.addingTimeInterval(1)))

        #expect(reducer.aggregate(for: .codex).status == .needsApproval)

        reducer.apply(.fixture(
            kind: .turnCompleted,
            sessionID: "a",
            turnID: "t1",
            at: startedAt.addingTimeInterval(2)))
        reducer.apply(.fixture(
            kind: .turnStarted,
            sessionID: "a",
            turnID: "t1",
            at: startedAt.addingTimeInterval(3)))

        #expect(reducer.session(
            provider: .codex,
            sessionID: "a")?.status == .completed)
    }

    @Test
    func `session end removes only the matching session`() {
        var reducer = AgentTaskReducer()
        reducer.apply(.fixture(
            kind: .turnStarted,
            sessionID: "a",
            turnID: "t1"))
        reducer.apply(.fixture(
            kind: .turnStarted,
            sessionID: "b",
            turnID: "t2"))
        reducer.apply(.fixture(
            kind: .sessionEnded,
            sessionID: "a",
            turnID: nil))

        #expect(reducer.session(
            provider: .codex,
            sessionID: "a") == nil)
        #expect(reducer.session(
            provider: .codex,
            sessionID: "b")?.status == .running)
    }
}

extension AgentTaskEvent {
    static func fixture(
        kind: AgentTaskEventKind,
        provider: AgentTaskProvider = .codex,
        sessionID: String,
        turnID: String?,
        projectPath: String? = nil,
        transcriptPath: String? = nil,
        title: String? = nil,
        at: Date = Date(timeIntervalSince1970: 100))
        -> AgentTaskEvent
    {
        AgentTaskEvent(
            id: "\(provider.rawValue):\(sessionID):\(turnID ?? "-"):\(kind.rawValue):\(at.timeIntervalSince1970)",
            provider: provider,
            sessionID: sessionID,
            turnID: turnID,
            kind: kind,
            occurredAt: at,
            projectPath: projectPath,
            transcriptPath: transcriptPath,
            taskTitle: title,
            source: .hook)
    }
}
