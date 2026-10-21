import CodexBarCore
import Foundation
import Testing

private func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

private func decisionBody(_ data: Data) -> [String: Any] {
    let root = json(data)
    let specific = root["hookSpecificOutput"] as? [String: Any] ?? [:]
    return specific["decision"] as? [String: Any] ?? [:]
}

private let suggestions = Data("""
[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test"}],\
"behavior":"allow","destination":"localSettings"}]
""".utf8)

struct AgentTaskApprovalHookOutputTests {
    @Test
    func `both agents receive the same envelope shape`() throws {
        for provider in [AgentTaskProvider.codex, .claude] {
            let data = try #require(AgentTaskApprovalHookOutput.encode(.allowedOnce, provider: provider))
            let specific = try #require(json(data)["hookSpecificOutput"] as? [String: Any])
            #expect(specific["hookEventName"] as? String == "PermissionRequest")
            #expect((specific["decision"] as? [String: Any])?["behavior"] as? String == "allow")
        }
    }

    @Test
    func `Harness offers no island approval actions or hook decision output`() {
        #expect(AgentTaskApprovalCapability.actions(
            provider: .deepseekHarness,
            hasPermissionSuggestions: true).isEmpty)
        #expect(AgentTaskApprovalHookOutput.encode(.allowedOnce, provider: .deepseekHarness) == nil)
    }

    @Test
    func `deny carries its reason back to the agent`() throws {
        let data = try #require(AgentTaskApprovalHookOutput.encode(
            .denied(message: "Blocked from the island"),
            provider: .claude))

        let body = decisionBody(data)
        #expect(body["behavior"] as? String == "deny")
        #expect(body["message"] as? String == "Blocked from the island")
    }

    @Test
    func `claude allow-all echoes the permission suggestion`() throws {
        let data = try #require(AgentTaskApprovalHookOutput.encode(
            .allowedAlways(suggestion: suggestions),
            provider: .claude))

        let entries = try #require(decisionBody(data)["updatedPermissions"] as? [[String: Any]])
        #expect(entries.count == 1)
        #expect(entries[0]["type"] as? String == "addRules")
        #expect(entries[0]["destination"] as? String == "localSettings")
    }

    /// The important one. On Codex these fields are reserved and fail closed: sending one makes
    /// Codex mark the hook run as failed and continue the tool call, which would silently turn a
    /// deliberate "Allow All" into a plain allow.
    @Test
    func `codex never receives reserved permission fields`() throws {
        let always = try #require(AgentTaskApprovalHookOutput.encode(
            .allowedAlways(suggestion: suggestions),
            provider: .codex))
        let bypass = try #require(AgentTaskApprovalHookOutput.encode(.bypassed, provider: .codex))

        for data in [always, bypass] {
            let body = decisionBody(data)
            #expect(body["updatedPermissions"] == nil)
            #expect(body["updatedInput"] == nil)
            #expect(body["interrupt"] == nil)
            #expect(body["behavior"] as? String == "allow")
        }
    }

    @Test
    func `claude bypass switches the session permission mode`() throws {
        let data = try #require(AgentTaskApprovalHookOutput.encode(.bypassed, provider: .claude))

        let entries = try #require(decisionBody(data)["updatedPermissions"] as? [[String: Any]])
        #expect(entries[0]["type"] as? String == "setMode")
        #expect(entries[0]["mode"] as? String == "bypassPermissions")
    }

    @Test
    func `a message never rides along with an allow`() throws {
        let decision = AgentTaskApprovalDecision(behavior: .allow, message: "ignored")
        let data = try #require(AgentTaskApprovalHookOutput.encode(decision, provider: .claude))

        #expect(decisionBody(data)["message"] == nil)
    }
}

struct AgentTaskApprovalCapabilityTests {
    @Test
    func `codex offers only the two actions it can honour`() {
        #expect(AgentTaskApprovalCapability.actions(provider: .codex, hasPermissionSuggestions: true)
            == [.deny, .allowOnce])
        #expect(!AgentTaskApprovalCapability.supports(.allowAlways, provider: .codex))
        #expect(!AgentTaskApprovalCapability.supports(.bypass, provider: .codex))
    }

    @Test
    func `allow-all appears only when the agent suggested a rule`() {
        #expect(AgentTaskApprovalCapability.actions(provider: .claude, hasPermissionSuggestions: true)
            == [.deny, .allowOnce, .allowAlways, .bypass])
        #expect(AgentTaskApprovalCapability.actions(provider: .claude, hasPermissionSuggestions: false)
            == [.deny, .allowOnce, .bypass])
    }
}

