import Foundation

public enum HarnessTaskBridgeDocument {
    private static let begin = "\n# BEGIN com.steipete.codexbar.harness.v1\n"
    private static let end = "# END com.steipete.codexbar.harness.v1\n"

    public static func install(data: Data, pluginPath: String, socketPath: String, statePath: String) throws -> Data {
        let original = try self.remove(data: data)
        guard let text = String(data: original, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("["),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
        else { throw AgentTaskHookDocumentError.invalidRoot }
        let block = try """
        - insert:
            - id: vibe-island-harness-bridge
              name: \(self.quote(pluginPath))
              config:
                socketPath: \(self.quote(socketPath))
                statePath: \(self.quote(statePath))

        """
        return Data((text + self.begin + block + self.end).utf8)
    }

    public static func remove(data: Data) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw AgentTaskHookDocumentError.invalidRoot }
        guard let start = text.range(of: self.begin) else {
            guard !text.contains(self.end) else { throw AgentTaskHookDocumentError.invalidRoot }
            return data
        }
        guard let finish = text.range(of: self.end, range: start.upperBound..<text.endIndex),
              text.range(of: self.begin, range: start.upperBound..<text.endIndex) == nil
        else { throw AgentTaskHookDocumentError.invalidRoot }
        // Harness can move the end comment past unrelated root operations when saving YAML.
        let body = String(text[start.upperBound..<finish.lowerBound])
        let nextOperation = body.range(of: "\n- ")
        let ownedOperation = nextOperation.map { String(body[..<$0.lowerBound]) } ?? body
        guard ownedOperation.hasPrefix("- insert:\n"),
              ownedOperation.range(
                  of: #"(?m)^[ \t]+- id: vibe-island-harness-bridge[ \t]*$"#,
                  options: .regularExpression) != nil,
              ownedOperation.components(separatedBy: .newlines).count(where: {
                  $0.range(of: #"^[ \t]+- "#, options: .regularExpression) != nil
              }) == 1
        else { throw AgentTaskHookDocumentError.invalidRoot }
        let preserved = nextOperation.map { String(body[$0.lowerBound...]) } ?? ""
        var result = text
        result.replaceSubrange(start.lowerBound..<finish.upperBound, with: preserved)
        return Data(result.utf8)
    }

    public static func containsManagedBridge(_ data: Data) -> Bool {
        String(data: data, encoding: .utf8)?.contains(self.begin) == true
    }

    private static func quote(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        guard let result = String(data: data, encoding: .utf8) else { throw AgentTaskHookDocumentError.invalidRoot }
        return result
    }
}
