# Vibe Island Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Replace the current Notch presentation with a fixture-driven, pixel-accurate Vibe Island shell while leaving all quota, provider, account, Keychain, and agent integrations untouched; follow-on Agent prompts are limited to Claude Code and OpenAI Codex.

**Architecture:** Keep one fixed transparent AppKit stage at the top of each screen and animate only the SwiftUI island inside it. A pure IslandShellPresentation model owns geometry and fixture content; the controller owns hover/click/ESC choreography; real product data remains disconnected until shell acceptance.

**Tech Stack:** Swift 6, SwiftUI, AppKit NSPanel, Observation, Swift Testing, SwiftPM.

---

## File map

- Create Sources/CodexBar/IslandShellPresentation.swift: pure phases, metrics, fixture data, and derived geometry.
- Create Sources/CodexBar/IslandShellMotion.swift: standard and Reduce Motion timing profiles plus SwiftUI animations.
- Create Sources/CodexBar/IslandShellView.swift: shell shape, root composition, content crossfade, and material.
- Create Sources/CodexBar/IslandShellFixtureViews.swift: compact pet/title/count and expanded fixture rows.
- Create Sources/CodexBar/IslandShellFont.swift: process-local registration for the independently licensed Departure Mono font.
- Create Sources/CodexBar/IslandShellLaunchOptions.swift: deterministic compact/expanded/reduced-motion launch arguments.
- Create Sources/CodexBar/Resources/Fonts/DepartureMono-Regular.otf: upstream v1.500 font from rektdeckard/departure-mono.
- Create Sources/CodexBar/Resources/Fonts/DepartureMono-OFL.txt: upstream SIL Open Font License.
- Modify Sources/CodexBar/NotchIslandView.swift: replace the visible tree with the new shell while leaving old feature models available for later wiring.
- Modify Sources/CodexBar/NotchBar.swift: fixed stage frame, shell state, hover cooldown, compact collapse target, and fixture launch options.
- Modify Tests/CodexBarTests/NotchGeometryTests.swift: exact target geometry and fixed-stage expectations.
- Create Tests/CodexBarTests/IslandShellPresentationTests.swift: phase, fixture, motion, and launch-option tests.
- Create Tests/CodexBarTests/IslandShellInteractionPolicyTests.swift: hover zone and cooldown tests.

### Task 1: Pure shell presentation and reference fixture

**Files:**
- Create: Sources/CodexBar/IslandShellPresentation.swift
- Create: Tests/CodexBarTests/IslandShellPresentationTests.swift

- [ ] **Step 1: Write the failing presentation tests**

Create Tests/CodexBarTests/IslandShellPresentationTests.swift:

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

- [ ] **Step 2: Run the tests and verify the new symbols are missing**

Run:

    swift test --filter IslandShellPresentationTests

Expected: FAIL with errors that IslandShellFixture and IslandShellPresentation are not defined.

- [ ] **Step 3: Implement the minimal pure model**

