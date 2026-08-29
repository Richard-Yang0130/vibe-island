import CodexBarCore
import Foundation
import Testing

struct AgentTaskHookDocumentTests {
    @Test
    func `install preserves unrelated settings and hooks`() throws {
        let input = Data(
            #"{"theme":"dark","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/other/hook"}]}]}}"#
                .utf8)

        let installed = try AgentTaskHookDocument.install(
            provider: .claude,
            data: input,
            helperPath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")

        let root = try #require(JSONSerialization.jsonObject(with: installed) as? [String: Any])
        #expect(root["theme"] as? String == "dark")
        #expect(AgentTaskHookDocument.inspect(provider: .claude, data: installed) == .installed)

        let hooks = try #require(root["hooks"] as? [String: Any])
        let stopGroups = try #require(hooks["Stop"] as? [[String: Any]])
        let unrelatedStillPresent = stopGroups.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains { handler in
                handler["command"] as? String == "/other/hook"
            } == true
        }
        #expect(unrelatedStillPresent)
    }

    @Test
    func `reinstall is idempotent`() throws {
        let first = try AgentTaskHookDocument.install(
            provider: .codex,
            data: Data(#"{}"#.utf8),
            helperPath: "/app/cli")
        let second = try AgentTaskHookDocument.install(
            provider: .codex,
            data: first,
            helperPath: "/app/cli")

        #expect(first == second)
    }

    @Test
    func `uninstall removes only precisely managed handlers`() throws {
        let unrelated = "echo " + AgentTaskHookDocument.ownerMarker
        let input: [String: Any] = [
            "hooks": ["Custom": [["hooks": [["type": "command", "command": unrelated]]]]],
        ]
        let installed = try AgentTaskHookDocument.install(
            provider: .codex,
            data: JSONSerialization.data(withJSONObject: input),
            helperPath: "/app/cli")

        let removed = try AgentTaskHookDocument.uninstall(provider: .codex, data: installed)
        let root = try self.jsonObject(removed)
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(hooks.keys.sorted() == ["Custom"])
        #expect(AgentTaskHookDocument.inspect(provider: .codex, data: removed) == .notInstalled)
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
