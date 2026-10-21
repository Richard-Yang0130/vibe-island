import CodexBarCore
import Foundation
import Network
import Testing
@testable import CodexBar
@testable import CodexBarCLI

private actor ApprovalAcknowledgementCapture {
    private(set) var body: Data?

    func record(_ body: Data) {
        self.body = body
    }
}

private final class ApprovalAcknowledgementPeer: @unchecked Sendable {
    let path: String
    let capture = ApprovalAcknowledgementCapture()
    private let listener: NWListener
    private let responseSchemaVersion: Int
    private let responseRequestID: String?
    private let queue = DispatchQueue(label: "codexbar.approval-acknowledgement-test")

    init(responseSchemaVersion: Int = 1, responseRequestID: String? = nil) throws {
        self.responseSchemaVersion = responseSchemaVersion
        self.responseRequestID = responseRequestID
        self.path = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("cba-\(UUID().uuidString.prefix(8))").appendingPathComponent("a.sock").path
        try AgentTaskSocketSecurity.prepareServer(path: self.path)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: self.path)
        self.listener = try NWListener(using: parameters)
    }

    func start() async throws {
        self.listener.newConnectionHandler = { [self] connection in
            connection.start(queue: self.queue)
            self.receive(on: connection, acknowledgement: false, accumulator: AgentTaskApprovalAccumulator())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    do {
                        try AgentTaskSocketSecurity.secureServerSocket(path: self.path)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                case let .failed(error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            self.listener.start(queue: self.queue)
        }
    }

    func stop() {
        self.listener.cancel()
        try? FileManager.default.removeItem(atPath: (self.path as NSString).deletingLastPathComponent)
    }

    private func receive(
        on connection: NWConnection,
        acknowledgement: Bool,
        accumulator original: AgentTaskApprovalAccumulator)
    {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, isComplete, error in
            var accumulator = original
            guard error == nil else { connection.cancel(); return }
            if let body = accumulator.append(data) {
                if acknowledgement {
                    Task { await self.capture.record(body) }
                    connection.cancel()
                } else {
                    guard let request = try? JSONDecoder().decode(AgentTaskApprovalRequest.self, from: body),
                          let encoded = try? JSONEncoder().encode(AgentTaskApprovalResponse(
                              requestID: request.requestID, decision: .allowedOnce)),
                          var response = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any]
                    else { connection.cancel(); return }
                    response["schemaVersion"] = self.responseSchemaVersion
                    response["requestID"] = self.responseRequestID ?? request.requestID
                    guard let body = try? JSONSerialization.data(withJSONObject: response),
                          let frame = AgentTaskApprovalFrame.encode(body)
                    else { connection.cancel(); return }
                    connection.send(
                        content: frame,
                        contentContext: .defaultMessage,
                        isComplete: false,
                        completion: .contentProcessed { error in
                            guard error == nil else { connection.cancel(); return }
                            self.receive(
                                on: connection,
                                acknowledgement: true,
                                accumulator: AgentTaskApprovalAccumulator())
                        })
                }
            } else if isComplete || !accumulator.shouldContinue {
                connection.cancel()
            } else {
                self.receive(on: connection, acknowledgement: acknowledgement, accumulator: accumulator)
            }
        }
    }
}

@MainActor
private final class ApprovalDeliveryCapture {
    var results: [(String, Bool)] = []
}

@MainActor
private final class ApprovalDecisionGate {
    var continuation: CheckedContinuation<AgentTaskApprovalDecision?, Never>?

    func wait() async -> AgentTaskApprovalDecision? {
        await withCheckedContinuation { self.continuation = $0 }
    }

    func resolve() {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: .allowedOnce)
    }
}

private func approvalDeliveryPath() -> String {
    FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        .appendingPathComponent("cba-\(UUID().uuidString.prefix(8))").appendingPathComponent("a.sock").path
}