Create Sources/CodexBar/IslandShellPresentation.swift:

    import CoreGraphics

    enum IslandShellPhase: Equatable {
        case dormant
        case compact
        case expanded
    }

    enum IslandShellTone: Equatable {
        case idle
        case working
    }

    struct IslandShellSessionFixture: Equatable, Identifiable {
        let id: String
        let title: String
        let agent: String
        let host: String
        let duration: String
        let prompt: String?
        let status: String?
        let tone: IslandShellTone
    }

    struct IslandShellFixture: Equatable {
        let compactTitle: String
        let sessionCount: Int
        let usageText: String
        let primary: IslandShellSessionFixture
        let secondary: [IslandShellSessionFixture]

        static let reference = IslandShellFixture(
            compactTitle: "fix auth bug",
            sessionCount: 3,
            usageText: "5h 11% 4h1m | 7d 2% 6h1m",
            primary: IslandShellSessionFixture(
                id: "claude-fix-auth",
                title: "fix auth bug",
                agent: "Claude Code",
                host: "iTerm",
                duration: "27m",
                prompt: "You: fix the auth bug in middleware",
                status: "Writing middleware.ts",
                tone: .working),
            secondary: [
                IslandShellSessionFixture(
                    id: "codex-backend",
                    title: "backend server",
                    agent: "Codex",
                    host: "Terminal",
                    duration: "1h",
                    prompt: nil,
                    status: nil,
                    tone: .working),
                IslandShellSessionFixture(
                    id: "gemini-queries",
                    title: "optimize queries",
                    agent: "Claude Code",
                    host: "Ghostty",
                    duration: "5h",
                    prompt: nil,
                    status: nil,
                    tone: .idle),
            ])
    }

    enum IslandShellMetrics {
        static let compactBodyWidth: CGFloat = 240
        static let expandedBodyWidth: CGFloat = 380
        static let compactHeight: CGFloat = 36
        static let expandedHeight: CGFloat = 175
        static let shoulderRadius: CGFloat = 13
        static let compactBottomRadius: CGFloat = 10
        static let expandedBottomRadius: CGFloat = 14
        static let stageWidth: CGFloat = 494
        static let stageHeight: CGFloat = 520
        static let stageSideMargin: CGFloat = 44
        static let hoverGrace: CGFloat = 16
        static let hoverDelay: Double = 0.20
        static let collapseDelay: Double = 0.32
        static let hoverCooldown: Double = 0.25
    }

    struct IslandShellPresentation: Equatable {
        let phase: IslandShellPhase
        let anchorSize: CGSize
        let fixture: IslandShellFixture

        var bodyWidth: CGFloat {
            switch self.phase {
            case .dormant: self.anchorSize.width
            case .compact: max(IslandShellMetrics.compactBodyWidth, self.anchorSize.width)
            case .expanded: max(IslandShellMetrics.expandedBodyWidth, self.anchorSize.width)
            }
        }

        var shoulderRadius: CGFloat {
            self.phase == .dormant ? 0 : IslandShellMetrics.shoulderRadius
        }

        var totalWidth: CGFloat {
            self.bodyWidth + self.shoulderRadius * 2
        }

        var height: CGFloat {
            switch self.phase {
            case .dormant: self.anchorSize.height
            case .compact: IslandShellMetrics.compactHeight
            case .expanded: IslandShellMetrics.expandedHeight
            }
        }

        var bottomRadius: CGFloat {
            switch self.phase {
            case .dormant: 0
            case .compact: IslandShellMetrics.compactBottomRadius
            case .expanded: IslandShellMetrics.expandedBottomRadius
            }
        }
    }

- [ ] **Step 4: Run the focused tests**

Run:

    swift test --filter IslandShellPresentationTests

Expected: PASS, 3 tests.

- [ ] **Step 5: Commit the pure shell contract**

Run:

    git add Sources/CodexBar/IslandShellPresentation.swift Tests/CodexBarTests/IslandShellPresentationTests.swift
    git commit -m "Add island shell presentation model"

### Task 2: Exact motion profile and shell outline

**Files:**
- Create: Sources/CodexBar/IslandShellMotion.swift
- Create: Sources/CodexBar/IslandShellView.swift
- Modify: Tests/CodexBarTests/IslandShellPresentationTests.swift

- [ ] **Step 1: Add failing motion and shape tests**

Append to IslandShellPresentationTests:

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
    func `shell outline fills its requested bounds`() {
        let rect = CGRect(x: 0, y: 0, width: 406, height: 175)
        let path = IslandShellShape(shoulderRadius: 13, bottomRadius: 14).path(in: rect)

        #expect(path.boundingRect == rect)
    }

- [ ] **Step 2: Run the tests and verify they fail**

Run:

    swift test --filter IslandShellPresentationTests

Expected: FAIL because IslandShellMotion and IslandShellShape do not exist.

- [ ] **Step 3: Add the motion profile and SwiftUI animation factories**