struct AgentTaskApprovalFrameTests {
    @Test
    func `a frame round-trips and reports trailing bytes`() throws {
        let body = Data("{\"a\":1}".utf8)
        let frame = try #require(AgentTaskApprovalFrame.encode(body))
        let trailing = Data([0xAA, 0xBB])

        guard case let .body(decoded, remainder) = AgentTaskApprovalFrame.decode(frame + trailing) else {
            Issue.record("expected a complete body")
            return
        }
        #expect(decoded == body)
        #expect(remainder == trailing)
    }

    @Test
    func `partial frames wait for more bytes instead of failing`() throws {
        let frame = try #require(AgentTaskApprovalFrame.encode(Data("hello".utf8)))

        #expect(AgentTaskApprovalFrame.decode(Data()) == .incomplete)
        #expect(AgentTaskApprovalFrame.decode(frame.prefix(3)) == .incomplete)
        #expect(AgentTaskApprovalFrame.decode(frame.prefix(frame.count - 1)) == .incomplete)
    }

    @Test
    func `an oversized announced length is refused rather than buffered`() {
        var frame = Data([0xFF, 0xFF, 0xFF, 0xFF])
        frame.append(Data("x".utf8))

        #expect(AgentTaskApprovalFrame.decode(frame) == .oversized)
        #expect(AgentTaskApprovalFrame.encode(Data(count: AgentTaskApprovalFrame.maximumBodyBytes + 1)) == nil)
    }
}

struct AgentTaskApprovalPayloadTests {
    private func payload(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    @Test
    func `permission request payload keeps the fields telemetry throws away`() throws {
        let data = try self.payload([
            "hook_event_name": "PermissionRequest",
            "session_id": "abc123",
            "cwd": "/Users/dev/api-server",
            "permission_mode": "default",
            "tool_name": "Bash",
            "tool_input": ["command": "rm -rf node_modules", "description": "Remove node_modules"],
            "permission_suggestions": [[
                "type": "addRules",
                "rules": [["toolName": "Bash"]],
                "behavior": "allow",
                "destination": "localSettings",
            ]],
        ])

        let parsed = try #require(AgentTaskApprovalPayload(hookPayload: data))
        #expect(parsed.sessionID == "abc123")
        #expect(parsed.toolName == "Bash")
        #expect(parsed.toolSummary == "rm -rf node_modules")
        #expect(parsed.projectPath == "/Users/dev/api-server")
        #expect(parsed.hasPermissionSuggestions)
    }

    @Test
    func `a payload without suggestions still parses`() throws {
        let data = try self.payload([
            "hook_event_name": "PermissionRequest",
            "session_id": "s",
            "tool_name": "apply_patch",
            "tool_input": ["file_path": "/tmp/a.ts"],
        ])

        let parsed = try #require(AgentTaskApprovalPayload(hookPayload: data))
        #expect(parsed.toolSummary == "/tmp/a.ts")
        #expect(!parsed.hasPermissionSuggestions)
    }

    @Test
    func `other hook events are not treated as permission requests`() throws {
        let data = try self.payload([
            "hook_event_name": "PostToolUse",
            "session_id": "s",
            "tool_name": "Bash",
        ])

        #expect(AgentTaskApprovalPayload(hookPayload: data) == nil)
        #expect(AgentTaskApprovalPayload(hookPayload: Data("not json".utf8)) == nil)
    }

    @Test
    func `identity is stable per payload so a retry reuses one card`() throws {
        let a = try self.payload(["hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "Bash"])

        #expect(AgentTaskApprovalRequest.identity(provider: .claude, payload: a)
            == AgentTaskApprovalRequest.identity(provider: .claude, payload: a))
        #expect(AgentTaskApprovalRequest.identity(provider: .claude, payload: a)
            != AgentTaskApprovalRequest.identity(provider: .codex, payload: a))
    }
}

struct AgentTaskApprovalHookDocumentTests {
    private func handlers(_ data: Data, event: String) -> [[String: Any]] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        let groups = hooks[event] as? [[String: Any]] ?? []
        return groups.compactMap { $0["hooks"] as? [[String: Any]] }.flatMap(\.self)
    }

