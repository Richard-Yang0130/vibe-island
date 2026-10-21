#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

public struct AgentTaskWireEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumPayloadBytes = 64 * 1024

    public let schemaVersion: Int
    public let provider: AgentTaskProvider
    public let payload: Data
    public let eventID: UUID?

    public init(schemaVersion: Int, provider: AgentTaskProvider, payload: Data, eventID: UUID? = UUID()) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.payload = payload
        self.eventID = eventID
    }

    public static func acceptsPayload(_ payload: Data) -> Bool {
        !payload.isEmpty && payload.count <= self.maximumPayloadBytes
    }
}

public enum AgentTaskSocketPath {
    public static func path(uid: UInt32) -> String {
        AgentTaskSocketSecurity.path(uid: uid, fileName: "task.sock")
    }

    public static var currentUserPath: String {
        #if canImport(Darwin)
        self.path(uid: Darwin.getuid())
        #elseif canImport(Glibc)
        self.path(uid: Glibc.getuid())
        #elseif canImport(Musl)
        self.path(uid: Musl.getuid())
        #endif
    }
}