Create Sources/CodexBar/IslandShellMotion.swift:

    import SwiftUI

    struct IslandShellMotionProfile: Equatable {
        let containerDuration: Double
        let radiusDuration: Double
        let opacityDuration: Double
        let blurDuration: Double
        let scaleDuration: Double
        let contentDelay: Double
        let blurRadius: CGFloat
        let hiddenScale: CGFloat
    }

    enum IslandShellMotion {
        static func profile(reduceMotion: Bool) -> IslandShellMotionProfile {
            if reduceMotion {
                return IslandShellMotionProfile(
                    containerDuration: 0.14,
                    radiusDuration: 0.14,
                    opacityDuration: 0.14,
                    blurDuration: 0.14,
                    scaleDuration: 0.14,
                    contentDelay: 0,
                    blurRadius: 0,
                    hiddenScale: 1)
            }
            return IslandShellMotionProfile(
                containerDuration: 0.50,
                radiusDuration: 0.40,
                opacityDuration: 0.25,
                blurDuration: 0.30,
                scaleDuration: 0.35,
                contentDelay: 0.06,
                blurRadius: 6,
                hiddenScale: 0.96)
        }

        static func container(reduceMotion: Bool) -> Animation {
            reduceMotion
                ? .easeOut(duration: 0.14)
                : .timingCurve(0.175, 0.885, 0.32, 1.1, duration: 0.50)
        }

        static func radius(reduceMotion: Bool) -> Animation {
            .easeOut(duration: reduceMotion ? 0.14 : 0.40)
        }

        static func opacity(reduceMotion: Bool) -> Animation {
            .easeOut(duration: reduceMotion ? 0.14 : 0.25)
                .delay(reduceMotion ? 0 : 0.06)
        }

        static func blur(reduceMotion: Bool) -> Animation {
            .easeOut(duration: reduceMotion ? 0.14 : 0.30)
                .delay(reduceMotion ? 0 : 0.06)
        }

        static func scale(reduceMotion: Bool) -> Animation {
            reduceMotion
                ? .easeOut(duration: 0.14)
                : .timingCurve(0.175, 0.885, 0.32, 1.1, duration: 0.35).delay(0.06)
        }
    }

- [ ] **Step 4: Add the exact concave-shoulder shape**

Create Sources/CodexBar/IslandShellView.swift:

    import SwiftUI

    struct IslandShellShape: Shape {
        var shoulderRadius: CGFloat
        var bottomRadius: CGFloat

        var animatableData: AnimatablePair<CGFloat, CGFloat> {
            get { AnimatablePair(self.shoulderRadius, self.bottomRadius) }
            set {
                self.shoulderRadius = newValue.first
                self.bottomRadius = newValue.second
            }
        }

        func path(in rect: CGRect) -> Path {
            let shoulder = max(0, min(self.shoulderRadius, rect.width / 2))
            let bottom = max(0, min(self.bottomRadius, min(rect.height, rect.width / 2)))
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + shoulder, y: rect.minY + shoulder),
                control: CGPoint(x: rect.minX + shoulder, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + shoulder + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + shoulder, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - shoulder - bottom, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - shoulder, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX, y: rect.minY),
                control: CGPoint(x: rect.maxX - shoulder, y: rect.minY))
            path.closeSubpath()
            return path
        }
    }

- [ ] **Step 5: Run tests and commit**

Run:

    swift test --filter IslandShellPresentationTests

Expected: PASS, 6 tests.

Then:

    git add Sources/CodexBar/IslandShellMotion.swift Sources/CodexBar/IslandShellView.swift Tests/CodexBarTests/IslandShellPresentationTests.swift
    git commit -m "Define island shell geometry and motion"

### Task 3: Fixture-driven compact and expanded views

**Files:**
- Create: Sources/CodexBar/IslandShellFont.swift
- Create: Sources/CodexBar/IslandShellFixtureViews.swift
- Create: Sources/CodexBar/Resources/Fonts/DepartureMono-Regular.otf
- Create: Sources/CodexBar/Resources/Fonts/DepartureMono-OFL.txt
- Modify: Sources/CodexBar/IslandShellView.swift

- [ ] **Step 1: Write the failing font-resource test**

Append to IslandShellPresentationTests:

    @Test
    func `departure mono ships with its OFL license`() {
        #expect(IslandShellFont.fontURL != nil)
        #expect(IslandShellFont.licenseURL != nil)
    }

Run:

    swift test --filter IslandShellPresentationTests

Expected: FAIL because IslandShellFont does not exist.

- [ ] **Step 2: Add Departure Mono from its independent OFL source**

Do not copy the font from Vibe Island.app. Download the independently published v1.500 release:

    mkdir -p /tmp/departure-mono-1.500 Sources/CodexBar/Resources/Fonts
    curl -L --fail --silent --show-error \
      -o /tmp/DepartureMono-1.500.zip \
      https://github.com/rektdeckard/departure-mono/releases/download/v1.500/DepartureMono-1.500.zip
    unzip -o /tmp/DepartureMono-1.500.zip -d /tmp/departure-mono-1.500
    cp /tmp/departure-mono-1.500/DepartureMono-1.500/DepartureMono-Regular.otf \
      Sources/CodexBar/Resources/Fonts/DepartureMono-Regular.otf
    cp /tmp/departure-mono-1.500/DepartureMono-1.500/LICENSE \
      Sources/CodexBar/Resources/Fonts/DepartureMono-OFL.txt

