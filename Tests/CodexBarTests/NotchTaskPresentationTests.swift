import CodexBarCore
import Testing
@testable import CodexBar

struct NotchTaskPresentationTests {
    @Test
    @MainActor
    func `expanded detail puts task before quota`() throws {
        let task = try #require(AgentTaskAttention(event: .fixture(
            kind: .turnCompleted,
            provider: .codex,
            sessionID: "s1",
            turnID: "t1",
            title: "Implement status")))
        let plan = NotchTaskDetailPlan(
            attention: task,
            activeSession: nil,
            quota: NotchQuotaSummary(usedPercent: 52, resetText: "Resets in 2h"))

        #expect(plan.sections.map(\.kind) == [.event, .openTask, .quota])
        #expect(plan.eventTitle == "Implement status")
    }

    @Test
    func `only finite attention schedules automatic dismissal`() {
        #expect(NotchAttentionPolicy.dismissAfter(status: .completed) == 5)
        #expect(NotchAttentionPolicy.dismissAfter(status: .interrupted) == 5)
        #expect(NotchAttentionPolicy.dismissAfter(status: .needsApproval) == nil)
        #expect(NotchAttentionPolicy.dismissAfter(status: .failed) == nil)
    }

    @Test
    @MainActor
    func `manual expansion shows current running task before quota`() {
        let running = AgentTaskSessionState(
            provider: .claude,
            sessionID: "s1",
            turnID: "t1",
            status: .running,
            updatedAt: .now,
            projectPath: "/repo/CodexBar",
            transcriptPath: nil,
            taskTitle: nil)
        let plan = NotchTaskDetailPlan(
            attention: nil,
            activeSession: running,
            quota: NotchQuotaSummary(usedPercent: 34, resetText: "Resets in 3h"))

        #expect(plan.sections.map(\.kind) == [.event, .openTask, .quota])
        #expect(plan.eventTitle == "CodexBar")
    }

    @Test(arguments: [
        (AgentTaskStatus.idle, NotchIndicatorState.idle),
        (.running, .running),
        (.needsApproval, .attention),
        (.completed, .idle),
        (.failed, .attention),
        (.interrupted, .attention),
        (.disconnected, .attention),
    ])
    func `task status maps to one compact indicator state`(
        _ status: AgentTaskStatus,
        _ state: NotchIndicatorState)
    {
        #expect(NotchLightPresentation.make(
            provider: .codex,
            status: status,
            isConfigured: true,
            attention: nil).state == state)
    }

    @Test
    func `unconfigured provider light is off`() {
        #expect(NotchLightPresentation.make(
            provider: .claude,
            status: .idle,
            isConfigured: false,
            attention: nil).state == .hidden)
    }

    @Test
    func `collapsed content places Claude left and Codex right with approved colors`() {
        let presentation = NotchCollapsedPresentation.make(claude: .running, codex: .idle)

        #expect(presentation.lights.map(\.provider) == [.claude, .codex])
        #expect(presentation.lights.map(\.side) == [.left, .right])
        #expect(presentation.lights.map(\.color.rawValue) == ["#D97757", "#F5F5F5"])
        #expect(presentation.visibleText.isEmpty)
    }

    @Test
    func `matching attention lights only that provider edge`() throws {
        let attention = try #require(AgentTaskAttention(event: .fixture(
            kind: .approvalRequested,
            provider: .claude,
            sessionID: "s1",
            turnID: "t1")))
        let presentation = NotchCollapsedPresentation.make(
            claude: .running,
            codex: .running,
            attention: attention)

        #expect(presentation.lights[0].state == .attention)
        #expect(presentation.lights[0].showsEdgeGlow)
        #expect(presentation.lights[1].state == .running)
        #expect(!presentation.lights[1].showsEdgeGlow)
    }
}