    /// With approvals off the document must stay byte-for-byte what it was before this feature,
    /// so enabling nothing changes nothing about the user's live agents.
    @Test
    func `approvals off keeps every event fire-and-forget`() throws {
        let installed = try AgentTaskHookDocument.install(
            provider: .claude,
            data: Data(),
            helperPath: "/tmp/codexbar")

        for event in AgentTaskHookDocument.claudeEvents {
            let handler = try #require(self.handlers(installed, event: event).first)
            #expect(handler["async"] as? Bool == true)
            #expect(handler["timeout"] as? Int == 1)
            #expect((handler["command"] as? String)?.contains("agent-event") == true)
        }
    }

    @Test
    func `approvals on makes only PermissionRequest synchronous`() throws {
        let installed = try AgentTaskHookDocument.install(
            provider: .claude,
            data: Data(),
            helperPath: "/tmp/codexbar",
            approvalsEnabled: true)

        let approval = try #require(
            self.handlers(installed, event: AgentTaskHookDocument.permissionRequestEvent).first)
        #expect(approval["async"] == nil)
        #expect(approval["timeout"] as? Int == AgentTaskApprovalTimeouts.hookTimeoutSeconds)
        #expect((approval["command"] as? String)?.contains("agent-approval") == true)

        // Everything else must stay async, or ordinary tool calls would start waiting on us.
        for event in AgentTaskHookDocument.claudeEvents
            where event != AgentTaskHookDocument.permissionRequestEvent
        {
            let handler = try #require(self.handlers(installed, event: event).first)
            #expect(handler["async"] as? Bool == true)
        }
    }

    @Test
    func `the hook timeout outlives the decision timeout`() {
        #expect(Double(AgentTaskApprovalTimeouts.hookTimeoutSeconds)
            > AgentTaskApprovalTimeouts.decisionSeconds)
    }

    @Test
    func `toggling the setting marks the installed document repairable`() throws {
        let telemetryOnly = try AgentTaskHookDocument.install(
            provider: .codex,
            data: Data(),
            helperPath: "/tmp/codexbar")
        let withApprovals = try AgentTaskHookDocument.install(
            provider: .codex,
            data: Data(),
            helperPath: "/tmp/codexbar",
            approvalsEnabled: true)

        #expect(AgentTaskHookDocument.inspect(provider: .codex, data: telemetryOnly) == .installed)
        #expect(AgentTaskHookDocument.inspect(
            provider: .codex,
            data: telemetryOnly,
            approvalsEnabled: true) == .needsRepair)
        #expect(AgentTaskHookDocument.inspect(
            provider: .codex,
            data: withApprovals,
            approvalsEnabled: true) == .installed)
        #expect(AgentTaskHookDocument.inspect(provider: .codex, data: withApprovals) == .needsRepair)
    }

    /// Regression: approval-mode drift used to make `inspect` report `needsRepair`, and the island
    /// keyed its very existence off `== .installed` — so a stale approval handler made the whole
    /// surface disappear rather than just prompting for a repair.
    @Test
    func `mode drift still counts as installed hooks`() throws {
        let withApprovals = try AgentTaskHookDocument.install(
            provider: .claude,
            data: Data(),
            helperPath: "/tmp/codexbar",
            approvalsEnabled: true)

        #expect(AgentTaskHookDocument.inspect(provider: .claude, data: withApprovals) == .needsRepair)
        #expect(AgentTaskHookDocument.hasManagedHooks(provider: .claude, data: withApprovals))
        #expect(!AgentTaskHookDocument.hasManagedHooks(provider: .claude, data: Data()))
    }

    @Test
    func `uninstall removes the approval handler too`() throws {
        let installed = try AgentTaskHookDocument.install(
            provider: .codex,
            data: Data(),
            helperPath: "/tmp/codexbar",
            approvalsEnabled: true)
        let removed = try AgentTaskHookDocument.uninstall(provider: .codex, data: installed)

        #expect(AgentTaskHookDocument.inspect(
            provider: .codex,
            data: removed,
            approvalsEnabled: true) == .notInstalled)
    }
}
