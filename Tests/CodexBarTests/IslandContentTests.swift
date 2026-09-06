import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

private func session(
    _ provider: AgentTaskProvider,
    id: String,
    status: AgentTaskStatus,
    minutesAgo: Double,
    project: String? = "/Users/dev/vibe-island",
    title: String? = nil,
    now: Date)
    -> AgentTaskSessionState
{
    AgentTaskSessionState(
        provider: provider,
        sessionID: id,
        turnID: nil,
        status: status,
        updatedAt: now.addingTimeInterval(-minutesAgo * 60),
        projectPath: project,
        transcriptPath: nil,
        taskTitle: title)
}

private func aggregates(
    _ sessions: [AgentTaskSessionState])
    -> [AgentTaskProvider: AgentTaskProviderAggregate]
{
    Dictionary(grouping: sessions, by: \.provider).mapValues { group in
        AgentTaskProviderAggregate(
            provider: group[0].provider,
            status: group.map(\.status).max { $0.priority < $1.priority } ?? .idle,
            sessions: group)
    }
}

struct IslandSceneTests {
    @Test
    func `scene geometry matches the published baseline`() {
        let anchor = CGSize(width: 156, height: 28)
        func size(_ scene: IslandScene) -> (CGFloat, CGFloat, CGFloat) {
            let presentation = IslandShellPresentation(scene: scene, anchorSize: anchor)
            return (presentation.bodyWidth, presentation.height, presentation.bottomRadius)
        }

        #expect(size(.approval) == (430, 245, 22))
        #expect(size(.ask) == (400, 215, 22))
        #expect(size(.ack) == (280, 42, 10))

        /// The session list drives the overview height, so every session is visible instead of
        /// being hidden behind a "+N".
        func listHeight(_ count: Int) -> CGFloat {
            IslandShellPresentation(scene: .overview, anchorSize: anchor, cardCount: count).height
        }
        #expect(listHeight(1) < listHeight(2))
        #expect(listHeight(2) < listHeight(3))
        #expect(listHeight(0) == listHeight(1))
        // ...but it stops growing rather than becoming a wall of black.
        #expect(listHeight(IslandSceneMetrics.maxVisibleSessions)
            == listHeight(IslandSceneMetrics.maxVisibleSessions + 20))

        // Each extra session adds exactly one pinned row plus its spacing — the card view frames
        // itself to the same constant, so the box always contains the list.
        #expect(listHeight(3) - listHeight(2)
            == IslandSceneMetrics.sessionRowHeight + IslandSceneMetrics.sessionRowSpacing)

        // Done carries a "click to jump" line the overview does not, and the box has to allow for
        // it: when it did not, the quota strip rendered outside the silhouette.
        func doneHeight(_ count: Int) -> CGFloat {
            IslandShellPresentation(scene: .done, anchorSize: anchor, cardCount: count).height
        }
        #expect(doneHeight(2) - listHeight(2) == IslandSceneMetrics.jumpHintHeight)

        // The stage has to clear the widest island plus shoulders and shadow margin, or the
        // silhouette gets cropped by its own window.
        let widest = IslandShellPresentation(scene: .overview, anchorSize: anchor).totalWidth
        #expect(widest + IslandShellMetrics.stageSideMargin * 2 <= IslandShellMetrics.stageWidth)
    }

    @Test
    func `compact hugs the notch until there is a quota to show`() {
        let anchor = CGSize(width: 156, height: 28)
        let bare = IslandShellPresentation(scene: .compact, anchorSize: anchor)
        let withQuota = IslandShellPresentation(
            scene: .compact,
            anchorSize: anchor,
            showsCompactQuota: true)

        // Nothing to show: stay exactly the hardware cut-out and take no menu-bar space.
        #expect(bare.compactHugsNotch)
        #expect(bare.bodyWidth == 156)
        #expect(bare.shoulderRadius == 0)

        // A reading earns two tight wings, one either side of the camera housing.
        #expect(!withQuota.compactHugsNotch)
        #expect(withQuota.bodyWidth == 156 + IslandShellMetrics.compactQuotaWingWidth * 2)
        #expect(withQuota.height == 28)
        #expect(withQuota.shoulderRadius == 13)
        #expect(withQuota.bottomRadius == 10)
    }

    @Test
    func `a notchless compact strip keeps the roomier prototype width`() {
        let compact = IslandShellPresentation(
            scene: .compact,
            anchorSize: CGSize(width: 84, height: 20),
            hasPhysicalNotch: false,
            showsCompactQuota: true)

        #expect(compact.bodyWidth == 264)
        #expect(compact.height == 36)
    }

    @Test
    func `only the expanded scenes report as expanded`() {
        #expect(IslandScene.allCases.filter(\.isExpanded)
            == [.overview, .approval, .ask, .done])
        #expect(IslandScene.allCases.filter(\.demandsAttention) == [.approval, .ask])
    }

    @Test
    func `running never interrupts but blocked states do`() {
        #expect(IslandScenePolicy.autoRaise(for: .running) == nil)
        #expect(IslandScenePolicy.autoRaise(for: .idle) == nil)
        #expect(IslandScenePolicy.autoRaise(for: nil) == nil)
        #expect(IslandScenePolicy.autoRaise(for: .needsApproval) == .approval)
        #expect(IslandScenePolicy.autoRaise(for: .completed) == .done)
        #expect(IslandScenePolicy.autoRaise(for: .failed) == .overview)
    }

    @Test
    func `manual expansion lands on the most useful scene`() {
        #expect(IslandScenePolicy.manualExpansion(for: .running) == .overview)
        #expect(IslandScenePolicy.manualExpansion(for: nil) == .overview)
        #expect(IslandScenePolicy.manualExpansion(for: .needsApproval) == .approval)
        #expect(IslandScenePolicy.manualExpansion(for: .completed) == .done)
    }

    @Test
    func `attention scenes glow and ambient scenes do not`() {
        #expect(IslandGlow.of(.compact) == nil)
        #expect(IslandGlow.of(.ack) == nil)
        #expect(IslandGlow.of(.approval)?.color == .alert)
        #expect(IslandGlow.of(.ask)?.color == .question)
        #expect(IslandGlow.of(.done)?.color == .idle)
    }
}

