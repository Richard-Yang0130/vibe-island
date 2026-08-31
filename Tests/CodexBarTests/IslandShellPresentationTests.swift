import CoreGraphics
import Testing
@testable import CodexBar

struct IslandShellPresentationTests {
    @Test
    func `reference fixture matches the public Vibe Island overview`() {
        let fixture = IslandShellFixture.reference

        #expect(fixture.compactTitle == "fix auth bug")
        #expect(fixture.sessionCount == 3)
        #expect(fixture.usageText == "5h 11% 4h1m | 7d 2% 6h1m")
        #expect(fixture.primary.title == "fix auth bug")
        #expect(fixture.primary.status == "Writing middleware.ts")
        #expect(fixture.secondary.map(\.title) == ["backend server", "optimize queries"])
        #expect(([fixture.primary] + fixture.secondary).map(\.agent)
            == ["Claude Code", "Codex", "Claude Code"])
    }

    @Test
    func `compact and expanded phases use exact reference geometry`() {
        let anchor = CGSize(width: 156, height: 28)
        let compact = IslandShellPresentation(
            phase: .compact,
            anchorSize: anchor,
            fixture: .reference)
        let expanded = IslandShellPresentation(
            phase: .expanded,
            anchorSize: anchor,
            fixture: .reference)

        #expect(compact.bodyWidth == 240)
        #expect(compact.totalWidth == 266)
        #expect(compact.height == 36)
        #expect(compact.bottomRadius == 10)
        #expect(expanded.bodyWidth == 380)
        #expect(expanded.totalWidth == 406)
        #expect(expanded.height == 175)
        #expect(expanded.bottomRadius == 14)
        #expect(expanded.shoulderRadius == 13)
    }

    @Test
    func `dormant phase hugs the physical anchor`() {
        let presentation = IslandShellPresentation(
            phase: .dormant,
            anchorSize: CGSize(width: 156, height: 28),
            fixture: .reference)

        #expect(presentation.bodyWidth == 156)
        #expect(presentation.totalWidth == 156)
        #expect(presentation.height == 28)
        #expect(presentation.shoulderRadius == 0)
        #expect(presentation.bottomRadius == 0)
    }
}
