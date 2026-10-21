import Foundation
import Testing
@testable import CodexBarCore

struct CodexTaskCompletionReaderTests {
    @Test
    func `completion is not hidden by a delayed tool hook in the same turn`() throws {
        try self.withTranscript { url, _ in
            try self.record("task_complete").write(to: url, atomically: true, encoding: .utf8)
            var reducer = AgentTaskReducer()
            reducer.apply(.fixture(
                kind: .turnStarted,
                sessionID: "test",
                turnID: "t1",
                transcriptPath: url.path))
            reducer.apply(.fixture(
                kind: .toolCompleted,
                sessionID: "test",
                turnID: "t1",
                at: Date(timeIntervalSince1970: 102)))
            let state = try #require(reducer.session(provider: .codex, sessionID: "test"))

            #expect(CodexTaskCompletionReader.read(for: state)?.kind == .turnCompleted)
        }
    }

    @Test(arguments: ["task_complete", "turn_aborted", "failure"])
    func `reads terminal lifecycle records`(type: String) throws {
        try self.withTranscript { url, state in
            let eventType = type == "failure" ? "task_complete" : type
            let error = type == "failure" ? #", "error":"failed""# : ""
            try self.record(eventType, extra: error).write(to: url, atomically: true, encoding: .utf8)
            let event = try #require(CodexTaskCompletionReader.read(for: state))
            #expect(event.kind == (type == "failure" ? .turnFailed
                    : type == "turn_aborted" ? .turnInterrupted : .turnCompleted))
        }
    }

    @Test
    func `ignores incomplete records wrong turns and older completions`() throws {
        try self.withTranscript { url, state in
            let complete = self.record("task_complete")
            try String(complete.dropLast()).write(to: url, atomically: true, encoding: .utf8)
            #expect(CodexTaskCompletionReader.read(for: state) == nil)
            try complete.write(to: url, atomically: true, encoding: .utf8)
            var current = state
            current.turnID = "other"
            #expect(CodexTaskCompletionReader.read(for: current) == nil)
            current.turnID = nil
            current.turnStartedAt = Date(timeIntervalSince1970: 102)
            #expect(CodexTaskCompletionReader.read(for: current) == nil)
            try (complete + self.record("task_started")).write(to: url, atomically: true, encoding: .utf8)
            #expect(CodexTaskCompletionReader.read(for: state) == nil)
        }
    }

    @Test
    func `reads bounded tail past malformed data and tolerates missing files`() throws {
        try self.withTranscript { url, state in
            #expect(CodexTaskCompletionReader.read(for: state) == nil)
            let data = String(repeating: "x", count: 1024 * 1024 + 100) + "\n"
                + self.record("task_complete") + "invalid\n"
            try data.write(to: url, atomically: true, encoding: .utf8)
            #expect(CodexTaskCompletionReader.read(for: state)?.kind == .turnCompleted)
        }
    }

    private func record(_ type: String, extra: String = "") -> String {
        #"{"timestamp":"1970-01-01T00:01:41Z","type":"event_msg","payload":{"type":""#
            + type + #"","turn_id":"t1""# + extra + "}}\n"
    }

    private func withTranscript(_ body: (URL, AgentTaskSessionState) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url, AgentTaskSessionState(
            provider: .codex,
            sessionID: "test",
            turnID: "t1",
            status: .running,
            updatedAt: Date(timeIntervalSince1970: 100),
            projectPath: nil,
            transcriptPath: url.path,
            taskTitle: nil))
    }
}