The upstream repository identifies the font as SIL OFL. Keep the license beside the font in the app resources.

- [ ] **Step 3: Register the bundled font once per process**

Create Sources/CodexBar/IslandShellFont.swift:

    import CoreText
    import Foundation

    enum IslandShellFont {
        static let familyName = "Departure Mono"

        static var fontURL: URL? {
            Bundle.module.url(
                forResource: "DepartureMono-Regular",
                withExtension: "otf",
                subdirectory: "Fonts")
        }

        static var licenseURL: URL? {
            Bundle.module.url(
                forResource: "DepartureMono-OFL",
                withExtension: "txt",
                subdirectory: "Fonts")
        }

        private static let didRegister: Bool = {
            guard let fontURL else { return false }
            return CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }()

        static func register() {
            _ = self.didRegister
        }
    }

Register the font when Task 4 connects the shell to NotchBarController.

- [ ] **Step 4: Build the fixture views**

Create Sources/CodexBar/IslandShellFixtureViews.swift:

    import SwiftUI

    struct IslandPixelPet: View {
        let tone: IslandShellTone
        let size: CGFloat

        private var color: Color {
            switch self.tone {
            case .idle: Color(red: 0.13, green: 0.77, blue: 0.36)
            case .working: Color(red: 0.23, green: 0.51, blue: 0.96)
            }
        }

        var body: some View {
            Canvas { context, canvasSize in
                let unit = min(canvasSize.width / 8, canvasSize.height / 8)
                let cells = [
                    CGRect(x: 1, y: 2, width: 1, height: 1),
                    CGRect(x: 4, y: 2, width: 1, height: 1),
                    CGRect(x: 0, y: 3, width: 6, height: 2),
                    CGRect(x: 1, y: 5, width: 2, height: 1),
                    CGRect(x: 4, y: 5, width: 2, height: 1),
                ]
                for cell in cells {
                    context.fill(
                        Path(CGRect(
                            x: cell.minX * unit,
                            y: cell.minY * unit,
                            width: cell.width * unit,
                            height: cell.height * unit)),
                        with: .color(self.color))
                }
                for eyeX in [1.0, 4.0] {
                    context.fill(
                        Path(CGRect(
                            x: eyeX * unit,
                            y: 3 * unit,
                            width: unit,
                            height: unit)),
                        with: .color(.black))
                }
            }
            .frame(width: self.size, height: self.size)
            .shadow(color: self.color.opacity(0.65), radius: 3)
            .accessibilityHidden(true)
        }
    }

    struct IslandCompactFixtureView: View {
        let fixture: IslandShellFixture

        var body: some View {
            HStack(spacing: 8) {
                IslandPixelPet(tone: .idle, size: 20)
                Text(self.fixture.compactTitle)
                    .font(.custom(IslandShellFont.familyName, size: 11))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                Text("\(self.fixture.sessionCount)")
                    .font(.custom(IslandShellFont.familyName, size: 9))
                    .foregroundStyle(.white.opacity(0.52))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    struct IslandExpandedFixtureView: View {
        let fixture: IslandShellFixture

        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.fixture.usageText)
                    .font(.custom(IslandShellFont.familyName, size: 9.5))
                    .foregroundStyle(.white.opacity(0.62))
                    .padding(.horizontal, 8)
                    .frame(height: 15)
                IslandPrimarySessionFixtureView(session: self.fixture.primary)
                ForEach(self.fixture.secondary) { session in
                    IslandSecondarySessionFixtureView(session: session)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private struct IslandPrimarySessionFixtureView: View {
        let session: IslandShellSessionFixture

        var body: some View {
            HStack(alignment: .top, spacing: 10) {
                IslandPixelPet(tone: self.session.tone, size: 16)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(self.session.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 4)
                        IslandSessionTag(text: self.session.agent)
                        IslandSessionTag(text: self.session.host)
                        Text(self.session.duration)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    if let prompt = self.session.prompt {
                        Text(prompt)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.40))
                            .lineLimit(1)
                    }
                    if let status = self.session.status {
                        Text(status)
                            .font(.system(size: 10))
                            .foregroundStyle(Color(red: 0.23, green: 0.51, blue: 0.96))
                            .lineLimit(1)
                    }
                }
            }
            .padding(8)
            .frame(height: 60)
            .contentShape(Rectangle())
        }
    }

    private struct IslandSecondarySessionFixtureView: View {
        let session: IslandShellSessionFixture

        private var dotColor: Color {
            switch self.session.tone {
            case .idle: Color(red: 0.13, green: 0.77, blue: 0.36)
            case .working: Color(red: 0.23, green: 0.51, blue: 0.96)
            }
        }

        var body: some View {
            HStack(spacing: 8) {
                Circle().fill(self.dotColor).frame(width: 6, height: 6)
                Text(self.session.title)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.70))
                    .lineLimit(1)
                Spacer(minLength: 4)
                IslandSessionTag(text: self.session.agent)
                IslandSessionTag(text: self.session.host)
                Text(self.session.duration)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
        }
    }

    private struct IslandSessionTag: View {
        let text: String

        var body: some View {
            Text(self.text)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
        }
    }

