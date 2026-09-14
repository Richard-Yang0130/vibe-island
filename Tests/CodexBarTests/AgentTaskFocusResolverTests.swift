import CodexBarCore
import Foundation
import SQLite3
import Testing
@testable import CodexBar

struct AgentTaskFocusResolverTests {
    @Test
    @MainActor
    func `unpersisted codex hooks cannot become tasks or thread links`() {
        let sessionID = UUID().uuidString.lowercased()
        let store = AgentTaskStatusStore()
        let payload = Data("{\"session_id\":\"\(sessionID)\",\"hook_event_name\":\"Stop\"}".utf8)
        let envelope = AgentTaskWireEnvelope(schemaVersion: 1, provider: .codex, payload: payload)

        #expect(!AgentTaskEventIntake.receive(envelope, at: .now, into: store))
        #expect(store.aggregate(for: .codex).sessions.isEmpty)
        #expect(store.currentAttention == nil)
        #expect(AgentTaskFocusResolver.codexThreadURL(provider: .codex, sessionID: sessionID) == nil)
    }

    @Test
    @MainActor
    func `only persisted matching rollouts can enter the list and open`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionID = UUID().uuidString.lowercased()
        let rollout = directory.appendingPathComponent("rollout.jsonl")
        let databaseURL = directory.appendingPathComponent("state_5.sqlite")
        var database: OpaquePointer?
        #expect(sqlite3_open(databaseURL.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        let path = rollout.path.replacingOccurrences(of: "'", with: "''")
        #expect(sqlite3_exec(
            database,
            "CREATE TABLE threads (id TEXT, rollout_path TEXT);" +
                "INSERT INTO threads VALUES ('\(sessionID)', '\(path)');",
            nil,
            nil,
            nil) == SQLITE_OK)
        let reader = CodexThreadMetadataReader(databaseURL: databaseURL)
        let payload = Data("{\"session_id\":\"\(sessionID)\",\"hook_event_name\":\"Stop\"}".utf8)
        let envelope = AgentTaskWireEnvelope(schemaVersion: 1, provider: .codex, payload: payload)
        let store = AgentTaskStatusStore()
        // A DB row alone is insufficient; missing or mismatched history cannot be resumed.
        #expect(!AgentTaskEventIntake.receive(envelope, at: .now, into: store, threadReader: reader))
        try Data(#"{"type":"session_meta","payload":{"id":"other"}}"#.utf8).write(to: rollout)
        #expect(!reader.containsResumableThread(sessionID))
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionID)\"}}\n".utf8).write(to: rollout)
        #expect(AgentTaskEventIntake.receive(envelope, at: .now, into: store, threadReader: reader))
        #expect(store.aggregate(for: .codex).sessions.count == 1)
        #expect(AgentTaskFocusResolver.codexThreadURL(
            provider: .codex, sessionID: sessionID, threadReader: reader)?.absoluteString
            == "codex://threads/\(sessionID)")
        try FileManager.default.removeItem(at: rollout)
        #expect(AgentTaskFocusResolver.codexThreadURL(
            provider: .codex, sessionID: sessionID, threadReader: reader) == nil)
        #expect(AgentTaskFocusResolver.codexThreadURL(provider: .claude, sessionID: sessionID) == nil)
    }

    @Test
    func `running persisted turns are recovered without a new hook`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID().uuidString.lowercased()
        let rollout = directory.appendingPathComponent("rollout.jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}\n".utf8).write(to: rollout)
        let url = directory.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let path = rollout.path.replacingOccurrences(of: "'", with: "''")
        let history = directory.appendingPathComponent("thread_history_1.sqlite").path
            .replacingOccurrences(of: "'", with: "''")
        let sql = "CREATE TABLE threads (id TEXT, rollout_path TEXT, cwd TEXT, archived INTEGER, updated_at INTEGER);" +
            "INSERT INTO threads VALUES ('\(id)', '\(path)', '/repo', 0, 100);" +
            "ATTACH DATABASE '\(history)' AS history;" +
            "CREATE TABLE history.thread_turns (thread_id TEXT, turn_id TEXT, status TEXT," +
            " started_at INTEGER, rollout_ordinal INTEGER);" +
            "INSERT INTO history.thread_turns VALUES ('\(id)', 'turn', 'inProgress', 100, 0);" +
            "INSERT INTO history.thread_turns VALUES ('missing', 'turn', 'inProgress', 100, 0);"
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        let reader = CodexThreadMetadataReader(databaseURL: url)
        let events = reader.runningTaskEvents(now: Date(timeIntervalSince1970: 101))
        #expect(events.count == 1)
        #expect(events.first?.sessionID == id)
        #expect(events.first?.kind == .turnStarted)
        #expect(events.first?.transcriptPath == rollout.path)
        let terminal = "{\"timestamp\":\"1970-01-01T00:01:41Z\",\"type\":\"event_msg\"," +
            "\"payload\":{\"type\":\"turn_aborted\",\"turn_id\":\"turn\"}}\n"
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(terminal.utf8))
        try handle.close()
        #expect(reader.runningTaskEvents(now: Date(timeIntervalSince1970: 102)).isEmpty)
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\"}}\n".utf8).write(to: rollout)
        // A newer terminal record supersedes an old unfinished DB turn.
        #expect(sqlite3_exec(
            db,
            "INSERT INTO history.thread_turns VALUES ('\(id)', 'new', 'completed', 101, 1);",
            nil,
            nil,
            nil) == SQLITE_OK)
        #expect(reader.runningTaskEvents(now: Date(timeIntervalSince1970: 102)).isEmpty)
    }

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
