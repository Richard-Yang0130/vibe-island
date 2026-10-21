import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct HarnessTaskRecoveryTests {
    private func envelope(_ hook: String, seq: Int, time: Int = 100) throws -> AgentTaskWireEnvelope {
        let payload = try JSONSerialization.data(withJSONObject: [
            "session_id": "h1", "turn_id": "1", "hook_event_name": hook,
            "harness_event_seq": seq, "harness_event_type": "turn/start",
            "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(time))),
        ])
        return AgentTaskWireEnvelope(schemaVersion: 1, provider: .deepseekHarness, payload: payload)
    }

    @Test @MainActor
    func `snapshot recovery deduplicates completion and reconnects a disconnected current turn`() throws {
        let start = try self.envelope("UserPromptSubmit", seq: 1)
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in nil })
        let snapshot = HarnessTaskSnapshot(pid: 99, generatedAt: 100_000, events: [start])
        store.synchronizeHarness(snapshot: snapshot, now: Date(timeIntervalSince1970: 100))
        #expect(store.aggregate(for: .deepseekHarness).status == .running)
        store.synchronizeHarness(snapshot: nil, now: Date(timeIntervalSince1970: 120))
        #expect(store.aggregate(for: .deepseekHarness).status == .disconnected)
        store.synchronizeHarness(snapshot: snapshot, now: Date(timeIntervalSince1970: 121))
        #expect(store.aggregate(for: .deepseekHarness).status == .running)
        #expect(store.currentAttention == nil)
        let done = try self.envelope("Stop", seq: 3, time: 125)
        let terminal = HarnessTaskSnapshot(pid: 99, generatedAt: 125_000, events: [start, done])
        store.synchronizeHarness(snapshot: terminal, now: Date(timeIntervalSince1970: 125))
        store.synchronizeHarness(snapshot: terminal, now: Date(timeIntervalSince1970: 126))
        #expect(store.pendingAttentionCount == 1)
        #expect(store.aggregate(for: .deepseekHarness).status == .completed)
    }

    @Test
    func `snapshot reader rejects stale unsafe and dead process records`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("harness-state.json")
        let data = try JSONEncoder().encode(HarnessTaskSnapshot(
            pid: 99,
            generatedAt: 100_000,
            events: [self.envelope("UserPromptSubmit", seq: 1)]))
        try data.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #expect(HarnessTaskSnapshotReader.read(
            path: url.path,
            now: Date(timeIntervalSince1970: 105),
            isProcessRunning: { _ in true }) != nil)
        #expect(HarnessTaskSnapshotReader.read(
            path: url.path,
            now: Date(timeIntervalSince1970: 111),
            isProcessRunning: { _ in true }) == nil)
        #expect(HarnessTaskSnapshotReader.read(
            path: url.path,
            now: Date(timeIntervalSince1970: 105),
            isProcessRunning: { _ in false }) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(HarnessTaskSnapshotReader.read(
            path: url.path,
            now: Date(timeIntervalSince1970: 105),
            isProcessRunning: { _ in true }) == nil)
    }

    @Test @MainActor
    func `dismissed disconnect can recover and subsequent outages still mark disconnected`() throws {
        let start = try self.envelope("UserPromptSubmit", seq: 1)
        let snapshot = HarnessTaskSnapshot(pid: 99, generatedAt: 100_000, events: [start])
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in nil })
        store.synchronizeHarness(snapshot: snapshot, now: Date(timeIntervalSince1970: 100))
        store.synchronizeHarness(snapshot: nil, now: Date(timeIntervalSince1970: 120))
        store.dismissCurrentAttention()
        #expect(store.aggregate(for: .deepseekHarness).status == .idle)
        store.synchronizeHarness(snapshot: snapshot, now: Date(timeIntervalSince1970: 121))
        #expect(store.aggregate(for: .deepseekHarness).status == .running)
        store.synchronizeHarness(snapshot: nil, now: Date(timeIntervalSince1970: 140))
        #expect(store.aggregate(for: .deepseekHarness).status == .disconnected)
    }

    @Test @MainActor
    func `a second outage of the same turn is a distinct state change`() throws {
        let start = try self.envelope("UserPromptSubmit", seq: 1)
        let snapshot = HarnessTaskSnapshot(pid: 99, generatedAt: 100_000, events: [start])
        let store = AgentTaskStatusStore(attentionDismissDelay: { _ in nil })
        store.synchronizeHarness(snapshot: snapshot, now: Date(timeIntervalSince1970: 100))
        store.synchronizeHarness(snapshot: nil, now: Date(timeIntervalSince1970: 120))
        store.synchronizeHarness(snapshot: snapshot, now: Date(timeIntervalSince1970: 121))
        store.synchronizeHarness(snapshot: nil, now: Date(timeIntervalSince1970: 140))
        #expect(store.aggregate(for: .deepseekHarness).status == .disconnected)
    }

    @Test
    func `Harness config installation is idempotent and removal preserves original bytes`() throws {
        let original = Data("# user configuration\n- set: title\n  config: { value: 'keep' }".utf8)
        let once = try HarnessTaskBridgeDocument.install(
            data: original,
            pluginPath: "/app/HarnessBridge.cjs",
            socketPath: "/private/task.sock",
            statePath: "/private/state.json")
        let twice = try HarnessTaskBridgeDocument.install(
            data: once,
            pluginPath: "/app/HarnessBridge.cjs",
            socketPath: "/private/task.sock",
            statePath: "/private/state.json")
        #expect(once == twice)
        #expect(try HarnessTaskBridgeDocument.remove(data: twice) == original)
        #expect(try !#require(String(data: once, encoding: .utf8)).contains("agent-approval"))
    }

    @Test
    func `installer keeps existing Harness configuration and refuses unreadable files`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = root.appendingPathComponent("HarnessBridge.cjs")
        try Data("// fixture".utf8).write(to: plugin)
        let installer = AgentTaskHookInstaller(homeDirectory: root, harnessPluginURL: plugin)
        let config = installer.configURL(for: .deepseekHarness)
        try FileManager.default.createDirectory(
            at: config.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let original = Data("# keep my settings\n- set: fixture\n  disabled: true\n".utf8)
        try original.write(to: config)
        try installer.install(.deepseekHarness)
        #expect(installer.inspect(.deepseekHarness).document == .installed)
        let firstInstall = try Data(contentsOf: config)
        let installedText = try #require(String(data: firstInstall, encoding: .utf8))
            .replacingOccurrences(of: "\\/", with: "/")
        #expect(!installedText.contains("socketPath: \"/var/"))
        #expect(installedText.contains("socketPath: \"/private/var/"))
        #expect(installedText.contains("statePath: \"/private/var/"))
        try Data("// updated fixture".utf8).write(to: plugin)
        #expect(installer.inspect(.deepseekHarness).document == .needsRepair)
        try installer.install(.deepseekHarness)
        #expect(try Data(contentsOf: config) != firstInstall)
        #expect(installer.inspect(.deepseekHarness).document == .installed)
        try installer.remove(.deepseekHarness)
        #expect(try Data(contentsOf: config) == original)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
        #expect(throws: (any Error).self) { try installer.install(.deepseekHarness) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        #expect(try Data(contentsOf: config) == original)
    }
}