The file reads only IslandShellFixture.reference data. It must not import Provider, SettingsStore, or AgentTaskStore.

- [ ] **Step 5: Complete the root shell composition**

Append to IslandShellView.swift:

    struct IslandShellActions {
        let toggleExpanded: @MainActor () -> Void
        let hoverEntered: @MainActor () -> Void
    }

    struct IslandShellView: View {
        let presentation: IslandShellPresentation
        let reduceMotion: Bool
        let actions: IslandShellActions

        private var shape: IslandShellShape {
            IslandShellShape(
                shoulderRadius: self.presentation.shoulderRadius,
                bottomRadius: self.presentation.bottomRadius)
        }

        var body: some View {
            ZStack {
                Color.black
                self.contentLayers
            }
            .frame(
                width: self.presentation.totalWidth,
                height: self.presentation.height,
                alignment: .top)
            .clipShape(self.shape)
            .overlay {
                self.shape.stroke(
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(self.presentation.phase == .expanded ? 0.08 : 0),
                        ],
                        startPoint: .top,
                        endPoint: .bottom),
                    lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.60), radius: 8, y: 2)
            .shadow(color: .black.opacity(0.30), radius: 24, y: 8)
            .shadow(
                color: .white.opacity(self.presentation.phase == .expanded ? 0.04 : 0),
                radius: 15)
            .contentShape(self.shape)
            .onTapGesture { self.actions.toggleExpanded() }
            .onHover { inside in
                if inside { self.actions.hoverEntered() }
            }
            .animation(
                IslandShellMotion.container(reduceMotion: self.reduceMotion),
                value: self.presentation.totalWidth)
            .animation(
                IslandShellMotion.container(reduceMotion: self.reduceMotion),
                value: self.presentation.height)
            .animation(
                IslandShellMotion.radius(reduceMotion: self.reduceMotion),
                value: self.presentation.bottomRadius)
        }

        private var contentLayers: some View {
            let compactVisible = self.presentation.phase == .compact
            let expandedVisible = self.presentation.phase == .expanded
            let profile = IslandShellMotion.profile(reduceMotion: self.reduceMotion)

            return ZStack {
                IslandCompactFixtureView(fixture: self.presentation.fixture)
                    .opacity(compactVisible ? 1 : 0)
                    .blur(radius: compactVisible ? 0 : profile.blurRadius)
                    .scaleEffect(compactVisible ? 1 : profile.hiddenScale)
                    .animation(
                        IslandShellMotion.opacity(reduceMotion: self.reduceMotion),
                        value: compactVisible)
                    .animation(
                        IslandShellMotion.blur(reduceMotion: self.reduceMotion),
                        value: compactVisible)
                    .animation(
                        IslandShellMotion.scale(reduceMotion: self.reduceMotion),
                        value: compactVisible)

                IslandExpandedFixtureView(fixture: self.presentation.fixture)
                    .opacity(expandedVisible ? 1 : 0)
                    .blur(radius: expandedVisible ? 0 : profile.blurRadius)
                    .scaleEffect(expandedVisible ? 1 : profile.hiddenScale)
                    .animation(
                        IslandShellMotion.opacity(reduceMotion: self.reduceMotion),
                        value: expandedVisible)
                    .animation(
                        IslandShellMotion.blur(reduceMotion: self.reduceMotion),
                        value: expandedVisible)
                    .animation(
                        IslandShellMotion.scale(reduceMotion: self.reduceMotion),
                        value: expandedVisible)
            }
        }
    }

