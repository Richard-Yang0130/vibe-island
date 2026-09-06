import CodexBarCore
import SwiftUI

/// 8×8 pixel sprites. Two slots side by side encode the whole ambient state: the left slot says
/// *who* (which agent), the right slot says *what it is doing*.
///
/// The bitmaps are transcribed from the interaction prototype. Two rules keep the pixel language
/// intact and both are easy to break by accident:
///
/// 1. Steps are whole pixels. Never animate a sprite by translating it — sub-pixel offsets turn
///    crisp 8×8 art into grey mush.
/// 2. The working state animates by *swapping frames*, not by moving anything.
enum IslandSprite: String, Equatable, CaseIterable {
    // Identity slot
    case claude
    case codex
    // Status slot
    case work0
    case work1
    case work2
    case alert
    case ask
    case done
    case idle

    /// Row-major bitmap; `X` is a lit pixel.
    var bitmap: [String] {
        switch self {
        case .claude: Self.claudeBitmap
        case .codex: Self.codexBitmap
        case .work0: Self.work0Bitmap
        case .work1: Self.work1Bitmap
        case .work2: Self.work2Bitmap
        case .alert: Self.alertBitmap
        case .ask: Self.askBitmap
        case .done: Self.doneBitmap
        case .idle: Self.idleBitmap
        }
    }

    private static let claudeBitmap = [
        "..X..X..",
        ".XXXXXX.",
        "XX.XX.XX",
        "XXXXXXXX",
        "X.XXXX.X",
        "X.X..X.X",
        "..XX.XX.",
        "........",
    ]

    private static let codexBitmap = [
        "...XX...",
        "..XXXX..",
        ".XXXXXX.",
        "XX.XX.XX",
        "XXXXXXXX",
        ".XXXXXX.",
        ".X.XX.X.",
        "X.X..X.X",
    ]

    private static let work0Bitmap = [
        "........",
        "......XX",
        "......XX",
        "...XX.XX",
        "...XX.XX",
        "XX.XX.XX",
        "XX.XX.XX",
        "........",
    ]

    private static let work1Bitmap = [
        "........",
        "...XX...",
        "...XX...",
        "XX.XX...",
        "XX.XX...",
        "XX.XX.XX",
        "XX.XX.XX",
        "........",
    ]

    private static let work2Bitmap = [
        "........",
        "XX......",
        "XX......",
        "XX....XX",
        "XX....XX",
        "XX.XX.XX",
        "XX.XX.XX",
        "........",
    ]

    private static let alertBitmap = [
        "...XX...",
        "...XX...",
        "...XX...",
        "...XX...",
        "...XX...",
        "........",
        "...XX...",
        "...XX...",
    ]

    private static let askBitmap = [
        "..XXX...",
        ".X...X..",
        ".....X..",
        "....X...",
        "...X....",
        "...X....",
        "........",
        "...X....",
    ]

    private static let doneBitmap = [
        "........",
        "......XX",
        ".....XX.",
        "X...XX..",
        "XX.XX...",
        ".XXXX...",
        "..XX....",
        "........",
    ]

    private static let idleBitmap = [
        "..XXX...",
        "..XXX...",
        "..XXX...",
        "..XXX...",
        "..XXX...",
        "..XXX...",
        "..XXX...",
        "........",
    ]
    /// The three-frame working cycle, in order.
    static let workingFrames: [IslandSprite] = [.work0, .work1, .work2]

    /// Seconds between working frames.
    static let workingFrameInterval: Double = 0.42

    static func identity(for provider: AgentTaskProvider) -> IslandSprite {
        switch provider {
        case .claude: .claude
        case .codex: .codex
        }
    }

    /// Status slot for a session state. `running` resolves to a frame supplied by the animator.
    static func status(for status: AgentTaskStatus, workingFrame: IslandSprite = .work0) -> IslandSprite {
        switch status {
        case .running: workingFrame
        case .needsApproval, .failed: .alert
        case .completed: .done
        case .idle, .interrupted, .disconnected: .idle
        }
    }
}

/// Renders one 8×8 sprite at an integer pixel scale.
struct IslandSpriteView: View {
    let sprite: IslandSprite
    let color: Color
    /// Edge length of a single sprite pixel, in points. Rounded down to a whole number so the grid
    /// always lands on exact boundaries.
    var pixelScale: CGFloat = 2

    private var step: CGFloat {
        max(1, self.pixelScale.rounded(.down))
    }

    var body: some View {
        let step = self.step
        let bitmap = self.sprite.bitmap
        return Canvas(rendersAsynchronously: false) { context, _ in
            for (row, line) in bitmap.enumerated() {
                for (column, character) in line.enumerated() where character == "X" {
                    context.fill(
                        Path(CGRect(
                            x: CGFloat(column) * step,
                            y: CGFloat(row) * step,
                            width: step,
                            height: step)),
                        with: .color(self.color))
                }
            }
        }
        .frame(width: step * 8, height: step * 8)
        .accessibilityHidden(true)
    }
}

/// The identity + status sprite pair used by the compact strip and by every session card.
struct IslandSpritePair: View {
    let provider: AgentTaskProvider
    let status: AgentTaskStatus
    var pixelScale: CGFloat = 2
    let reduceMotion: Bool

    @State private var frameIndex = 0

    private var workingFrame: IslandSprite {
        IslandSprite.workingFrames[self.frameIndex % IslandSprite.workingFrames.count]
    }

    private var isWorking: Bool {
        self.status == .running && !self.reduceMotion
    }

    var body: some View {
        HStack(spacing: max(1, self.pixelScale.rounded(.down)) + 1) {
            IslandSpriteView(
                sprite: IslandSprite.identity(for: self.provider),
                color: IslandAgentColor.color(for: self.provider),
                pixelScale: self.pixelScale)
            IslandSpriteView(
                sprite: IslandSprite.status(for: self.status, workingFrame: self.workingFrame),
                color: self.status.islandColor.color,
                pixelScale: self.pixelScale)
        }
        .task(id: self.isWorking) {
            guard self.isWorking else { return }
            // Frame swap, never a transform: see the type comment.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(IslandSprite.workingFrameInterval))
                guard !Task.isCancelled else { return }
                self.frameIndex &+= 1
            }
        }
    }
}
