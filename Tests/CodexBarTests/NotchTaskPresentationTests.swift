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
        (AgentTaskStatus.idle, NotchLightMotion.staticDim),
        (.running, .breathe),
        (.needsApproval, .doublePulse),
        (.completed, .completionPulse),
        (.failed, .triplePulse),
        (.interrupted, .interruptedPulse),
    ])
    func `task status maps to one stable light motion`(
        _ status: AgentTaskStatus,
        _ motion: NotchLightMotion)
    {
        #expect(NotchLightPresentation.make(
            provider: .codex,
            status: status,
            isConfigured: true).motion == motion)
    }

    @Test
    func `unconfigured provider light is off`() {
        #expect(NotchLightPresentation.make(
            provider: .claude,
            status: .idle,
            isConfigured: false).motion == .off)
    }

    @Test
    func `collapsed content always contains codex then claude and no text`() {
        let presentation = NotchCollapsedPresentation.make(codex: .running, claude: .idle)

        #expect(presentation.lights.map(\.provider) == [.codex, .claude])
        #expect(presentation.visibleText.isEmpty)
    }
}
