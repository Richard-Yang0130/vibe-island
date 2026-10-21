import Foundation

public enum AgentTaskHookDocumentStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case needsRepair
}

public enum AgentTaskHookDocumentError: Error {
    case invalidRoot
}

public enum AgentTaskHookDocument {
    public static let ownerMarker = "com.steipete.codexbar.task-status.v1"
    public static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd",
    ]
    public static let claudeEvents = codexEvents + ["StopFailure"]

    public static let permissionRequestEvent = "PermissionRequest"

    public static func command(helperPath: String, provider: AgentTaskProvider) -> String {
        "\(self.shellQuote(helperPath)) agent-event --provider \(provider.rawValue) --managed-by \(self.ownerMarker)"
    }

    /// The blocking variant, registered only when the user opts into island approvals.
    public static func approvalCommand(helperPath: String, provider: AgentTaskProvider) -> String {
        "\(self.shellQuote(helperPath)) agent-approval --provider \(provider.rawValue) --managed-by \(self.ownerMarker)"
    }

    /// The handler written for one event.
    ///
    /// Every event except `PermissionRequest` stays fire-and-forget telemetry: `async` so it can
    /// never delay a tool call. `PermissionRequest` has to run synchronously, because both agents
    /// document that a background hook cannot approve or deny anything — registering it as `async`
    /// is exactly why approvals did not work before.
    static func handler(
        event: String,
        helperPath: String,
        provider: AgentTaskProvider,
        approvalsEnabled: Bool)
        -> [String: Any]
    {
        guard approvalsEnabled, event == self.permissionRequestEvent else {
            return [
                "type": "command",
                "command": self.command(helperPath: helperPath, provider: provider),
                "timeout": 1,
                "async": true,
            ]
        }
        return [
            "type": "command",
            "command": self.approvalCommand(helperPath: helperPath, provider: provider),
            "timeout": AgentTaskApprovalTimeouts.hookTimeoutSeconds,
        ]
    }

    public static func install(
        provider: AgentTaskProvider,
        data: Data,
        helperPath: String,
        approvalsEnabled: Bool = false)
        throws -> Data
    {
        guard provider != .deepseekHarness else { throw AgentTaskHookDocumentError.invalidRoot }
        var root = try self.root(from: data)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in self.events(for: provider) {
            var groups = self.removingManagedHandlers(from: hooks[event] as? [[String: Any]] ?? [])
            groups.append([
                "matcher": "",
                "hooks": [self.handler(
                    event: event,
                    helperPath: helperPath,
                    provider: provider,
                    approvalsEnabled: approvalsEnabled)],
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    public static func uninstall(provider _: AgentTaskProvider, data: Data) throws -> Data {
        var root = try self.root(from: data)
        guard var hooks = root["hooks"] as? [String: Any] else { return data }
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let cleaned = self.removingManagedHandlers(from: groups)
            if cleaned.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = cleaned
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Whether our managed handlers are present at all, ignoring which mode `PermissionRequest`
    /// is in.
    ///
    /// Approval-mode drift is a repair prompt, not a reason to consider the hooks missing: the
    /// telemetry handlers still work, so status lights and quota must keep rendering.
    public static func hasManagedHooks(provider: AgentTaskProvider, data: Data) -> Bool {
        guard provider != .deepseekHarness,
              let root = try? self.root(from: data),
              let hooks = root["hooks"] as? [String: Any]
        else { return false }
        return self.events(for: provider).allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains(where: self.isManagedHandler) == true
            }
        }
    }

    public static func inspect(
        provider: AgentTaskProvider,
        data: Data,
        approvalsEnabled: Bool = false) -> AgentTaskHookDocumentStatus
    {
        guard provider != .deepseekHarness else { return .notInstalled }
        guard let root = try? self.root(from: data),
              let hooks = root["hooks"] as? [String: Any]
        else { return .notInstalled }

        let events = self.events(for: provider)
        var approvalModeMatches = true
        let installed = events.filter { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            let handlers = groups.compactMap { $0["hooks"] as? [[String: Any]] }.flatMap(\.self)
            let managed = handlers.filter(self.isManagedHandler)
            guard !managed.isEmpty else { return false }
            // Toggling the approvals setting changes the PermissionRequest handler in place, so a
            // document installed under the other mode has to report as repairable rather than
            // silently keeping the stale (and, for approvals, non-functional) handler.
            if event == self.permissionRequestEvent,
               managed.contains(where: self.isApprovalHandler) != approvalsEnabled
            {
                approvalModeMatches = false
            }
            return true
        }
        if installed.isEmpty { return .notInstalled }
        guard installed.count == events.count, approvalModeMatches else { return .needsRepair }
        return .installed
    }

    private static func removingManagedHandlers(from groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { original in
            guard var handlers = original["hooks"] as? [[String: Any]] else { return original }
            handlers.removeAll(where: self.isManagedHandler)
            guard !handlers.isEmpty else { return nil }
            var group = original
            group["hooks"] = handlers
            return group
        }
    }

    private static func isManagedHandler(_ handler: [String: Any]) -> Bool {
        guard let command = handler["command"] as? String else { return false }
        let tokens = command.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard tokens.contains("agent-event") || tokens.contains("agent-approval"),
              let markerIndex = tokens.firstIndex(of: "--managed-by"),
              tokens.indices.contains(markerIndex + 1)
        else { return false }
        return tokens[markerIndex + 1] == self.ownerMarker
    }

    /// True when the handler is the blocking approval variant rather than telemetry.
    private static func isApprovalHandler(_ handler: [String: Any]) -> Bool {
        guard let command = handler["command"] as? String else { return false }
        return command.split(whereSeparator: \Character.isWhitespace).map(String.init)
            .contains("agent-approval")
    }

    private static func root(from data: Data) throws -> [String: Any] {
        if data.isEmpty { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentTaskHookDocumentError.invalidRoot
        }
        return root
    }

    private static func events(for provider: AgentTaskProvider) -> [String] {
        provider == .codex ? self.codexEvents : self.claudeEvents
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
