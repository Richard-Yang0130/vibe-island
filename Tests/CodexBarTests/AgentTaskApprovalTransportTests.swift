import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

private func permissionPayload(
    tool: String = "Bash",
    command: String = "rm -rf node_modules",
    suggestions: Bool = true)
    -> Data
{
    let hint = suggestions
        ? """
        ,"permission_suggestions":[{"type":"addRules",\
        "rules":[{"toolName":"\(tool)","ruleContent":"\(command)"}],\
        "behavior":"allow","destination":"localSettings"}]
        """
        : ""
    return Data("""
    {"hook_event_name":"PermissionRequest","session_id":"session-1",\
    "cwd":"/Users/dev/api-server","tool_name":"\(tool)",\
    "tool_input":{"command":"\(command)"}\(hint)}
    """.utf8)
}

private func socketPath() -> String {
    // Unix socket paths are length-limited, so keep this short rather than using the long
    // per-test temporary directory.
    "/tmp/cbx-approval-test-\(UInt32.random(in: 0..<UInt32.max)).sock"
}

struct AgentTaskApprovalDecisionMappingTests {
    @Test
    func `each button maps to the decision it promises`() throws {
        let suggestion = permissionPayload()
        let parsed = try #require(AgentTaskApprovalPayload(hookPayload: suggestion))

        let deny = AgentTaskApprovalCapability.decision(
            for: .deny,
            provider: .claude,
            permissionSuggestionsJSON: parsed.permissionSuggestionsJSON,
            denyMessage: "no")
        let always = AgentTaskApprovalCapability.decision(
            for: .allowAlways,
            provider: .claude,
            permissionSuggestionsJSON: parsed.permissionSuggestionsJSON,
            denyMessage: nil)

        #expect(deny == .denied(message: "no"))
        #expect(always.behavior == .allow)
        #expect(always.updatedPermissionsJSON != nil)
    }

    /// Downgrading matters more than it looks: an unsupported action must never widen permissions
    /// beyond the single call the user was actually looking at.
    @Test
    func `unsupported actions degrade to a one-shot allow`() throws {
        let parsed = try #require(AgentTaskApprovalPayload(hookPayload: permissionPayload()))

        for action in [AgentTaskApprovalAction.allowAlways, .bypass] {
            let codex = AgentTaskApprovalCapability.decision(
                for: action,
                provider: .codex,
                permissionSuggestionsJSON: parsed.permissionSuggestionsJSON,
                denyMessage: nil)
            #expect(codex == .allowedOnce, "\(action) should degrade on Codex")
        }

        // Claude can do allow-all, but not when the agent offered nothing to echo.
        let withoutSuggestion = AgentTaskApprovalCapability.decision(
            for: .allowAlways,
            provider: .claude,
            permissionSuggestionsJSON: nil,
            denyMessage: nil)
        #expect(withoutSuggestion == .allowedOnce)
    }
}

@MainActor
struct AgentTaskApprovalStoreTests {
    @Test
    func `a disabled store answers nothing and shows nothing`() async {
        let store = AgentTaskApprovalStore()
        let request = AgentTaskApprovalRequest(
            provider: .claude,
            requestID: "r1",
            payload: permissionPayload())

        let decision = await store.handle(request)

        #expect(decision == nil)
        #expect(store.pending.isEmpty)
    }

    @Test
    func `a decision reaches the waiting hook`() async {
        let store = AgentTaskApprovalStore()
        store.isEnabled = true
        let request = AgentTaskApprovalRequest(
            provider: .claude,
            requestID: "r1",
            payload: permissionPayload())

        async let decision = store.handle(request)
        while store.pending.isEmpty {
            await Task.yield()
        }
        store.resolve(id: "r1", action: .deny)

        #expect(await decision?.behavior == .deny)
        #expect(store.pending.isEmpty)
    }

    @Test
    func `a duplicated hook invocation shares one card and one answer`() async {
        let store = AgentTaskApprovalStore()
        store.isEnabled = true
        let payload = permissionPayload()
        let id = AgentTaskApprovalRequest.identity(provider: .claude, payload: payload)
        let request = AgentTaskApprovalRequest(
            provider: .claude,
            requestID: id,
            payload: payload)

        async let first = store.handle(request)
        while store.pending.isEmpty {
            await Task.yield()
        }
        async let second = store.handle(request)
        #expect(store.pending.count == 1)
        store.resolve(id: id, action: .allowOnce)

        let results = await [first, second]
        #expect(results.allSatisfy { $0?.behavior == .allow })
    }

