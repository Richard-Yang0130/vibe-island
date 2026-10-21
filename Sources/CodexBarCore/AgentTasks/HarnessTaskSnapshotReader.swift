#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public struct HarnessTaskSnapshot: Codable, Sendable {
    public let schemaVersion: Int
    public let pid: Int32
    public let generatedAt: Double
    public let events: [AgentTaskWireEnvelope]

    public init(schemaVersion: Int = 1, pid: Int32, generatedAt: Double, events: [AgentTaskWireEnvelope]) {
        self.schemaVersion = schemaVersion
        self.pid = pid
        self.generatedAt = generatedAt
        self.events = events
    }

    public func taskEvents(now: Date) -> [AgentTaskEvent] {
        self.events.filter { $0.provider == .deepseekHarness }.compactMap {
            AgentTaskEventNormalizer.normalize($0, receivedAt: now)
        }
    }
}

public enum HarnessTaskSnapshotReader {
    public static var path: String {
        URL(fileURLWithPath: AgentTaskSocketPath.currentUserPath)
            .deletingLastPathComponent().appendingPathComponent("harness-state.json").path
    }

    public static func read(
        path: String = Self.path,
        now: Date = Date(),
        isProcessRunning: (Int32) -> Bool = { $0 > 1 && kill($0, 0) == 0 }) -> HarnessTaskSnapshot?
    {
        let fileManager = FileManager.default
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard let directory = try? fileManager.attributesOfItem(atPath: parent),
              directory[.type] as? FileAttributeType == .typeDirectory,
              (directory[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              (directory[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= 512 * 1024,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)), data.count <= 512 * 1024,
              let snapshot = try? JSONDecoder().decode(HarnessTaskSnapshot.self, from: data),
              snapshot.schemaVersion == 1, snapshot.generatedAt.isFinite,
              now.timeIntervalSince1970 - snapshot.generatedAt / 1000 <= 10,
              snapshot.generatedAt / 1000 - now.timeIntervalSince1970 <= 5,
              isProcessRunning(snapshot.pid),
              snapshot.events.count <= 2048,
              snapshot.events.allSatisfy({ $0.provider == .deepseekHarness })
        else { return nil }
        return snapshot
    }
}
