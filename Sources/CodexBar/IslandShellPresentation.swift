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
    static let compactSideWidth: CGFloat = 90
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
    let hasPhysicalNotch: Bool
    let fixture: IslandShellFixture

    init(
        phase: IslandShellPhase,
        anchorSize: CGSize,
        hasPhysicalNotch: Bool = true,
        fixture: IslandShellFixture)
    {
        self.phase = phase
        self.anchorSize = anchorSize
        self.hasPhysicalNotch = hasPhysicalNotch
        self.fixture = fixture
    }

    var bodyWidth: CGFloat {
        switch self.phase {
        case .dormant: self.anchorSize.width
        case .compact:
            self.hasPhysicalNotch
                ? self.anchorSize.width
                : max(
                    IslandShellMetrics.compactBodyWidth,
                    self.anchorSize.width + IslandShellMetrics.compactSideWidth * 2)
        case .expanded: max(IslandShellMetrics.expandedBodyWidth, self.anchorSize.width)
        }
    }

    var shoulderRadius: CGFloat {
        self.phase == .dormant || (self.phase == .compact && self.hasPhysicalNotch)
            ? 0
            : IslandShellMetrics.shoulderRadius
    }

    var totalWidth: CGFloat {
        self.bodyWidth + self.shoulderRadius * 2
    }

    var height: CGFloat {
        switch self.phase {
        case .dormant: self.anchorSize.height
        case .compact: self.hasPhysicalNotch ? self.anchorSize.height : IslandShellMetrics.compactHeight
        case .expanded: IslandShellMetrics.expandedHeight
        }
    }

    var bottomRadius: CGFloat {
        switch self.phase {
        case .dormant: 0
        case .compact: self.hasPhysicalNotch ? 0 : IslandShellMetrics.compactBottomRadius
        case .expanded: IslandShellMetrics.expandedBottomRadius
        }
    }
}

enum IslandShellFixtureIndicatorScenario: String, Equatable {
    case running
    case claudeAttention = "claude-attention"
    case codexAttention = "codex-attention"
    case bothAttention = "both-attention"
}

struct IslandShellLaunchOptions: Equatable {
    let phase: IslandShellPhase
    let reduceMotion: Bool
    let isFixture: Bool
    let indicatorScenario: IslandShellFixtureIndicatorScenario

    init(arguments: [String]) {
        self.isFixture = arguments.contains("--island-fixture-phase")
            || arguments.contains("--island-fixture-status")
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
        if let flag = arguments.firstIndex(of: "--island-fixture-status"),
           arguments.indices.contains(flag + 1),
           let scenario = IslandShellFixtureIndicatorScenario(rawValue: arguments[flag + 1])
        {
            self.indicatorScenario = scenario
        } else {
            self.indicatorScenario = .running
        }
    }

    static var current: IslandShellLaunchOptions {
        IslandShellLaunchOptions(arguments: CommandLine.arguments)
    }
}
