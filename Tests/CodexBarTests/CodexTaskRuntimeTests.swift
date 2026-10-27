import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CodexTaskRuntimeTests {
    @Test
    func `recovery loop retires an exited task even when it is absent from recovery results`() async throws {
        let url = try self.transcript(sessionID: "a")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentTaskStatusStore()
        store.receive(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1", transcriptPath: url.path))
        let snapshots = CodexRuntimeSnapshotSequence()
        store.startRunningTaskRecovery(read: { [] }, readRuntime: { await snapshots.next() })
        defer { store.stopCompletionMonitoring() }
        for _ in 0..<100 {
            if store.aggregate(for: .codex).status == .idle { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(store.aggregate(for: .codex).status == .idle)
        #expect(store.currentAttention == nil)
    }

    @Test
    func `orphan cleanup preserves another live task and other providers`() throws {
        try self.withRunningTask { store, _ in
            let liveURL = try self.transcript(sessionID: "live")
            defer { try? FileManager.default.removeItem(at: liveURL) }
            store.receive(.fixture(
                kind: .turnStarted, sessionID: "live", turnID: "t2", transcriptPath: liveURL.path))
            store.receive(.fixture(kind: .turnStarted, provider: .claude, sessionID: "claude", turnID: "t3"))
            store.receive(.fixture(kind: .turnStarted, provider: .deepseekHarness, sessionID: "harness", turnID: "t4"))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1000, paths: [liveURL.path]))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1016, paths: [liveURL.path]))
            let states = store.aggregate(for: .codex).sessions
            #expect(states.first(where: { $0.sessionID == "a" })?.status == .idle)
            #expect(states.first(where: { $0.sessionID == "live" })?.status == .running)
            #expect(store.aggregate(for: .claude).status == .running)
            #expect(store.aggregate(for: .deepseekHarness).status == .running)
        }
    }

    @Test
    func `normal completion retains its notification during a runtime scan`() throws {
        try self.withRunningTask { store, _ in
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1000))
            store.receive(.fixture(kind: .turnCompleted, sessionID: "a", turnID: "t1", at: self.date(1001)))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1016))
            #expect(store.aggregate(for: .codex).status == .completed)
            #expect(store.currentAttention?.status == .completed)
        }
    }

    @Test
    func `ownerless unchanged turn retires without a completion notification`() throws {
        try self.withRunningTask { store, path in
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1000))
            #expect(store.aggregate(for: .codex).status == .running)
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1016))
            #expect(store.aggregate(for: .codex).status == .idle)
            #expect(store.currentAttention == nil)

            store.receive(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1", transcriptPath: path))
            store.receive(.fixture(kind: .toolCompleted, sessionID: "a", turnID: nil, at: self.date(1017)))
            store.receive(.fixture(kind: .approvalRequested, sessionID: "a", turnID: nil, at: self.date(1017.5)))
            #expect(store.aggregate(for: .codex).status == .idle)
            #expect(store.currentAttention == nil)
            store.receive(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t2", at: self.date(1018)))
            #expect(store.aggregate(for: .codex).status == .running)
        }
    }

    @Test(arguments: [AgentTaskEventKind.turnStarted, .approvalRequested])
    func `live writer protects silent running and approval turns`(kind: AgentTaskEventKind) throws {
        try self.withRunningTask { store, path in
            store.receive(.fixture(kind: kind, sessionID: "a", turnID: "t1", at: self.date(101)))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1000))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1100, paths: [path]))
            #expect(store.aggregate(for: .codex).status == (kind == .turnStarted ? .running : .needsApproval))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1200))
            #expect(store.aggregate(for: .codex).status != .idle)
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1216))
            #expect(store.aggregate(for: .codex).status == .idle)
            #expect(store.currentAttention == nil)
        }
    }

    @Test
    func `unavailable scan resets orphan confirmation`() throws {
        try self.withRunningTask { store, _ in
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1000))
            store.synchronizeCodexRuntime(snapshot: nil)
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1100))
            #expect(store.aggregate(for: .codex).status == .running)
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1116))
            #expect(store.aggregate(for: .codex).status == .idle)
        }
    }

    @Test
    func `new tool activity and new turns restart orphan confirmation`() throws {
        try self.withRunningTask { store, _ in
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1000))
            store.receive(.fixture(kind: .toolCompleted, sessionID: "a", turnID: "t1", at: self.date(1001)))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1016))
            #expect(store.aggregate(for: .codex).status == .running)
            store.receive(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t2", at: self.date(1017)))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1032))
            #expect(store.aggregate(for: .codex).sessions.first?.turnID == "t2")
            #expect(store.aggregate(for: .codex).status == .running)
        }
    }

    @Test
    func `changed transcript restarts confirmation even without a hook`() throws {
        try self.withRunningTask { store, path in
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1000))
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{}\n".utf8))
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: self.date(1001)], ofItemAtPath: path)
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1016))
            #expect(store.aggregate(for: .codex).status == .running)
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1032))
            #expect(store.aggregate(for: .codex).status == .idle)
        }
    }

    @Test
    func `snapshot older than a new hook cannot clear the task`() throws {
        try self.withRunningTask { store, _ in
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1000))
            store.receive(.fixture(kind: .toolCompleted, sessionID: "a", turnID: "t1", at: self.date(1020)))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1016))
            #expect(store.aggregate(for: .codex).status == .running)
        }
    }

    @Test
    func `missing or mismatched transcript is not evidence of an exited task`() throws {
        try self.withRunningTask { store, path in
            try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"other\"}}\n".utf8)
                .write(to: URL(fileURLWithPath: path))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1000))
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1016))
            #expect(store.aggregate(for: .codex).status == .running)
            try FileManager.default.removeItem(atPath: path)
            store.synchronizeCodexRuntime(snapshot: self.snapshot(at: 1100))
            #expect(store.aggregate(for: .codex).status == .running)
        }
    }

    private func withRunningTask(_ body: (AgentTaskStatusStore, String) throws -> Void) throws {
        let url = try self.transcript(sessionID: "a")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in nil })
        defer { store.stopCompletionMonitoring() }
        store.receive(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1", transcriptPath: url.path))
        try body(store, url.path)
    }

    private func transcript(sessionID: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(sessionID)\",\"source\":\"exec\"}}\n".utf8)
            .write(to: url)
        try FileManager.default.setAttributes([.modificationDate: self.date(100)], ofItemAtPath: url.path)
        return url
    }

    private func snapshot(at time: TimeInterval, paths: Set<String> = []) -> CodexTaskRuntimeSnapshot {
        CodexTaskRuntimeSnapshot(checkedAt: self.date(time), writableRolloutPaths: paths)
    }

    private func date(_ time: TimeInterval) -> Date {
        Date(timeIntervalSince1970: time)
    }
}

private actor CodexRuntimeSnapshotSequence {
    private var time: TimeInterval = 1000

    func next() -> CodexTaskRuntimeSnapshot {
        defer { self.time += 16 }
        return CodexTaskRuntimeSnapshot(checkedAt: Date(timeIntervalSince1970: self.time), writableRolloutPaths: [])
    }
}
