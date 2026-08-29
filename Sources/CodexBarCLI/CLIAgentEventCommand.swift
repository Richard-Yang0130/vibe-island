import CodexBarCore
import Commander
import Foundation

#if canImport(Network)
import Network
#endif

struct AgentEventOptions: CommanderParsable {
    @Option(name: .long("provider"), help: "codex | claude")
    var provider: String?

    @Option(name: .long("managed-by"), help: "Internal hook owner marker")
    var managedBy: String?
}

extension CodexBarCLI {
    static let agentTaskHookOwnerMarker = "com.steipete.codexbar.task-status.v1"

    static func runAgentEvent(_ values: ParsedValues) async {
        guard values.options["managedBy"]?.last == self.agentTaskHookOwnerMarker,
              let rawProvider = values.options["provider"]?.last,
              let provider = AgentTaskProvider(rawValue: rawProvider)
        else { return }

        let stdin = FileHandle.standardInput.readData(
            ofLength: AgentTaskWireEnvelope.maximumPayloadBytes + 1)
        _ = await self.forwardAgentEvent(provider: provider, stdin: stdin)
    }

    static func forwardAgentEvent(
        provider: AgentTaskProvider,
        stdin: Data,
        send: @escaping @Sendable (Data, String) async -> Bool = AgentTaskBridgeClient.send)
        async -> Bool
    {
        guard AgentTaskWireEnvelope.acceptsPayload(stdin),
              let encoded = try? JSONEncoder().encode(AgentTaskWireEnvelope(
                  schemaVersion: AgentTaskWireEnvelope.currentSchemaVersion,
                  provider: provider,
                  payload: stdin))
        else { return true }

        _ = await send(encoded, AgentTaskSocketPath.currentUserPath)
        return true
    }
}

enum AgentTaskBridgeClient {
    static func send(_ data: Data, _ path: String) async -> Bool {
        #if canImport(Network)
        let connection = NWConnection(to: .unix(path: path), using: .tcp)
        return await withCheckedContinuation { continuation in
            let completion = AgentTaskBridgeSendCompletion(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: data,
                        contentContext: .defaultMessage,
                        isComplete: true,
                        completion: .contentProcessed { error in
                            completion.finish(error == nil)
                            connection.cancel()
                        })
                case .failed, .cancelled:
                    completion.finish(false)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "com.steipete.codexbar.agent-task-client"))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(250)) {
                completion.finish(false)
                connection.cancel()
            }
        }
        #else
        return false
        #endif
    }
}

#if canImport(Network)
private final class AgentTaskBridgeSendCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ result: Bool) {
        self.lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(returning: result)
    }
}
#endif