private func sendApprovalRequest(_ request: AgentTaskApprovalRequest, path: String) async throws -> NWConnection {
    let frame = try #require(AgentTaskApprovalFrame.encode(JSONEncoder().encode(request)))
    let connection = NWConnection(to: .unix(path: path), using: .tcp)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.stateUpdateHandler = nil
                connection.send(
                    content: frame,
                    contentContext: .defaultMessage,
                    isComplete: false,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    })
            case let .failed(error):
                connection.stateUpdateHandler = nil
                continuation.resume(throwing: error)
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "codexbar.raw-approval-test"))
    }
    return connection
}

private func receiveApprovalFrame(on connection: NWConnection) async -> Data? {
    var accumulator = AgentTaskApprovalAccumulator()
    while accumulator.shouldContinue {
        let (data, complete, failed): (Data?, Bool, Bool) = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, complete, error in
                continuation.resume(returning: (data, complete, error != nil))
            }
        }
        guard !failed else { return nil }
        if let body = accumulator.append(data) { return body }
        if complete { return nil }
    }
    return nil
}

struct AgentTaskApprovalAcknowledgementTests {
    @Test
    func `helper acknowledges the complete response before returning`() async throws {
        let peer = try ApprovalAcknowledgementPeer()
        try await peer.start()
        defer { peer.stop() }
        let request = AgentTaskApprovalRequest(provider: .claude, requestID: "ack-request", payload: Data("{}".utf8))
        let frame = try #require(AgentTaskApprovalFrame.encode(JSONEncoder().encode(request)))

        let response = await AgentTaskApprovalClient.exchange(frame, peer.path)
        #expect(response != nil)
        for _ in 0..<100 {
            if await peer.capture.body != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let body = try #require(await peer.capture.body)
        let acknowledgement = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(acknowledgement["schemaVersion"] as? Int == 1)
        #expect(acknowledgement["requestID"] as? String == request.requestID)
    }

    @Test(arguments: ["request", "schema"])
    func `helper does not acknowledge a response with the wrong identity or version`(_ mismatch: String) async throws {
        let peer = try ApprovalAcknowledgementPeer(
            responseSchemaVersion: mismatch == "schema" ? 2 : 1,
            responseRequestID: mismatch == "request" ? "other-request" : nil)
        try await peer.start()
        defer { peer.stop() }
        let request = AgentTaskApprovalRequest(provider: .claude, requestID: "r1", payload: Data("{}".utf8))
        let frame = try #require(AgentTaskApprovalFrame.encode(JSONEncoder().encode(request)))

        #expect(await AgentTaskApprovalClient.exchange(frame, peer.path) == nil)
        #expect(await peer.capture.body == nil)
    }

    @Test
    @MainActor
    func `server confirms that the real helper received the response`() async throws {
        let path = approvalDeliveryPath()
        let capture = ApprovalDeliveryCapture()
        let server = AgentTaskApprovalServer(
            path: path,
            onDelivery: { capture.results.append(($0, $1)) },
            handler: { _ in .denied(message: "No") })
        try await server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }
        let request = AgentTaskApprovalRequest(provider: .claude, requestID: "r1", payload: Data("{}".utf8))
        let frame = try #require(AgentTaskApprovalFrame.encode(JSONEncoder().encode(request)))
        let body = try #require(await AgentTaskApprovalClient.exchange(frame, path))
        #expect(try JSONDecoder().decode(AgentTaskApprovalResponse.self, from: body).decision?.behavior == .deny)
        for _ in 0..<200 where capture.results.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(capture.results.count == 1)
        #expect(capture.results.first?.0 == request.requestID)
        #expect(capture.results.first?.1 == true)
    }

