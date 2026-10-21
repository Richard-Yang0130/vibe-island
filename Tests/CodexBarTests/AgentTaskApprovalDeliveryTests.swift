import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct AgentTaskApprovalDeliveryTests {
    @Test(arguments: [true, false])
    func `a selection waits for the helper delivery result`(succeeded: Bool) async {
        let store = AgentTaskApprovalStore()
        store.isEnabled = true
        let request = self.request()
        let hook = Task { await store.handle(request) }
        while store.pending.isEmpty {
            await Task.yield()
        }
        var result: Bool?
        let submission = Task {
            let delivered = await store.submit(id: request.requestID, action: .allowOnce)
            result = delivered
            return delivered
        }
        #expect(await hook.value?.behavior == .allow)
        #expect(result == nil)

        store.reportDelivery(id: request.requestID, succeeded: succeeded)
        #expect(await submission.value == succeeded)
    }

    @Test
    func `a failed duplicate cannot hide a later helper acknowledgement`() async {
        let store = AgentTaskApprovalStore()
        store.isEnabled = true
        let request = self.request()
        let hook = Task { await store.handle(request) }
        while store.pending.isEmpty {
            await Task.yield()
        }
        var result: Bool?
        let submission = Task {
            let delivered = await store.submit(id: request.requestID, action: .allowOnce)
            result = delivered
            return delivered
        }
        _ = await hook.value
        store.reportDelivery(id: request.requestID, succeeded: false)
        await Task.yield()
        #expect(result == nil)

        store.reportDelivery(id: request.requestID, succeeded: true)
        #expect(await submission.value)
    }

    @Test
    func `an acknowledgement for another request cannot confirm a selection`() async {
        let store = AgentTaskApprovalStore()
        store.isEnabled = true
        let request = self.request()
        let hook = Task { await store.handle(request) }
        while store.pending.isEmpty {
            await Task.yield()
        }
        var result: Bool?
        let submission = Task {
            let delivered = await store.submit(id: request.requestID, action: .deny)
            result = delivered
            return delivered
        }
        #expect(await hook.value?.behavior == .deny)
        store.reportDelivery(id: "another-request", succeeded: true)
        await Task.yield()
        #expect(result == nil)

        store.reportDelivery(id: request.requestID, succeeded: true)
        #expect(await submission.value)
    }

    @Test
    func `draining releases a selection that is still awaiting delivery`() async {
        let store = AgentTaskApprovalStore()
        store.isEnabled = true
        let request = self.request()
        let hook = Task { await store.handle(request) }
        while store.pending.isEmpty {
            await Task.yield()
        }
        let submission = Task { await store.submit(id: request.requestID, action: .allowOnce) }
        _ = await hook.value

        store.drain()
        #expect(await submission.value == false)
    }

    private func request() -> AgentTaskApprovalRequest {
        AgentTaskApprovalRequest(
            provider: .claude,
            requestID: "delivery-test",
            payload: Data(
                (#"{"hook_event_name":"PermissionRequest","session_id":"synthetic","#
                    + #""tool_name":"Bash","tool_input":{"command":"echo synthetic"}}"#).utf8))
    }
}
