import CodexBarCore
import Foundation
import Network

#if canImport(Darwin)
import Darwin
#endif

struct AgentTaskEnvelopeAccumulator {
    static let maximumWireBytes = AgentTaskWireEnvelope.maximumPayloadBytes * 2

    private var data = Data()
    private(set) var shouldContinue = true

    mutating func append(_ chunk: Data?, isComplete: Bool) -> AgentTaskWireEnvelope? {
        guard self.shouldContinue else { return nil }
        if let chunk {
            guard self.data.count + chunk.count <= Self.maximumWireBytes else {
                self.shouldContinue = false
                return nil
            }
            self.data.append(chunk)
        }
        guard isComplete else { return nil }
        self.shouldContinue = false
        guard let envelope = try? JSONDecoder().decode(AgentTaskWireEnvelope.self, from: self.data),
              envelope.schemaVersion == AgentTaskWireEnvelope.currentSchemaVersion,
              AgentTaskWireEnvelope.acceptsPayload(envelope.payload)
        else { return nil }
        return envelope
    }
}

final class AgentTaskEventSocketServer: @unchecked Sendable {
    typealias EnvelopeHandler = @MainActor @Sendable (AgentTaskWireEnvelope) -> Void

    private let path: String
    private let handler: EnvelopeHandler
    private let queue = DispatchQueue(label: "com.steipete.codexbar.agent-task-server")
    private let lock = NSLock()
    private var listener: NWListener?
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var previousUmask: mode_t?

    init(
        path: String = AgentTaskSocketPath.currentUserPath,
        handler: @escaping EnvelopeHandler)
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
            self?.receive(on: connection)
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

    private func receive(on connection: NWConnection) {
        connection.start(queue: self.queue)
        self.receive(on: connection, accumulator: AgentTaskEnvelopeAccumulator())
    }

    private func receive(
        on connection: NWConnection,
        accumulator original: AgentTaskEnvelopeAccumulator)
    {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1024)
        { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }

            var accumulator = original
            if let envelope = accumulator.append(data, isComplete: isComplete) {
                connection.cancel()
                Task { @MainActor in
                    self.handler(envelope)
                }
            } else if accumulator.shouldContinue, data?.isEmpty == false {
                self.receive(on: connection, accumulator: accumulator)
            } else {
                connection.cancel()
            }
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
