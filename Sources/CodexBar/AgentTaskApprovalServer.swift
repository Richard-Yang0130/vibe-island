import CodexBarCore
import Foundation
import Network

#if canImport(Darwin)
import Darwin
#endif

/// Accumulates length-prefixed frames across `NWConnection` reads.
struct AgentTaskApprovalAccumulator {
    private var buffer = Data()
    private(set) var shouldContinue = true

    mutating func append(_ chunk: Data?) -> Data? {
        guard self.shouldContinue else { return nil }
        if let chunk { self.buffer.append(chunk) }
        switch AgentTaskApprovalFrame.decode(self.buffer) {
        case let .body(body, remainder):
            self.buffer = remainder
            return body
        case .oversized:
            self.shouldContinue = false
            return nil
        case .incomplete:
            return nil
        }
    }
}

/// Serves blocking permission requests from the hook helper.
///
/// Deliberately a second listener rather than a mode on the telemetry socket: that socket infers
/// message boundaries from the client hanging up, which cannot work when the client has to wait
/// for a reply. Keeping them apart also means a fault in either path leaves the other intact.
final class AgentTaskApprovalServer: @unchecked Sendable {
    typealias RequestHandler = @MainActor @Sendable (AgentTaskApprovalRequest) async -> AgentTaskApprovalDecision?

    private let path: String
    private let handler: RequestHandler
    private let queue = DispatchQueue(label: "com.steipete.codexbar.agent-approval-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var previousUmask: mode_t?

    init(
        path: String = AgentTaskApprovalSocketPath.currentUserPath,
        handler: @escaping RequestHandler)
    {
        self.path = path
        self.handler = handler
    }

    func start() async throws {
        try? FileManager.default.removeItem(atPath: self.path)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: self.path)
        #if canImport(Darwin)
        self.previousUmask = Darwin.umask(0o077)
        #endif

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            self.restoreUmask()
            throw error
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.receive(on: connection, accumulator: AgentTaskApprovalAccumulator())
        }

        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.readyContinuation = continuation
            self.lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.restoreUmask()
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: 0o600],
                        ofItemAtPath: self.path)
                    self.finishStart(.success(()))
                case let .failed(error):
                    self.restoreUmask()
                    self.finishStart(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: self.queue)
        }
    }

    func stop() {
        self.listener?.cancel()
        self.listener = nil
        self.restoreUmask()
        try? FileManager.default.removeItem(atPath: self.path)
    }

    private func receive(on connection: NWConnection, accumulator original: AgentTaskApprovalAccumulator) {
        connection
            .receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
                guard let self, error == nil else {
                    connection.cancel()
                    return
                }
                var accumulator = original
                if let body = accumulator.append(data) {
                    self.resolve(body: body, on: connection)
                    return
                }
                if isComplete || !accumulator.shouldContinue {
                    connection.cancel()
                    return
                }
                self.receive(on: connection, accumulator: accumulator)
            }
    }

    private func resolve(body: Data, on connection: NWConnection) {
        guard let request = try? JSONDecoder().decode(AgentTaskApprovalRequest.self, from: body),
              request.schemaVersion == AgentTaskApprovalRequest.currentSchemaVersion
        else {
            connection.cancel()
            return
        }

        Task { @MainActor [handler] in
            let decision = await handler(request)
            let response = AgentTaskApprovalResponse(requestID: request.requestID, decision: decision)
            guard let encoded = try? JSONEncoder().encode(response),
                  let frame = AgentTaskApprovalFrame.encode(encoded)
            else {
                connection.cancel()
                return
            }
            connection.send(
                content: frame,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func finishStart(_ result: Result<Void, Error>) {
        self.lock.lock()
        let continuation = self.readyContinuation
        self.readyContinuation = nil
        self.lock.unlock()

        switch result {
        case .success:
            continuation?.resume()
        case let .failure(error):
            continuation?.resume(throwing: error)
        }
    }

    private func restoreUmask() {
        #if canImport(Darwin)
        self.lock.lock()
        let previousUmask = self.previousUmask
        self.previousUmask = nil
        self.lock.unlock()
        if let previousUmask {
            Darwin.umask(previousUmask)
        }
        #endif
    }
}