struct IslandSpriteTests {
    @Test
    func `every sprite is an eight by eight grid`() {
        for sprite in IslandSprite.allCases {
            let bitmap = sprite.bitmap
            #expect(bitmap.count == 8, "\(sprite.rawValue) has \(bitmap.count) rows")
            for row in bitmap {
                #expect(row.count == 8, "\(sprite.rawValue) has a \(row.count) column row")
                #expect(row.allSatisfy { $0 == "X" || $0 == "." })
            }
        }
    }

    @Test
    func `the working cycle has three distinct frames`() {
        #expect(IslandSprite.workingFrames == [.work0, .work1, .work2])
        #expect(Set(IslandSprite.workingFrames.map(\.bitmap.description)).count == 3)
    }

    @Test
    func `status maps to the sprite that reads as that state`() {
        #expect(IslandSprite.status(for: .running, workingFrame: .work1) == .work1)
        #expect(IslandSprite.status(for: .needsApproval) == .alert)
        #expect(IslandSprite.status(for: .failed) == .alert)
        #expect(IslandSprite.status(for: .completed) == .done)
        #expect(IslandSprite.status(for: .idle) == .idle)
        #expect(IslandSprite.identity(for: .claude) == .claude)
        #expect(IslandSprite.identity(for: .codex) == .codex)
    }
}

struct IslandDurationTests {
    @Test
    func `durations compress to the prototype vocabulary`() {
        #expect(IslandDuration.compact(27 * 60) == "27m")
        #expect(IslandDuration.compact(64 * 60) == "1h04")
        #expect(IslandDuration.compact(5 * 3600) == "5h")
        #expect(IslandDuration.compact(26 * 3600) == "1d2h")
        #expect(IslandDuration.compact(48 * 3600) == "2d")
    }

    @Test
    func `sub minute and invalid intervals produce no label`() {
        #expect(IslandDuration.compact(30) == nil)
        #expect(IslandDuration.compact(-5) == nil)
        #expect(IslandDuration.compact(.infinity) == nil)
    }
}

