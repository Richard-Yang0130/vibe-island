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

    public static func command(helperPath: String, provider: AgentTaskProvider) -> String {
        "\(self.shellQuote(helperPath)) agent-event --provider \(provider.rawValue) --managed-by \(self.ownerMarker)"
    }

    public static func install(
        provider: AgentTaskProvider,
        data: Data,
        helperPath: String)
        throws -> Data
    {
        var root = try self.root(from: data)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command = self.command(helperPath: helperPath, provider: provider)
        for event in self.events(for: provider) {
            var groups = self.removingManagedHandlers(from: hooks[event] as? [[String: Any]] ?? [])
            groups.append([
                "matcher": "",
                "hooks": [[
                    "type": "command",
                    "command": command,
                    "timeout": 1,
                    "async": true,
                ]],
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

    public static func inspect(
        provider: AgentTaskProvider,
        data: Data) -> AgentTaskHookDocumentStatus
    {
        guard let root = try? self.root(from: data),
              let hooks = root["hooks"] as? [String: Any]
        else { return .notInstalled }

        let events = self.events(for: provider)
        let installed = events.filter { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains { group in
                (group["hooks"] as? [[String: Any]])?.contains(where: self.isManagedHandler) == true
            }
        }
        if installed.isEmpty { return .notInstalled }
        return installed.count == events.count ? .installed : .needsRepair
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
        guard tokens.contains("agent-event"),
              let markerIndex = tokens.firstIndex(of: "--managed-by"),
              tokens.indices.contains(markerIndex + 1)
        else { return false }
        return tokens[markerIndex + 1] == self.ownerMarker
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
