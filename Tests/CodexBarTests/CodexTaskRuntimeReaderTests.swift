import Foundation
import Testing
@testable import CodexBarCore

struct CodexTaskRuntimeReaderTests {
    @Test
    func `only writable rollout descriptors protect a session`() throws {
        let output = """
        p42
        f3
        ar
        n/tmp/reader.jsonl
        f4
        au
        n/tmp/writer.jsonl
        f5
        aw
        n/tmp/other.log
        p43
        f8
        aw
        n/tmp/second.jsonl

        """
        let paths = try #require(CodexTaskRuntimeReader.writableRolloutPaths(in: output, expectedPIDs: [42, 43]))
        #expect(paths == Set(["/tmp/writer.jsonl", "/tmp/second.jsonl"].map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        }))
        #expect(CodexTaskRuntimeReader.writableRolloutPaths(in: output, expectedPIDs: [42, 43, 44]) == nil)
        #expect(CodexTaskRuntimeReader.writableRolloutPaths(in: "p42\nfNOFD\n", expectedPIDs: [42]) == nil)
        #expect(CodexTaskRuntimeReader.writableRolloutPaths(
            in: "p42\nf4\nn/tmp/missing-access.jsonl\n", expectedPIDs: [42]) == nil)
    }

    @Test
    func `scan failures malformed inventories and process churn are unavailable`() async {
        let ps = "42 1 Sun Oct 25 18:00:00 2026 /Applications/ChatGPT.app/Contents/Resources/codex\n"
        let lsof = "p42\nf3\nau\nn/tmp/live.jsonl\n"
        let scenarios: [[SubprocessResult]] = [
            [.init(stdout: "", stderr: "")],
            [.init(stdout: "malformed", stderr: "")],
            [.init(stdout: ps, stderr: "permission denied")],
            [.init(stdout: ps, stderr: ""), .init(stdout: lsof, stderr: "permission denied")],
            [.init(stdout: ps, stderr: ""), .init(stdout: "p42\nfNOFD\n", stderr: "")],
            [
                .init(stdout: ps, stderr: ""),
                .init(stdout: lsof, stderr: ""),
                .init(stdout: ps.replacingOccurrences(of: "42 ", with: "43 "), stderr: ""),
            ],
        ]
        for results in scenarios {
            let script = RuntimeCommandScript(results: results)
            let snapshot = await CodexTaskRuntimeReader.read(run: { _, _ in try await script.next() })
            #expect(snapshot == nil)
        }
        let snapshot = await CodexTaskRuntimeReader.read(run: { _, _ in throw RuntimeCommandScript.Failure.exhausted })
        #expect(snapshot == nil)
    }

    @Test
    func `complete inventory without codex processes confirms no writers`() async throws {
        let script = RuntimeCommandScript(results: [
            .init(stdout: "42 1 Sun Oct 25 18:00:00 2026 /usr/bin/other\n", stderr: ""),
            .init(stdout: "42 1 Sun Oct 25 18:00:00 2026 /usr/bin/other\n", stderr: ""),
        ])
        let snapshot = try #require(await CodexTaskRuntimeReader.read(run: { _, _ in try await script.next() }))
        #expect(snapshot.writableRolloutPaths.isEmpty)
    }

    #if os(macOS)
    @Test
    func `real lsof sees an open writer and its subsequent close`() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID().uuidString).jsonl")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let pid = ProcessInfo.processInfo.processIdentifier
        let inventory = "\(pid) 1 Sun Oct 25 18:00:00 2026 /test/codex\n"
        let run: CodexTaskRuntimeReader.Command = { binary, arguments in
            if binary == "/bin/ps" { return SubprocessResult(stdout: inventory, stderr: "") }
            return try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: ProcessInfo.processInfo.environment,
                timeout: 3,
                maxOutputBytes: 4 * 1024 * 1024,
                label: "test-codex-rollout-writer")
        }
        let live = try #require(await CodexTaskRuntimeReader.read(run: run))
        #expect(live.writableRolloutPaths.contains(url.resolvingSymlinksInPath().path))
        try handle.close()
        let closed = try #require(await CodexTaskRuntimeReader.read(run: run))
        #expect(!closed.writableRolloutPaths.contains(url.resolvingSymlinksInPath().path))
    }
    #endif
}

private actor RuntimeCommandScript {
    enum Failure: Error { case exhausted }
    private var results: [SubprocessResult]

    init(results: [SubprocessResult]) {
        self.results = results
    }

    func next() throws -> SubprocessResult {
        guard !self.results.isEmpty else { throw Failure.exhausted }
        return self.results.removeFirst()
    }
}
