import CodexBarCore
import CoreGraphics

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

/// Frozen reference content. Production never reads this — it exists so every visual regression
/// screenshot lands on the exact same frame.
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
    static let compactSideWidth: CGFloat = 90
    /// Wing width used when the compact island has to stay permanently visible beside a hardware
    /// notch. Deliberately much tighter than `compactSideWidth`: every point here is taken from
    /// the menu bar.
    static let compactQuotaWingWidth: CGFloat = 66
    static let expandedBodyWidth: CGFloat = 380
    static let compactHeight: CGFloat = 36
    static let expandedHeight: CGFloat = 175
    static let shoulderRadius: CGFloat = 13
    static let compactBottomRadius: CGFloat = 10
    static let expandedBottomRadius: CGFloat = 22
    // Must clear the widest island plus its shoulders and the shadow margin:
    // 430 + 2*13 + 2*44 = 544.
    static let stageWidth: CGFloat = 560
    static let stageHeight: CGFloat = 520
    static let stageSideMargin: CGFloat = 44
    static let hoverGrace: CGFloat = 16
    static let hoverDelay: Double = 0.18
    static let collapseDelay: Double = 0.35
    static let hoverCooldown: Double = 0.30
}

/// Geometry for one scene on one screen. Everything the silhouette and the hover hit-box need,
/// and nothing else.
struct IslandShellPresentation: Equatable {
    let scene: IslandScene
    let anchorSize: CGSize
    let hasPhysicalNotch: Bool
    /// Whether the compact island should carry a permanent quota reading in its wings.
    let showsCompactQuota: Bool
    /// How many sessions the expanded list has to show; the island grows to fit them.
    let cardCount: Int

    init(
        scene: IslandScene,
        anchorSize: CGSize,
        hasPhysicalNotch: Bool = true,
        showsCompactQuota: Bool = false,
        cardCount: Int = 0)
    {
        self.scene = scene
        self.anchorSize = anchorSize
        self.hasPhysicalNotch = hasPhysicalNotch
        self.showsCompactQuota = showsCompactQuota
        self.cardCount = cardCount
    }

    /// True when compact is nothing but the hardware cut-out. Growing wings costs menu-bar space,
    /// so it only happens when there is an actual reading to put there.
    var compactHugsNotch: Bool {
        self.hasPhysicalNotch && !self.showsCompactQuota
    }

    /// On notched hardware the compact island *is* the hardware cut-out: it must not grow, or it
    /// would paint over the camera housing. Notchless screens get the simulated 240pt strip.
    private var hugsAnchor: Bool {
        self.scene == .dormant || (self.scene == .compact && self.compactHugsNotch)
    }

    var bodyWidth: CGFloat {
        if self.hugsAnchor { return self.anchorSize.width }
        guard let width = IslandSceneMetrics.bodyWidth(self.scene) else {
            // Beside a hardware notch the wings stay tight; on a simulated anchor there is no
            // menu bar underneath, so the prototype's roomier strip is fine.
            guard !self.hasPhysicalNotch else {
                return self.anchorSize.width + IslandShellMetrics.compactQuotaWingWidth * 2
            }
            return max(
                IslandShellMetrics.compactBodyWidth,
                self.anchorSize.width + IslandShellMetrics.compactSideWidth * 2)
        }
        return max(width, self.anchorSize.width)
    }

    var height: CGFloat {
        if self.hugsAnchor { return self.anchorSize.height }
        // Compact beside a hardware notch keeps the cut-out's own height even once it grows wings,
        // or the wings hang below the menu bar instead of reading as part of it.
        if self.scene == .compact, self.hasPhysicalNotch { return self.anchorSize.height }
        return IslandSceneMetrics.height(self.scene, cardCount: self.cardCount)
            ?? IslandShellMetrics.compactHeight
    }

    var shoulderRadius: CGFloat {
        self.hugsAnchor ? 0 : IslandShellMetrics.shoulderRadius
    }

    var bottomRadius: CGFloat {
        self.hugsAnchor ? 0 : IslandSceneMetrics.bottomRadius(self.scene)
    }

    var totalWidth: CGFloat {
        self.bodyWidth + self.shoulderRadius * 2
    }

    var glow: IslandGlow? {
        IslandGlow.of(self.scene)
    }
}

// MARK: - Launch fixtures

enum IslandShellFixtureIndicatorScenario: String, Equatable {
    case running
    case claudeAttention = "claude-attention"
    case codexAttention = "codex-attention"
    case bothAttention = "both-attention"
}

/// Debug-only launch overrides so every scene can be frozen for a screenshot.
struct IslandShellLaunchOptions: Equatable {
    let scene: IslandScene
    let reduceMotion: Bool
    let isFixture: Bool
    let indicatorScenario: IslandShellFixtureIndicatorScenario

    init(arguments: [String]) {
        self.isFixture = arguments.contains("--island-fixture-scene")
            || arguments.contains("--island-fixture-phase")
            || arguments.contains("--island-fixture-status")
        self.scene = Self.scene(in: arguments) ?? .compact
        self.reduceMotion = arguments.contains("--island-reduce-motion")
        if let flag = arguments.firstIndex(of: "--island-fixture-status"),
           arguments.indices.contains(flag + 1),
           let scenario = IslandShellFixtureIndicatorScenario(rawValue: arguments[flag + 1])
        {
            self.indicatorScenario = scenario
        } else {
            self.indicatorScenario = .running
        }
    }

    private static func scene(in arguments: [String]) -> IslandScene? {
        for flag in ["--island-fixture-scene", "--island-fixture-phase"] {
            guard let index = arguments.firstIndex(of: flag),
                  arguments.indices.contains(index + 1)
            else { continue }
            let raw = arguments[index + 1]
            // `--island-fixture-phase expanded` predates scenes; keep it working.
            if raw == "expanded" { return .overview }
            if let scene = IslandScene(rawValue: raw) { return scene }
        }
        return nil
    }

    static var current: IslandShellLaunchOptions {
        IslandShellLaunchOptions(arguments: CommandLine.arguments)
    }
}
