import CodexBarCore
import Foundation
import Network

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
    private let onDelivery: (@MainActor @Sendable (String, Bool) -> Void)?
    private let queue = DispatchQueue(label: "com.steipete.codexbar.agent-approval-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<Void, Error>?

    init(
        path: String = AgentTaskApprovalSocketPath.currentUserPath,
        onDelivery: (@MainActor @Sendable (String, Bool) -> Void)? = nil,
        handler: @escaping RequestHandler)
    {
        self.path = path
        self.handler = handler
        self.onDelivery = onDelivery
    }

    func start() async throws {
        try AgentTaskSocketSecurity.prepareServer(path: self.path)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: self.path)
        let listener = try NWListener(using: parameters)
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
                    do {
                        try AgentTaskSocketSecurity.secureServerSocket(path: self.path)
                        self.finishStart(.success(()))
                    } catch {
                        listener.cancel()
                        self.finishStart(.failure(error))
                    }
                case let .failed(error):
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
        try? AgentTaskSocketSecurity.removeServerSocket(path: self.path)
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

        let delivery = AgentTaskApprovalDelivery(
            connection: connection, requestID: request.requestID, onDelivery: self.onDelivery)
        Task { @MainActor [handler] in
            let decision = await handler(request)
            let response = AgentTaskApprovalResponse(requestID: request.requestID, decision: decision)
            guard let encoded = try? JSONEncoder().encode(response),
                  let frame = AgentTaskApprovalFrame.encode(encoded)
            else {
                delivery.finish(false)
                return
            }
            delivery.send(frame)
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
}

/// A write completion only means buffering succeeded; the helper's ACK confirms receipt.
private final class AgentTaskApprovalDelivery: @unchecked Sendable {
    private let connection: NWConnection
    private let requestID: String
    private let onDelivery: (@MainActor @Sendable (String, Bool) -> Void)?
    private let lock = NSLock()
    private var finished = false

    init(
        connection: NWConnection,
        requestID: String,
        onDelivery: (@MainActor @Sendable (String, Bool) -> Void)?)
    {
        self.connection = connection
        self.requestID = requestID
        self.onDelivery = onDelivery
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .failed, .cancelled: self.finish(false)
            default: break
            }
        }
    }

    func send(_ frame: Data) {
        self.lock.lock()
        let finished = self.finished
        self.lock.unlock()
        guard !finished else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + AgentTaskApprovalTimeouts.deliverySeconds)
        {
            self.finish(false)
        }
        self.connection.send(
            content: frame,
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { error in
                if error != nil { self.finish(false) } else {
                    self.receive(accumulator: AgentTaskApprovalAccumulator())
                }
            })
    }

    private func receive(accumulator original: AgentTaskApprovalAccumulator) {
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            guard error == nil else { self.finish(false); return }
            var accumulator = original
            if let body = accumulator.append(data) {
                let acknowledgement = try? JSONDecoder().decode(AgentTaskApprovalAcknowledgement.self, from: body)
                self.finish(
                    acknowledgement?.schemaVersion == AgentTaskApprovalAcknowledgement.currentSchemaVersion
                        && acknowledgement?.requestID == self.requestID)
            } else if isComplete || !accumulator.shouldContinue {
                self.finish(false)
            } else {
                self.receive(accumulator: accumulator)
            }
        }
    }

    func finish(_ delivered: Bool) {
        self.lock.lock()
        guard !self.finished else { self.lock.unlock(); return }
        self.finished = true
        self.lock.unlock()
        self.connection.stateUpdateHandler = nil
        self.connection.cancel()
        if let onDelivery {
            Task { @MainActor [requestID] in onDelivery(requestID, delivered) }
        }
    }
}