- [ ] **Step 6: Build and commit**

Run:

    swift build
    swift test --filter IslandShellPresentationTests

Expected: build succeeds and focused tests pass.

Then:

    git add Sources/CodexBar/IslandShellFont.swift Sources/CodexBar/IslandShellView.swift Sources/CodexBar/IslandShellFixtureViews.swift Sources/CodexBar/Resources/Fonts
    git commit -m "Render Vibe Island shell fixtures"

### Task 4: Fixed stage and stable hover choreography

**Files:**
- Modify: Sources/CodexBar/NotchBar.swift
- Modify: Sources/CodexBar/NotchIslandView.swift
- Modify: Tests/CodexBarTests/NotchGeometryTests.swift
- Create: Tests/CodexBarTests/IslandShellInteractionPolicyTests.swift

- [ ] **Step 1: Write exact geometry and interaction tests**

Replace the old phase-growth test in NotchGeometryTests with:

    @MainActor
    @Test
    func `shell presentation grows inside one fixed stage`() {
        let state = NotchBarState()
        state.notchSize = CGSize(width: 156, height: 28)

        state.phase = .compact
        #expect(state.shellPresentation.totalWidth == 266)
        #expect(state.shellPresentation.height == 36)

        state.phase = .expanded
        #expect(state.shellPresentation.totalWidth == 406)
        #expect(state.shellPresentation.height == 175)
        #expect(NotchGeometry.stageWidth == 494)
        #expect(NotchGeometry.stageHeight == 520)
    }

Create IslandShellInteractionPolicyTests with:

    @Test
    func `expanded hover zone adds sixteen point grace`() {
        let bounds = CGRect(x: 600, y: 700, width: 406, height: 175)
        #expect(IslandShellInteractionPolicy.hoverZone(visibleBounds: bounds)
            == bounds.insetBy(dx: -16, dy: -16))
    }

    @Test
    func `cooldown blocks immediate hover reentry`() {
        let collapsedAt = Date(timeIntervalSinceReferenceDate: 100)
        #expect(!IslandShellInteractionPolicy.canEnter(
            now: collapsedAt.addingTimeInterval(0.20),
            collapsedAt: collapsedAt))
        #expect(IslandShellInteractionPolicy.canEnter(
            now: collapsedAt.addingTimeInterval(0.25),
            collapsedAt: collapsedAt))
    }

- [ ] **Step 2: Run the tests and verify failure**

Run:

    swift test --filter NotchGeometryTests
    swift test --filter IslandShellInteractionPolicyTests

Expected: FAIL because compact phase, shellPresentation, and the policy are not wired.

- [ ] **Step 3: Wire shell state and geometry**

Remove NotchPhase. In NotchBarState, change phase to IslandShellPhase, initialize it to compact, add reduceMotion, and add shellPresentation:

    var shellPresentation: IslandShellPresentation {
        IslandShellPresentation(
            phase: self.phase,
            anchorSize: self.notchSize,
            fixture: .reference)
    }

