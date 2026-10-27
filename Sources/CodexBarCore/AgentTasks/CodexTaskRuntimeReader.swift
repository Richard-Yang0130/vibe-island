import Foundation

public struct CodexTaskRuntimeSnapshot: Sendable {
    public let checkedAt: Date
    public let writableRolloutPaths: Set<String>

    public init(checkedAt: Date, writableRolloutPaths: Set<String>) {
        self.checkedAt = checkedAt
        self.writableRolloutPaths = Set(writableRolloutPaths.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
        })
    }
}

/// A complete descriptor scan distinguishes a silent turn from a recorder whose process has exited.
public enum CodexTaskRuntimeReader {
    typealias Command = @Sendable (String, [String]) async throws -> SubprocessResult

    public static func read() async -> CodexTaskRuntimeSnapshot? {
        await self.read { binary, arguments in
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            return try await SubprocessRunner.run(
                binary: binary,
                arguments: arguments,
                environment: environment,
                timeout: 3,
                maxOutputBytes: 4 * 1024 * 1024,
                label: "codex-task-runtime")
        }
    }

    static func read(run: Command) async -> CodexTaskRuntimeSnapshot? {
        let checkedAt = Date()
        do {
            guard let before = try await self.processes(run: run) else { return nil }
            var paths = Set<String>()
            if !before.isEmpty {
                let result = try await run("/usr/sbin/lsof", [
                    "-nP", "-a", "-p", before.map { String($0.pid) }.joined(separator: ","), "-Fpfan",
                ])
                guard result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let writable = self.writableRolloutPaths(in: result.stdout, expectedPIDs: Set(before.map(\.pid)))
                else { return nil }
                paths = writable
            }
            // A new/resumed process during lsof makes absence inconclusive until the next poll.
            guard let after = try await self.processes(run: run), before == after else { return nil }
            return CodexTaskRuntimeSnapshot(checkedAt: checkedAt, writableRolloutPaths: paths)
        } catch {
            return nil
        }
    }

    private static func processes(run: Command) async throws -> [AgentProcessRecord]? {
        let result = try await run("/bin/ps", ["-x", "-o", "pid=,ppid=,lstart=,comm="])
        let lines = result.stdout.split(whereSeparator: \.isNewline)
        let records = AgentPSOutputParser.parse(result.stdout)
        guard result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !records.isEmpty, records.count == lines.count,
              records.allSatisfy({ $0.startedAt != nil })
        else { return nil }
        return records.filter {
            let name = URL(fileURLWithPath: $0.command).lastPathComponent.lowercased()
            return name == "codex" || name.hasPrefix("codex-")
        }.sorted { $0.pid < $1.pid }
    }

    static func writableRolloutPaths(in output: String, expectedPIDs: Set<Int32>) -> Set<String>? {
        var descriptorPIDs = Set<Int32>()
        var paths = Set<String>()
        var pid: Int32?
        var numericDescriptor = false
        var access: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let value = String(line.dropFirst())
            switch line.first {
            case "p":
                pid = Int32(value)
                numericDescriptor = false
                access = nil
            case "f":
                numericDescriptor = Int(value) != nil
                access = nil
                if numericDescriptor, let pid { descriptorPIDs.insert(pid) }
            case "a":
                access = value
            case "n" where numericDescriptor && value.hasSuffix(".jsonl"):
                guard let access, ["r", "w", "u"].contains(access), value.hasPrefix("/"),
                      !value.contains("\\")
                else { return nil }
                if access != "r" { paths.insert(value) }
            default:
                break
            }
        }
        guard descriptorPIDs == expectedPIDs else { return nil }
        return paths
    }
}
