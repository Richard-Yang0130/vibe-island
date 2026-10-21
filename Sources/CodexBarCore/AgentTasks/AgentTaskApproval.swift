#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Crypto
import Foundation

// MARK: - Actions

/// What the island can offer for a pending permission request.
///
/// The set is provider-dependent; see `AgentTaskApprovalCapability`.
public enum AgentTaskApprovalAction: String, Codable, Sendable, CaseIterable {
    case deny
    case allowOnce
    case allowAlways
    case bypass
}

// MARK: - Decision

/// A decision the user made on the island, on its way back to the agent.
///
/// `updatedPermissionsJSON` carries an opaque JSON array that we echo back verbatim — it comes
/// from the agent's own `permission_suggestions`, so we never synthesise permission rules
/// ourselves.
public struct AgentTaskApprovalDecision: Codable, Equatable, Sendable {
    public enum Behavior: String, Codable, Sendable {
        case allow
        case deny
    }

    public let behavior: Behavior
    /// Deny only: tells the agent why.
    public let message: String?
    /// Allow only: JSON array echoed into `updatedPermissions`.
    public let updatedPermissionsJSON: Data?

    public init(behavior: Behavior, message: String? = nil, updatedPermissionsJSON: Data? = nil) {
        self.behavior = behavior
        self.message = message
        self.updatedPermissionsJSON = updatedPermissionsJSON
    }

    public static func denied(message: String? = nil) -> AgentTaskApprovalDecision {
        AgentTaskApprovalDecision(behavior: .deny, message: message)
    }

    public static let allowedOnce = AgentTaskApprovalDecision(behavior: .allow)

    public static func allowedAlways(suggestion: Data) -> AgentTaskApprovalDecision {
        AgentTaskApprovalDecision(behavior: .allow, updatedPermissionsJSON: suggestion)
    }

    /// Switches the session into bypass mode. Only takes effect when the session was launched with
    /// bypass available; otherwise the agent treats it as a no-op.
    public static var bypassed: AgentTaskApprovalDecision {
        let entry: [[String: Any]] = [["type": "setMode", "mode": "bypassPermissions", "destination": "session"]]
        let data = try? JSONSerialization.data(withJSONObject: entry)
        return AgentTaskApprovalDecision(behavior: .allow, updatedPermissionsJSON: data)
    }
}

// MARK: - Capability

/// Which actions a provider can actually honour.
///
/// This is not cosmetic gating. On Codex, `updatedInput` / `updatedPermissions` / `interrupt` are
/// reserved fields that **fail closed**: sending one makes Codex mark the hook run as failed and
/// continue the tool call. So an "Allow All" button on Codex would not merely be inert, it would
/// silently turn into "allow" — worse than not offering it.
public enum AgentTaskApprovalCapability {
    public static func actions(
        provider: AgentTaskProvider,
        hasPermissionSuggestions: Bool)
        -> [AgentTaskApprovalAction]
    {
        switch provider {
        case .codex:
            [.deny, .allowOnce]
        case .claude:
            hasPermissionSuggestions
                ? [.deny, .allowOnce, .allowAlways, .bypass]
                : [.deny, .allowOnce, .bypass]
        case .deepseekHarness:
            []
        }
    }

    public static func supports(_ action: AgentTaskApprovalAction, provider: AgentTaskProvider) -> Bool {
        switch provider {
        case .codex: action == .deny || action == .allowOnce
        case .claude: true
        case .deepseekHarness: false
        }
    }

    /// Turns the button the user pressed into a decision for this provider.
    ///
    /// Downgrades rather than fails: an action the provider cannot express, or an "Allow All" with
    /// no suggestion to echo, becomes a plain one-shot allow. The user asked to proceed, so the
    /// safe reading of a missing capability is "allow once", never "allow more than asked".
    public static func decision(
        for action: AgentTaskApprovalAction,
        provider: AgentTaskProvider,
        permissionSuggestionsJSON: Data?,
        denyMessage: String?)
        -> AgentTaskApprovalDecision
    {
        switch action {
        case .deny:
            return .denied(message: denyMessage)
        case .allowOnce:
            return .allowedOnce
        case .allowAlways:
            guard self.supports(.allowAlways, provider: provider),
                  let permissionSuggestionsJSON
            else { return .allowedOnce }
            return .allowedAlways(suggestion: permissionSuggestionsJSON)
        case .bypass:
            guard self.supports(.bypass, provider: provider) else { return .allowedOnce }
            return .bypassed
        }
    }
}

// MARK: - Hook output

public enum AgentTaskApprovalHookOutput {
    /// Serialises a decision into the JSON the agent reads from the hook's stdout.
    ///
    /// Both agents accept the same envelope shape; only the decision fields differ. Fields the
    /// provider cannot honour are dropped here rather than relying on the far side to ignore
    /// unknown keys — on Codex, an unknown key is a hook failure, not a no-op.
    public static func encode(
        _ decision: AgentTaskApprovalDecision,
        provider: AgentTaskProvider)
        -> Data?
    {
        guard provider != .deepseekHarness else { return nil }
        var body: [String: Any] = ["behavior": decision.behavior.rawValue]

        if decision.behavior == .deny, let message = decision.message, !message.isEmpty {
            body["message"] = message
        }

        if decision.behavior == .allow,
           AgentTaskApprovalCapability.supports(.allowAlways, provider: provider),
           let json = decision.updatedPermissionsJSON,
           let entries = try? JSONSerialization.jsonObject(with: json) as? [[String: Any]],
           !entries.isEmpty
        {
            body["updatedPermissions"] = entries
        }

        let root: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": body,
            ],
        ]
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

