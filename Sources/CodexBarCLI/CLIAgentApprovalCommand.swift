import CodexBarCore
import Commander
import Foundation

#if canImport(Network)
import Network
#endif

struct AgentApprovalOptions: CommanderParsable {
    @Option(name: .long("provider"), help: "codex | claude")
    var provider: String?

    @Option(name: .long("managed-by"), help: "Internal hook owner marker")
    var managedBy: String?
}

extension CodexBarCLI {
    /// Blocking `PermissionRequest` hook handler.
    ///
    /// Unlike `agent-event`, this one stays alive until CodexBar returns a decision, because a
    /// background hook is documented by both agents to be incapable of approving or denying
    /// anything.
    ///
    /// Every failure path is silent and fails open. Printing nothing means "no decision", which
    /// sends the agent back to its normal approval flow — the same thing that happens today. The
    /// helper must never emit diagnostics on stdout: the agents parse stdout as the decision, so a
    /// stray log line is a malformed decision.
    static func runAgentApproval(_ values: ParsedValues) async {
        guard values.options["managedBy"]?.last == self.agentTaskHookOwnerMarker,
              let rawProvider = values.options["provider"]?.last,
              let provider = AgentTaskProvider(rawValue: rawProvider)
        else { return }

        let stdin = FileHandle.standardInput.readData(
            ofLength: AgentTaskApprovalFrame.maximumBodyBytes + 1)
        guard let output = await self.resolveApproval(provider: provider, stdin: stdin) else { return }
        FileHandle.standardOutput.write(output)
    }

    static func resolveApproval(
        provider: AgentTaskProvider,
        stdin: Data,
        exchange: @Sendable (Data, String) async -> Data? = AgentTaskApprovalClient.exchange)
        async -> Data?
    {
        guard !stdin.isEmpty, stdin.count <= AgentTaskApprovalFrame.maximumBodyBytes else { return nil }
        let request = AgentTaskApprovalRequest(
            provider: provider,
            requestID: AgentTaskApprovalRequest.identity(provider: provider, payload: stdin),
            payload: stdin)
        guard let body = try? JSONEncoder().encode(request),
              let frame = AgentTaskApprovalFrame.encode(body),
              let responseBody = await exchange(frame, AgentTaskApprovalSocketPath.currentUserPath),
              let response = try? JSONDecoder().decode(AgentTaskApprovalResponse.self, from: responseBody),
              response.requestID == request.requestID,
              let decision = response.decision
        else { return nil }
        return AgentTaskApprovalHookOutput.encode(decision, provider: provider)
    }
}

enum AgentTaskApprovalClient {
    /// Sends one framed request and waits for one framed reply.
    ///
    /// Two separate deadlines: a short one for reaching a running CodexBar, and a long one for the
    /// user actually deciding. Collapsing them into one would either make a missing app stall the
    /// agent, or give the user no time to answer.
    static func exchange(_ frame: Data, _ path: String) async -> Data? {
        #if canImport(Network)
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        return await withCheckedContinuation { continuation in
            let box = AgentTaskApprovalExchange(continuation: continuation, connection: connection)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.markConnected()
                    connection.send(
                        content: frame,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { error in
                            if error != nil { box.finish(nil) } else { box.receive() }
                        })
                case .failed, .cancelled:
                    box.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.steipete.codexbar.agent-approval-client"))

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + AgentTaskApprovalTimeouts.connectSeconds)
            {
                box.failIfNotConnected()
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + AgentTaskApprovalTimeouts.decisionSeconds)
            {
                box.finish(nil)
            }
        }
        #else
        return nil
        #endif
    }
}

#if canImport(Network)
/// Serialises completion so a timeout racing a reply can only resume the continuation once.
private final class AgentTaskApprovalExchange: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var connected = false
    private var buffer = Data()
    private let connection: NWConnection

    init(continuation: CheckedContinuation<Data?, Never>, connection: NWConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func markConnected() {
        self.lock.lock()
        self.connected = true
        self.lock.unlock()
    }

    func failIfNotConnected() {
        self.lock.lock()
        let connected = self.connected
        self.lock.unlock()
        if !connected { self.finish(nil) }
    }

    func receive() {
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, error in
            guard error == nil else {
                self.finish(nil)
                return
            }
            if let data, !data.isEmpty {
                self.lock.lock()
                self.buffer.append(data)
                let snapshot = self.buffer
                self.lock.unlock()
                switch AgentTaskApprovalFrame.decode(snapshot) {
                case let .body(body, _):
                    self.finish(body)
                    return
                case .oversized:
                    self.finish(nil)
                    return
                case .incomplete:
                    break
                }
            }
            if isComplete {
                self.finish(nil)
            } else {
                self.receive()
            }
        }
    }

    func finish(_ value: Data?) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        guard let continuation else { return }
        self.connection.cancel()
        continuation.resume(returning: value)
    }
}
#endif