    @Test
    @MainActor
    func `a helper cancelled before the decision is not reported as delivered`() async throws {
        let path = approvalDeliveryPath()
        let capture = ApprovalDeliveryCapture()
        let gate = ApprovalDecisionGate()
        let server = AgentTaskApprovalServer(
            path: path,
            onDelivery: { capture.results.append(($0, $1)) },
            handler: { _ in await gate.wait() })
        try await server.start()
        defer {
            gate.resolve()
            server.stop()
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }
        let request = AgentTaskApprovalRequest(provider: .claude, requestID: "r1", payload: Data("{}".utf8))
        let connection = try await sendApprovalRequest(request, path: path)
        for _ in 0..<100 where gate.continuation == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.continuation != nil)
        connection.cancel()
        gate.resolve()
        for _ in 0..<200 where capture.results.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(capture.results.count == 1)
        #expect(capture.results.first?.0 == request.requestID)
        #expect(capture.results.first?.1 == false)
    }

    @Test
    @MainActor
    func `a helper that never acknowledges the response times out`() async throws {
        let path = approvalDeliveryPath()
        let capture = ApprovalDeliveryCapture()
        let server = AgentTaskApprovalServer(
            path: path,
            onDelivery: { capture.results.append(($0, $1)) },
            handler: { _ in .allowedOnce })
        try await server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }
        let request = AgentTaskApprovalRequest(provider: .claude, requestID: "r1", payload: Data("{}".utf8))
        let connection = try await sendApprovalRequest(request, path: path)
        defer { connection.cancel() }
        _ = try #require(await receiveApprovalFrame(on: connection))
        for _ in 0..<200 where capture.results.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(capture.results.count == 1)
        #expect(capture.results.first?.1 == false)
    }

    @Test(arguments: ["request", "schema"])
    @MainActor
    func `an acknowledgement with the wrong identity or version fails delivery`(_ mismatch: String) async throws {
        let path = approvalDeliveryPath()
        let capture = ApprovalDeliveryCapture()
        let server = AgentTaskApprovalServer(
            path: path,
            onDelivery: { capture.results.append(($0, $1)) },
            handler: { _ in .allowedOnce })
        try await server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }
        let request = AgentTaskApprovalRequest(provider: .claude, requestID: "r1", payload: Data("{}".utf8))
        let connection = try await sendApprovalRequest(request, path: path)
        defer { connection.cancel() }
        _ = try #require(await receiveApprovalFrame(on: connection))
        let body = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": mismatch == "schema" ? 2 : 1,
            "requestID": mismatch == "request" ? "other-request" : request.requestID,
        ])
        let frame = try #require(AgentTaskApprovalFrame.encode(body))
        connection.send(content: frame, isComplete: true, completion: .idempotent)
        for _ in 0..<200 where capture.results.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(capture.results.count == 1)
        #expect(capture.results.first?.1 == false)
    }

    @Test
    @MainActor
    func `a fragmented acknowledgement reports delivery only once`() async throws {
        let path = approvalDeliveryPath()
        let capture = ApprovalDeliveryCapture()
        let server = AgentTaskApprovalServer(
            path: path,
            onDelivery: { capture.results.append(($0, $1)) },
            handler: { _ in .allowedOnce })
        try await server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
        }
        let request = AgentTaskApprovalRequest(provider: .claude, requestID: "r1", payload: Data("{}".utf8))
        let connection = try await sendApprovalRequest(request, path: path)
        defer { connection.cancel() }
        _ = try #require(await receiveApprovalFrame(on: connection))
        let frame = try #require(AgentTaskApprovalFrame.encode(JSONEncoder().encode(
            AgentTaskApprovalAcknowledgement(requestID: request.requestID))))
        connection.send(content: Data(frame.prefix(2)), isComplete: false, completion: .idempotent)
        connection.send(content: Data(frame.dropFirst(2)), isComplete: true, completion: .idempotent)
        try await Task.sleep(for: .seconds(AgentTaskApprovalTimeouts.deliverySeconds + 0.1))

        #expect(capture.results.count == 1)
        #expect(capture.results.first?.1 == true)
    }
}
