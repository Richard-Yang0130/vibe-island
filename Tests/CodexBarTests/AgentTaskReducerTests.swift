import Foundation
import Testing
@testable import CodexBarCore

struct AgentTaskReducerTests {
    @Test
    func `approval outranks running and terminal events cannot move backwards`() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducer = AgentTaskReducer()
        reducer.apply(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1", at: startedAt))
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

        #expect(reducer.session(provider: .codex, sessionID: "a")?.status == .completed)
    }

    @Test
    func `session end removes only the matching session`() {
        var reducer = AgentTaskReducer()
        reducer.apply(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1"))
        reducer.apply(.fixture(kind: .turnStarted, sessionID: "b", turnID: "t2"))
        reducer.apply(.fixture(kind: .sessionEnded, sessionID: "a", turnID: nil))

        #expect(reducer.session(provider: .codex, sessionID: "a") == nil)
        #expect(reducer.session(provider: .codex, sessionID: "b")?.status == .running)
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
