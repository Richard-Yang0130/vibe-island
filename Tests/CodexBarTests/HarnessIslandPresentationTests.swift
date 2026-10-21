import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct HarnessIslandPresentationTests {
    @Test(arguments: [AgentTaskStatus.running, .completed])
    @MainActor
    func `Harness cards retain their identity and completion affordance`(_ status: AgentTaskStatus) throws {
        let now = Date(timeIntervalSince1970: 1000)
        let session = AgentTaskSessionState(
            provider: .deepseekHarness,
            sessionID: "harness-task",
            turnID: "turn",
            status: status,
            updatedAt: now,
            projectPath: nil,
            transcriptPath: nil,
            taskTitle: nil)
        let content = IslandContent(
            card: nil,
            aggregates: [.deepseekHarness: AgentTaskProviderAggregate(
                provider: .deepseekHarness,
                status: status,
                sessions: [session])],
            attention: nil,
            hidePersonalInfo: false,
            now: now)
        let card = try #require(content.cards.first)
        #expect(content.sessionCount == 1)
        #expect(content.leadProvider == .deepseekHarness)
        #expect(card.provider == .deepseekHarness)
        #expect(card.title == "DeepSeek Harness")
        #expect(card.chips == ["DeepSeek Harness"])
        #expect(card.isJumpTarget == (status == .completed))
        #expect(IslandSprite.identity(for: card.provider) == .deepseekHarness)
        #expect(IslandSprite.identity(for: card.provider) != .claude)
        let plan = NotchTaskDetailPlan(attention: nil, activeSession: session, quota: nil)
        #expect(plan.providerName == "DeepSeek Harness")
    }

    @Test
    func `Harness whale uses its own eight pixel bitmap`() {
        let bitmap = IslandSprite.identity(for: .deepseekHarness).bitmap
        #expect(bitmap.count == 8)
        #expect(bitmap.allSatisfy { $0.count == 8 && $0.allSatisfy { $0 == "." || $0 == "X" } })
        #expect(bitmap != IslandSprite.claude.bitmap)
        #expect(bitmap != IslandSprite.codex.bitmap)
    }

    @Test
    func `configured Harness supplies the right blue light without Codex`() {
        let presentation = NotchCollapsedPresentation.make(
            claude: .idle,
            codex: .idle,
            harness: .running,
            codexConfigured: false,
            harnessConfigured: true)
        #expect(presentation.lights.map(\.provider) == [.claude, .deepseekHarness])
        #expect(presentation.lights[1].side == .right)
        #expect(presentation.lights[1].color == .harness)
        #expect(presentation.lights[1].color.rawValue == "#4D6BFE")
        #expect(presentation.lights[1].state == .running)
    }

    @Test
    func `right light follows strongest configured status and matching attention on ties`() throws {
        let harnessAttention = try #require(AgentTaskAttention(event: .fixture(
            kind: .approvalRequested,
            provider: .deepseekHarness,
            sessionID: "harness-task",
            turnID: "turn")))
        func provider(
            codex: AgentTaskStatus,
            harness: AgentTaskStatus,
            configured: Bool = true,
            attention: AgentTaskAttention? = nil) -> AgentTaskProvider
        {
            NotchCollapsedPresentation.make(
                claude: .idle,
                codex: codex,
                harness: harness,
                harnessConfigured: configured,
                attention: attention).lights[1].provider
        }
        #expect(provider(codex: .running, harness: .needsApproval) == .deepseekHarness)
        #expect(provider(codex: .needsApproval, harness: .running) == .codex)
        #expect(provider(codex: .running, harness: .running) == .codex)
        #expect(provider(codex: .needsApproval, harness: .needsApproval, attention: harnessAttention) ==
            .deepseekHarness)
        #expect(provider(codex: .running, harness: .needsApproval, configured: false) == .codex)
    }

    @Test(arguments: [true, false])
    @MainActor
    func `Harness opening reports the desktop opener without Claude fallback`(_ accepted: Bool) {
        var attempted = false
        let opened = AgentTaskFocusResolver.open(
            provider: .deepseekHarness,
            sessionID: "same-id",
            sessions: [AgentSession.fixture(id: "same-id", provider: .claude, cwd: "/repo")],
            openThread: {
                attempted = true
                return accepted
            },
            focus: { _ in
                Issue.record("Harness must never focus a Claude session")
                return .focused
            })
        #expect(attempted)
        #expect(opened == accepted)
    }

    @Test
    func `Harness desktop link uses its registered root and has no terminal session provider`() {
        #expect(AgentTaskFocusResolver.desktopURL(
            provider: .deepseekHarness,
            sessionID: "untrusted/id?query")?.absoluteString == "dsh://open")
        #expect(AgentTaskFocusResolver.desktopURL(provider: .claude, sessionID: "same-id") == nil)
        #expect(AgentTaskFocusResolver.sessionProvider(for: .deepseekHarness) == nil)
        let event = AgentTaskEvent.fixture(
            kind: .turnCompleted,
            provider: .deepseekHarness,
            sessionID: "same-id",
            turnID: nil,
            projectPath: "/repo")
        #expect(AgentTaskFocusResolver.resolve(
            event: event,
            sessions: [AgentSession.fixture(id: "same-id", provider: .claude, cwd: "/repo")]) == nil)
    }
}