// MARK: - Request payload

/// The parts of a `PermissionRequest` hook payload the island needs.
///
/// `PreToolUse` and `PermissionRequest` both deliver `tool_name` and `tool_input`; the telemetry
/// normalizer throws them away because it only builds status lights. Approvals need them.
public struct AgentTaskApprovalPayload: Equatable, Sendable {
    public let sessionID: String
    public let toolName: String
    /// Human-readable command or target, when the agent supplied one.
    public let toolSummary: String?
    public let projectPath: String?
    public let permissionMode: String?
    /// Opaque JSON array of "always allow" options the agent offered, echoed back verbatim.
    public let permissionSuggestionsJSON: Data?

    public var hasPermissionSuggestions: Bool {
        self.permissionSuggestionsJSON != nil
    }

    public init?(hookPayload: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: hookPayload) as? [String: Any],
              (object["hook_event_name"] as? String) == "PermissionRequest",
              let sessionID = Self.nonEmpty(object["session_id"]),
              let toolName = Self.nonEmpty(object["tool_name"])
        else { return nil }

        self.sessionID = sessionID
        self.toolName = toolName
        self.projectPath = Self.nonEmpty(object["cwd"])
        self.permissionMode = Self.nonEmpty(object["permission_mode"])

        let input = object["tool_input"] as? [String: Any]
        // Bash and apply_patch both put the operative text in `command`; Claude adds a
        // human-readable `description` for the approval reason.
        self.toolSummary = Self.nonEmpty(input?["command"])
            ?? Self.nonEmpty(input?["description"])
            ?? Self.nonEmpty(input?["file_path"])

        if let suggestions = object["permission_suggestions"] as? [[String: Any]],
           !suggestions.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: suggestions)
        {
            self.permissionSuggestionsJSON = data
        } else {
            self.permissionSuggestionsJSON = nil
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Wire

public struct AgentTaskApprovalRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let provider: AgentTaskProvider
    public let requestID: String
    public let payload: Data

    public init(provider: AgentTaskProvider, requestID: String, payload: Data) {
        self.schemaVersion = Self.currentSchemaVersion
        self.provider = provider
        self.requestID = requestID
        self.payload = payload
    }

    /// Stable identity for one pending request, so a retried or duplicated hook invocation reuses
    /// the card already on the island instead of stacking a second one.
    public static func identity(provider: AgentTaskProvider, payload: Data) -> String {
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        return "\(provider.rawValue):\(digest)"
    }
}

public struct AgentTaskApprovalResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: String
    /// `nil` means "no decision" — the helper stays silent and the agent runs its normal flow.
    public let decision: AgentTaskApprovalDecision?

    public init(requestID: String, decision: AgentTaskApprovalDecision?) {
        self.schemaVersion = AgentTaskApprovalRequest.currentSchemaVersion
        self.requestID = requestID
        self.decision = decision
    }
}

public struct AgentTaskApprovalAcknowledgement: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let requestID: String

    public init(requestID: String) {
        self.schemaVersion = Self.currentSchemaVersion
        self.requestID = requestID
    }
}

/// Length-prefixed framing: 4-byte big-endian length, then the JSON body.
///
/// The telemetry socket infers message boundaries from the client closing the connection, which
/// cannot work when the client has to stay around for a reply. Hence explicit framing here.
public enum AgentTaskApprovalFrame {
    public static let maximumBodyBytes = 128 * 1024

    public static func encode(_ body: Data) -> Data? {
        guard body.count <= self.maximumBodyBytes else { return nil }
        var frame = Data(capacity: body.count + 4)
        let length = UInt32(body.count)
        frame.append(UInt8((length >> 24) & 0xFF))
        frame.append(UInt8((length >> 16) & 0xFF))
        frame.append(UInt8((length >> 8) & 0xFF))
        frame.append(UInt8(length & 0xFF))
        frame.append(body)
        return frame
    }

    public enum DecodeResult: Equatable {
        /// Need more bytes before a body can be read.
        case incomplete
        /// A complete body, plus whatever bytes followed it.
        case body(Data, remainder: Data)
        /// The stream announced a body we refuse to buffer; the caller must drop the connection.
        case oversized
    }

    public static func decode(_ buffer: Data) -> DecodeResult {
        guard buffer.count >= 4 else { return .incomplete }
        let bytes = [UInt8](buffer.prefix(4))
        let length = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        guard length <= UInt32(self.maximumBodyBytes) else { return .oversized }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return .incomplete }
        return .body(
            buffer.subdata(in: 4..<total),
            remainder: buffer.subdata(in: total..<buffer.count))
    }
}

public enum AgentTaskApprovalSocketPath {
    public static func path(uid: UInt32) -> String {
        AgentTaskSocketSecurity.path(uid: uid, fileName: "approval.sock")
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

// MARK: - Timeouts

public enum AgentTaskApprovalTimeouts {
    /// Connecting to a running CodexBar. Missing app must fail fast so the agent is not delayed.
    public static let connectSeconds: Double = 0.25
    /// How long the island waits for the user.
    public static let decisionSeconds: Double = 60
    /// The helper must acknowledge a complete reply before the island reports delivery.
    public static let deliverySeconds: Double = 1
    /// What we write into the hook document. Must exceed `decisionSeconds` so the helper always
    /// exits on its own terms instead of being killed mid-write by the agent.
    public static let hookTimeoutSeconds: Int = 90
}