Replace the top of NotchGeometry with:

    enum NotchGeometry {
        static let stageWidth: CGFloat = IslandShellMetrics.stageWidth
        static let stageHeight: CGFloat = IslandShellMetrics.stageHeight
        static let stageSideMargin: CGFloat = IslandShellMetrics.stageSideMargin
        static let dormantSideGrab: CGFloat = 20
        static let dormantBottomGrab: CGFloat = 8
        static let simulatedAnchorSize = CGSize(width: 84, height: 20)
        static let simulatedTopGap: CGFloat = 6
        static let hoverGrace: CGFloat = IslandShellMetrics.hoverGrace

Keep the existing layout functions below these constants. Leave product-data properties present but unused by shellPresentation.

At the start of NotchBarController.configurePanel(), call IslandShellFont.register(). Replace the visible NotchIslandView body with IslandShellView using state.shellPresentation, state.reduceMotion, toggleExpanded, and hoverEntered. Keep the legacy feature presentation types compiled but unreachable until the function phase.

- [ ] **Step 4: Add the pure interaction policy**

Add:

    enum IslandShellInteractionPolicy {
        static func hoverZone(visibleBounds: CGRect) -> CGRect {
            visibleBounds.insetBy(
                dx: -IslandShellMetrics.hoverGrace,
                dy: -IslandShellMetrics.hoverGrace)
        }

        static func canEnter(now: Date, collapsedAt: Date?) -> Bool {
            guard let collapsedAt else { return true }
            return now.timeIntervalSince(collapsedAt) >= IslandShellMetrics.hoverCooldown
        }
    }

- [ ] **Step 5: Keep one fixed stage frame**

Delete settleTask, openStage(), scheduleStageSettle(), and every call to them. Replace applyPanelFrame and refreshHoverZone with:

    private func applyPanelFrame() {
        guard let layout else { return }
        self.panel.setFrame(layout.stageFrame, display: true)
        self.state.centerOffset = layout.anchorRect.midX - layout.stageFrame.midX
    }

    private func refreshHoverZone() {
        defer { self.updatePanelMouseEventPolicy(pointerLocation: NSEvent.mouseLocation) }
        guard let layout else {
            self.hoverZone = .zero
            return
        }
        let shell = self.state.shellPresentation
        let visibleBounds = CGRect(
            x: layout.anchorRect.midX - shell.totalWidth / 2,
            y: layout.stageFrame.maxY - shell.height,
            width: shell.totalWidth,
            height: shell.height)
        self.hoverZone = IslandShellInteractionPolicy.hoverZone(visibleBounds: visibleBounds)
    }

- [ ] **Step 6: Collapse to Compact and add cooldown**

Delete the controller's static dwellInterval and use IslandShellMetrics. Add:

    private var lastCollapsedAt: Date?

Replace toggle, pointerDidEnter, scheduleDwellExpansion, scheduleCollapse, collapseNow, and setPhase with:

    func toggle() {
        if self.state.phase == .expanded {
            self.collapseNow()
        } else if self.state.phase == .compact {
            guard NotchSurfaceVisibilityPolicy.shouldExpand(
                trigger: .click,
                isFullscreen: self.isFullscreen())
            else { return }
            self.setPhase(.expanded)
            self.startPointerWatchdog()
        }
    }

    private func pointerDidEnter() {
        self.collapseTask?.cancel()
        self.collapseTask = nil
        guard IslandShellInteractionPolicy.canEnter(
            now: Date(),
            collapsedAt: self.lastCollapsedAt)
        else { return }
        guard !self.isPointerInside else { return }
        guard NotchSurfaceVisibilityPolicy.shouldExpand(
            trigger: .hover,
            isFullscreen: self.isFullscreen())
        else { return }
        self.isPointerInside = true
        if self.state.phase == .compact {
            self.scheduleDwellExpansion()
            self.startPointerWatchdog()
        }
    }

    private func scheduleDwellExpansion() {
        guard self.state.phase == .compact, self.dwellTask == nil else { return }
        self.dwellTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(IslandShellMetrics.hoverDelay))
            guard !Task.isCancelled,
                  let self,
                  self.isPointerInside,
                  self.state.phase == .compact
            else { return }
            self.dwellTask = nil
            self.setPhase(.expanded)
        }
    }

    private func scheduleCollapse() {
        self.collapseTask?.cancel()
        self.collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(IslandShellMetrics.collapseDelay))
            guard !Task.isCancelled, let self, !self.isPointerInside else { return }
            self.collapseTask = nil
            self.collapseNow()
        }
    }

    private func collapseNow() {
        self.dwellTask?.cancel()
        self.dwellTask = nil
        guard self.state.phase == .expanded else { return }
        self.lastCollapsedAt = Date()
        self.setPhase(.compact)
    }

    private func setPhase(_ phase: IslandShellPhase) {
        withAnimation(IslandShellMotion.container(reduceMotion: self.state.reduceMotion)) {
            self.state.phase = phase
        }
        self.refreshHoverZone()
    }

Update pointerDidExit to schedule collapse whenever the phase is expanded. Update ESC and outside-click handlers to call collapseNow. teardown() alone sets phase to dormant before ordering the panel out.

During the shell phase, replace the task-attention entry points with:

    func present(_: AgentTaskAttention) {}

    func collapseForExternalAttention() {}

    func collapseAttention() {}

Real task attention is reconnected after shell acceptance.

