import CodexBarCore
import Darwin
import Foundation
import Network
import Testing
@testable import CodexBar
@testable import CodexBarCLI

private func socketTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("cbs-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return directory
}

struct AgentTaskSocketSecurityTests {
    @Test
    func `server refuses a public directory before binding`() async throws {
        let directory = try socketTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("s.sock").path
        let server = AgentTaskEventSocketServer(path: path) { _ in }
        defer { server.stop() }

        await #expect(throws: AgentTaskSocketSecurity.Failure.self) { try await server.start() }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test
    func `server preserves a regular file and rejects a socket symlink`() async throws {
        let directory = try socketTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        try Data("preserve me".utf8).write(to: URL(fileURLWithPath: path))
        let server = AgentTaskApprovalServer(path: path) { _ in .allowedOnce }
        defer { server.stop() }

        await #expect(throws: AgentTaskSocketSecurity.Failure.self) { try await server.start() }
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "preserve me")
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "missing")
        await #expect(throws: AgentTaskSocketSecurity.Failure.self) { try await server.start() }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: path) == "missing")
    }

    @Test
    func `a symlinked parent and another owner are refused`() throws {
        let directory = try socketTestDirectory()
        let link = directory.deletingLastPathComponent().appendingPathComponent("cbs-\(UUID().uuidString.prefix(8))")
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)

        #expect(throws: AgentTaskSocketSecurity.Failure.self) {
            try AgentTaskSocketSecurity.prepareServer(path: link.appendingPathComponent("s.sock").path)
        }
        #expect(throws: AgentTaskSocketSecurity.Failure.self) {
            try AgentTaskSocketSecurity.prepareServer(
                path: directory.appendingPathComponent("s.sock").path, uid: getuid() + 1)
        }
    }

    @Test
    func `old public paths and oversized addresses are refused`() throws {
        #expect(throws: AgentTaskSocketSecurity.Failure.self) {
            try AgentTaskSocketSecurity.prepareServer(path: "/tmp/codexbar-\(getuid())-agent-approval.sock")
        }
        #expect(throws: AgentTaskSocketSecurity.Failure.self) {
            try AgentTaskSocketSecurity.prepareServer(path: "/" + String(repeating: "x", count: 104))
        }
    }

    @Test
    func `clients require a private socket in a private directory`() async throws {
        let directory = try socketTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        let server = AgentTaskApprovalServer(path: path) { _ in nil }
        try await server.start()
        defer { server.stop() }

        try AgentTaskSocketSecurity.validateClient(path: path)
        #expect(throws: AgentTaskSocketSecurity.Failure.self) {
            try AgentTaskSocketSecurity.validateClient(path: path, uid: getuid() + 1)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path)
        #expect(throws: AgentTaskSocketSecurity.Failure.self) {
            try AgentTaskSocketSecurity.validateClient(path: path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    @Test
    func `clients ignore an allow reply from a public directory`() async throws {
        let directory = try socketTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("s.sock").path
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        let response = AgentTaskApprovalResponse(requestID: "forged", decision: .allowedOnce)
        let frame = try #require(AgentTaskApprovalFrame.encode(JSONEncoder().encode(response)))
        let queue = DispatchQueue(label: "codexbar.socket-security-test")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.send(
                content: frame,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        #expect(await AgentTaskApprovalClient.exchange(Data(), path) == nil)
        #expect(await AgentTaskBridgeClient.send(Data("private event".utf8), path) == false)
    }
}