    /// A hook that fires again just after the user decided must inherit that decision instead of
    /// putting a second card on the island.
    @Test
    func `a retry inside the duplicate window reuses the decision`() async {
        let store = AgentTaskApprovalStore()
        store.isEnabled = true
        let payload = permissionPayload()
        let id = AgentTaskApprovalRequest.identity(provider: .claude, payload: payload)
        let request = AgentTaskApprovalRequest(
            provider: .claude,
            requestID: id,
            payload: payload)

        async let first = store.handle(request)
        while store.pending.isEmpty {
            await Task.yield()
        }
        store.resolve(id: id, action: .deny)
        _ = await first

        let retry = await store.handle(request)

        #expect(retry?.behavior == .deny)
        #expect(store.pending.isEmpty)
    }

    @Test
    func `the deadline releases the agent instead of blocking it forever`() async {
        let store = AgentTaskApprovalStore()
        store.isEnabled = true
        let request = AgentTaskApprovalRequest(
            provider: .claude,
            requestID: "r1",
            payload: permissionPayload())

        let decision = await store.handle(request, timeout: 0.05)

        #expect(decision == nil)
        #expect(store.pending.isEmpty)
    }

    @Test
    func `draining releases every blocked agent`() async {
        let store = AgentTaskApprovalStore()
        store.isEnabled = true
        let request = AgentTaskApprovalRequest(
            provider: .claude,
            requestID: "r1",
            payload: permissionPayload())

        async let decision = store.handle(request)
        while store.pending.isEmpty {
            await Task.yield()
        }
        store.drain()

        #expect(await decision == nil)
        #expect(store.pending.isEmpty)
    }

    @Test
    func `a non permission payload is ignored`() async throws {
        let store = AgentTaskApprovalStore()
        store.isEnabled = true
        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "Bash",
        ])
        let request = AgentTaskApprovalRequest(
            provider: .claude,
            requestID: "r1",
            payload: payload)

        #expect(await store.handle(request) == nil)
        #expect(store.pending.isEmpty)
    }
}

struct AgentTaskApprovalTransportTests {
    /// The real helper against the real server, over a real unix socket.
    @Test
    func `a decision travels from the island back to the hook stdout`() async throws {
        let path = socketPath()
        let server = AgentTaskApprovalServer(path: path) { request in
            #expect(request.provider == .claude)
            return .denied(message: "Denied from CodexBar")
        }
        try await server.start()
        defer { server.stop() }

        let output = await CodexBarCLI.resolveApproval(
            provider: .claude,
            stdin: permissionPayload(),
            exchange: { frame, _ in await AgentTaskApprovalClient.exchange(frame, path) })

        let data = try #require(output)
        let root = try #require(
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        let specific = try #require(root["hookSpecificOutput"] as? [String: Any])
        let decision = try #require(specific["decision"] as? [String: Any])
        #expect(specific["hookEventName"] as? String == "PermissionRequest")
        #expect(decision["behavior"] as? String == "deny")
        #expect(decision["message"] as? String == "Denied from CodexBar")
    }

    @Test
    func `no decision produces no stdout so the agent asks normally`() async throws {
        let path = socketPath()
        let server = AgentTaskApprovalServer(path: path) { _ in nil }
        try await server.start()
        defer { server.stop() }

        let output = await CodexBarCLI.resolveApproval(
            provider: .codex,
            stdin: permissionPayload(),
            exchange: { frame, _ in await AgentTaskApprovalClient.exchange(frame, path) })

        #expect(output == nil)
    }

    /// The most important failure path: CodexBar is not running. The helper has to give up inside
    /// the connect budget, otherwise every tool call in the user's agent stalls.
    @Test
    func `a missing app fails open quickly`() async {
        let started = Date()

        let output = await CodexBarCLI.resolveApproval(
            provider: .claude,
            stdin: permissionPayload(),
            exchange: { frame, _ in await AgentTaskApprovalClient.exchange(frame, socketPath()) })

        #expect(output == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test
    func `an empty or oversized payload is never sent`() async {
        let refuse: @Sendable (Data, String) async -> Data? = { _, _ in
            Issue.record("payload should have been rejected before any connection")
            return nil
        }

        #expect(await CodexBarCLI.resolveApproval(
            provider: .claude, stdin: Data(), exchange: refuse) == nil)
        #expect(await CodexBarCLI.resolveApproval(
            provider: .claude,
            stdin: Data(count: AgentTaskApprovalFrame.maximumBodyBytes + 1),
            exchange: refuse) == nil)
    }

    @Test
    func `a reply for a different request is discarded`() async {
        let mismatched: @Sendable (Data, String) async -> Data? = { _, _ in
            let response = AgentTaskApprovalResponse(requestID: "someone-else", decision: .allowedOnce)
            return try? JSONEncoder().encode(response)
        }

        let output = await CodexBarCLI.resolveApproval(
            provider: .claude, stdin: permissionPayload(), exchange: mismatched)

        #expect(output == nil)
    }
}