- [ ] **Step 7: Run focused tests and commit**

Run:

    swift test --filter NotchGeometryTests
    swift test --filter IslandShellInteractionPolicyTests
    swift test --filter NotchSurfaceCoordinatorTests

Expected: all focused suites pass.

Then:

    git add Sources/CodexBar/NotchBar.swift Tests/CodexBarTests/NotchGeometryTests.swift Tests/CodexBarTests/IslandShellInteractionPolicyTests.swift
    git commit -m "Stabilize island shell stage"

### Task 5: Deterministic launch fixtures

**Files:**
- Create: Sources/CodexBar/IslandShellLaunchOptions.swift
- Modify: Sources/CodexBar/NotchBar.swift
- Modify: Tests/CodexBarTests/IslandShellPresentationTests.swift

- [ ] **Step 1: Write failing launch-option tests**

Append to IslandShellPresentationTests:

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
    }

- [ ] **Step 2: Verify failure**

Run:

    swift test --filter IslandShellPresentationTests

Expected: FAIL because IslandShellLaunchOptions is missing.

- [ ] **Step 3: Implement argument parsing**

Create:

    struct IslandShellLaunchOptions: Equatable {
        let phase: IslandShellPhase
        let reduceMotion: Bool

        init(arguments: [String]) {
            if let flag = arguments.firstIndex(of: "--island-fixture-phase"),
               arguments.indices.contains(flag + 1)
            {
                self.phase = switch arguments[flag + 1] {
                case "dormant": .dormant
                case "expanded": .expanded
                default: .compact
                }
            } else {
                self.phase = .compact
            }
            self.reduceMotion = arguments.contains("--island-reduce-motion")
        }

        static var current: IslandShellLaunchOptions {
            IslandShellLaunchOptions(arguments: CommandLine.arguments)
        }
    }

- [ ] **Step 4: Apply options before the panel is shown**

After assigning state.notchSize in NotchBarController.init, set state.phase and state.reduceMotion from IslandShellLaunchOptions.current, OR-ing the reduce flag with macOS accessibilityDisplayShouldReduceMotion.

- [ ] **Step 5: Run tests and commit**

Run:

    swift test --filter IslandShellPresentationTests
    swift test --filter NotchGeometryTests

Expected: all tests pass.

Then:

    git add Sources/CodexBar/IslandShellLaunchOptions.swift Sources/CodexBar/NotchBar.swift Tests/CodexBarTests/IslandShellPresentationTests.swift
    git commit -m "Add island shell fixture launch modes"

### Task 6: Package, inspect, and compare each shell state

**Files:**
- No product code changes unless a measured mismatch is found.

- [ ] **Step 1: Run repository verification**

Run:

    make check
    make test

Expected: both exit 0 and no Keychain prompt appears.

- [ ] **Step 2: Package the tested bundle**

Run:

    ./Scripts/package_app.sh

Expected: a freshly packaged CodexBar.app at the repository root.

- [ ] **Step 3: Verify Compact with Computer Use**

Restart:

    pkill -x CodexBar || pkill -f CodexBar.app || true
    open -n "$PWD/CodexBar.app" --args --island-fixture-phase compact

Acceptance: 240 pt body, 13 pt shoulders, 36 pt height, 10 pt lower radius, unclipped fixture, transparent 494 pt stage click-through.

- [ ] **Step 4: Verify Expanded with Computer Use**

Restart:

    pkill -x CodexBar || pkill -f CodexBar.app || true
    open -n "$PWD/CodexBar.app" --args --island-fixture-phase expanded

Acceptance: 380 pt body, 13 pt shoulders, 175 pt height, correct usage/primary/secondary hierarchy, static measurement error no greater than 2 pt.

- [ ] **Step 5: Verify motion**

Exercise hover, click, ESC, and mouse leave. Confirm the stage does not move, the content layers do not push layout, hover does not immediately collapse, and cooldown prevents reopening.

- [ ] **Step 6: Verify Reduce Motion**

Restart with:

    open -n "$PWD/CodexBar.app" --args --island-fixture-phase compact --island-reduce-motion

Acceptance: 0.14 second transition with no blur or overshoot.

- [ ] **Step 7: User acceptance checkpoint**

Present Compact and Expanded captures, test commands, results, and measured pixel deltas. Stop before wiring quota. Real quota is the first functional task after the user approves the shell.
