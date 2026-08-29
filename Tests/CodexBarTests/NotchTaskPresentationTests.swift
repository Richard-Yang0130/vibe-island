import CodexBarCore
import Testing
@testable import CodexBar

struct NotchTaskPresentationTests {
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
