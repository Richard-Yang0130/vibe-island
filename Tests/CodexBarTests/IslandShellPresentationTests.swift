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
    func `physical notch compact phase exactly matches the hardware anchor`() {
        let anchor = CGSize(width: 156, height: 28)
        let compact = IslandShellPresentation(
            phase: .compact,
            anchorSize: anchor,
            hasPhysicalNotch: true,
            fixture: .reference)
        let expanded = IslandShellPresentation(
            phase: .expanded,
            anchorSize: anchor,
            hasPhysicalNotch: true,
            fixture: .reference)

        #expect(compact.bodyWidth == 156)
        #expect(compact.totalWidth == 156)
        #expect(compact.height == 28)
        #expect(compact.shoulderRadius == 0)
        #expect(compact.bottomRadius == 0)
        #expect(expanded.bodyWidth == 380)
        #expect(expanded.totalWidth == 406)
        #expect(expanded.height == 175)
        #expect(expanded.bottomRadius == 14)
        #expect(expanded.shoulderRadius == 13)
    }

    @Test
    func `notchless compact phase retains the simulated anchor shell`() {
        let compact = IslandShellPresentation(
            phase: .compact,
            anchorSize: CGSize(width: 84, height: 20),
            hasPhysicalNotch: false,
            fixture: .reference)

        #expect(compact.bodyWidth == 264)
        #expect(compact.totalWidth == 290)
        #expect(compact.height == 36)
        #expect(compact.shoulderRadius == 13)
        #expect(compact.bottomRadius == 10)
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

    @Test
    func `standard motion matches the public shell timing`() {
        let profile = IslandShellMotion.profile(reduceMotion: false)

        #expect(profile.containerDuration == 0.50)
        #expect(profile.radiusDuration == 0.40)
        #expect(profile.opacityDuration == 0.25)
        #expect(profile.blurDuration == 0.30)
        #expect(profile.scaleDuration == 0.35)
        #expect(profile.contentDelay == 0.06)
        #expect(profile.blurRadius == 6)
        #expect(profile.hiddenScale == 0.96)
    }

    @Test
    func `reduce motion removes blur and overshoot`() {
        let profile = IslandShellMotion.profile(reduceMotion: true)

        #expect(profile.containerDuration == 0.14)
        #expect(profile.contentDelay == 0)
        #expect(profile.blurRadius == 0)
        #expect(profile.hiddenScale == 1)
    }

    @Test
    func `status motion uses approved breathing and attention timings`() {
        let running = NotchIndicatorMotion.dot(state: .running, reduceMotion: false)
        let attention = NotchIndicatorMotion.edge(reduceMotion: false)

        #expect(running.minimumOpacity == 0.35)
        #expect(running.maximumOpacity == 1)
        #expect(running.duration == 2.4)
        #expect(attention.minimumOpacity == 0.35)
        #expect(attention.maximumOpacity == 1)
        #expect(attention.duration == 1.2)
    }

    @Test
    func `reduce motion keeps status indicators steadily bright`() {
        let running = NotchIndicatorMotion.dot(state: .running, reduceMotion: true)
        let attention = NotchIndicatorMotion.edge(reduceMotion: true)

        #expect(running.minimumOpacity == 1)
        #expect(running.maximumOpacity == 1)
        #expect(running.duration == nil)
        #expect(attention.minimumOpacity == 1)
        #expect(attention.maximumOpacity == 1)
        #expect(attention.duration == nil)
    }

    @Test
    func `shell outline fills its requested bounds`() {
        let rect = CGRect(x: 0, y: 0, width: 406, height: 175)
        let path = IslandShellShape(shoulderRadius: 13, bottomRadius: 14).path(in: rect)

        #expect(path.boundingRect == rect)
    }

    @Test
    func `departure mono ships with its OFL license`() {
        #expect(IslandShellFont.fontURL != nil)
        #expect(IslandShellFont.licenseURL != nil)
    }

    @Test
    func `fixture layout uses the measured overview dimensions`() {
        #expect(IslandShellFixtureLayout.compactSpacing == 8)
        #expect(IslandShellFixtureLayout.compactPetSize == 20)
        #expect(IslandShellFixtureLayout.compactSideWidth == 90)
        #expect(IslandShellFixtureLayout.horizontalPadding == 12)
        #expect(IslandShellFixtureLayout.verticalPadding == 10)
        #expect(IslandShellFixtureLayout.usageHeight == 15)
        #expect(IslandShellFixtureLayout.primaryHeight == 60)
        #expect(IslandShellFixtureLayout.secondaryHeight == 28)
    }

    @Test
    func `launch options select an exact fixture phase`() {
        let options = IslandShellLaunchOptions(arguments: [
            "CodexBar",
            "--island-fixture-phase",
            "expanded",
            "--island-reduce-motion",
        ])

        #expect(options.phase == .expanded)
        #expect(options.reduceMotion)
        #expect(options.isFixture)
        #expect(options.indicatorScenario == .running)
    }

    @Test
    func `invalid launch phase leaves the runtime in compact mode`() {
        let options = IslandShellLaunchOptions(arguments: [
            "CodexBar",
            "--island-fixture-phase",
            "approval",
        ])

        #expect(options.phase == .compact)
        #expect(!options.reduceMotion)
        #expect(options.isFixture)
    }

    @Test
    func `regular launch does not force the fixture surface`() {
        let options = IslandShellLaunchOptions(arguments: ["CodexBar"])

        #expect(!options.isFixture)
    }

    @Test(arguments: [
        ("running", IslandShellFixtureIndicatorScenario.running),
        ("claude-attention", .claudeAttention),
        ("codex-attention", .codexAttention),
        ("both-attention", .bothAttention),
    ])
    func `fixture status selects a deterministic indicator scenario`(
        _ value: String,
        _ expected: IslandShellFixtureIndicatorScenario)
    {
        let options = IslandShellLaunchOptions(arguments: [
            "CodexBar",
            "--island-fixture-phase",
            "compact",
            "--island-fixture-status",
            value,
        ])

        #expect(options.indicatorScenario == expected)
    }
}