struct IslandContentTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000)

    @Test
    func `sessions sort by urgency then recency`() {
        let content = IslandContent(
            card: nil,
            aggregates: aggregates([
                session(.claude, id: "a", status: .running, minutesAgo: 1, now: self.now),
                session(.codex, id: "b", status: .needsApproval, minutesAgo: 30, now: self.now),
                session(.codex, id: "c", status: .running, minutesAgo: 90, now: self.now),
            ]),
            attention: nil,
            hidePersonalInfo: false,
            now: self.now)

        #expect(content.cards.map(\.id) == ["codex:b", "claude:a", "codex:c"])
        #expect(content.cards.map(\.sessionID) == ["b", "a", "c"])
        #expect(content.sessionCount == 3)
        // The compact strip speaks for the top card, so the sprite always matches the list.
        #expect(content.leadProvider == .codex)
        #expect(content.leadStatus == .needsApproval)
    }

    @Test
    func `card falls back from title to project folder`() {
        let content = IslandContent(
            card: nil,
            aggregates: aggregates([
                session(.claude, id: "a", status: .running, minutesAgo: 27, now: self.now),
                session(
                    .codex,
                    id: "b",
                    status: .running,
                    minutesAgo: 27,
                    title: "optimize queries",
                    now: self.now),
            ]),
            attention: nil,
            hidePersonalInfo: false,
            now: self.now)

        let titles = Set(content.cards.map(\.title))
        #expect(titles == ["vibe-island", "optimize queries"])
        #expect(content.cards.allSatisfy { $0.duration == "27m" })
        #expect(content.cards.allSatisfy { $0.chips.first == "Claude" || $0.chips.first == "Codex" })
    }

    @Test
    func `root working directory is not shown as a task title`() throws {
        let content = IslandContent(
            card: nil,
            aggregates: aggregates([
                session(.codex, id: "root", status: .running, minutesAgo: 1, project: "/", now: self.now),
            ]),
            attention: nil,
            hidePersonalInfo: false,
            now: self.now)

        #expect(try #require(content.cards.first).title == "Codex")
    }

    @Test
    func `idle sessions are absent from the running task list`() {
        let content = IslandContent(
            card: nil,
            aggregates: aggregates([
                session(.codex, id: "stale", status: .idle, minutesAgo: 1, now: self.now),
                session(.codex, id: "live", status: .running, minutesAgo: 2, now: self.now),
            ]),
            attention: nil,
            hidePersonalInfo: false,
            now: self.now)

        #expect(content.cards.map(\.id) == ["codex:live"])
    }

    @Test
    func `hiding personal info drops titles paths and prompts`() throws {
        let content = IslandContent(
            card: nil,
            aggregates: aggregates([
                session(
                    .claude,
                    id: "a",
                    status: .completed,
                    minutesAgo: 5,
                    title: "fix auth bug",
                    now: self.now),
            ]),
            attention: nil,
            hosts: ["claude:a": "Ghostty"],
            hidePersonalInfo: true,
            now: self.now)

        let card = try #require(content.cards.first)
        #expect(card.title != "fix auth bug")
        #expect(card.subtitle == nil)
        #expect(!card.chips.contains("Ghostty"))
    }

    @Test
    func `host chip appears only when a terminal was resolved`() throws {
        let content = IslandContent(
            card: nil,
            aggregates: aggregates([
                session(.claude, id: "a", status: .running, minutesAgo: 5, now: self.now),
                session(.codex, id: "b", status: .running, minutesAgo: 6, now: self.now),
            ]),
            attention: nil,
            hosts: ["claude:a": "iTerm"],
            hidePersonalInfo: false,
            now: self.now)

        let resolved = try #require(content.cards.first { $0.id == "claude:a" })
        let unresolved = try #require(content.cards.first { $0.id == "codex:b" })
        #expect(resolved.chips == ["Claude", "iTerm"])
        #expect(unresolved.chips == ["Codex"])
    }

    @Test
    func `only finished sessions advertise a jump`() {
        let content = IslandContent(
            card: nil,
            aggregates: aggregates([
                session(.claude, id: "a", status: .completed, minutesAgo: 2, now: self.now),
                session(.codex, id: "b", status: .running, minutesAgo: 2, now: self.now),
            ]),
            attention: nil,
            hidePersonalInfo: false,
            now: self.now)

        #expect(content.cards.filter(\.isJumpTarget).map(\.id) == ["claude:a"])
    }

    @Test
    func `no usage data means no usage strip rather than a fake reading`() {
        let content = IslandContent(
            card: nil,
            aggregates: [:],
            attention: nil,
            hidePersonalInfo: false,
            now: self.now)

        #expect(content.usage == nil)
        #expect(content.cards.isEmpty)
        #expect(content.sessionCount == 0)
        #expect(content.leadStatus == .idle)
    }

    @Test
    func `attention detail only exists while a session is blocked`() throws {
        func detail(_ kind: AgentTaskEventKind) -> IslandAttentionDetail? {
            let event = AgentTaskEvent(
                id: "e",
                provider: .claude,
                sessionID: "s",
                turnID: nil,
                kind: kind,
                occurredAt: self.now,
                projectPath: "/Users/dev/api-server",
                transcriptPath: nil,
                taskTitle: nil,
                source: .hook)
            return IslandAttentionDetail(
                attention: AgentTaskAttention(event: event),
                hidePersonalInfo: false)
        }

        #expect(detail(.turnCompleted) == nil)
        let blocked = try #require(detail(.approvalRequested))
        #expect(blocked.status == .needsApproval)
        #expect(blocked.title == "api-server")
        #expect(blocked.project == "/Users/dev/api-server")
    }

    @Test
    func `acknowledgement text rides along without disturbing the list`() {
        let base = IslandContent(
            card: nil,
            aggregates: aggregates([
                session(.claude, id: "a", status: .completed, minutesAgo: 1, now: self.now),
            ]),
            attention: nil,
            hidePersonalInfo: false,
            now: self.now)
        let acknowledged = base.acknowledging("Jumped")

        #expect(base.acknowledgement == nil)
        #expect(acknowledged.acknowledgement == "Jumped")
        #expect(acknowledged.cards == base.cards)
    }
}
