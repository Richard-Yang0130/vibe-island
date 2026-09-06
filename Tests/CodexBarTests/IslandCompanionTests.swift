import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct IslandCompanionTests {
    @Test
    func `automatic assignment survives order changes restarts and overflow`() throws {
        let suite = "IslandCompanionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = IslandCompanionAssignments(defaults: defaults)
        let keys = (0..<10).map { "codex:session-\($0)" }
        let original = store.assign(keys: keys)
        #expect(Set(original.values).count == 10)
        #expect(store.assign(keys: keys.reversed()) == original)
        let restored = IslandCompanionAssignments(defaults: defaults)
        #expect(restored.assign(keys: keys) == original)
        let expanded = restored.assign(keys: keys + ["claude:session-0"])
        #expect(expanded.count == 11)
        #expect(keys.allSatisfy { expanded[$0] == original[$0] })
        #expect(expanded.values.allSatisfy { (0..<10).contains($0) })
        let fresh = restored.assign(keys: ["claude:new-1", "claude:new-2"])
        #expect(Set(fresh.values).count == 2)
        #expect(restored.assign(keys: keys) == original)
    }

    @Test
    func `all ten bundled companions contain aligned decodable frames`() {
        #expect(IslandCompanionArtwork.entries.count == 10)
        for (index, entry) in IslandCompanionArtwork.entries.enumerated() {
            #expect(IslandCompanionArtwork.image(index: index) != nil)
            #expect(entry.frames.count == 6)
            #expect(entry.frames.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        }
        #expect(IslandCompanionArtwork.image(index: -1) == nil)
        #expect(IslandCompanionArtwork.image(index: 10) == nil)
    }

    @Test
    func `content binding keeps cards and attention on the same character`() throws {
        let suite = "IslandCompanionContent.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cards = ["one", "two"].map { id in
            IslandSessionCard(
                id: "claude:\(id)",
                sessionID: id,
                provider: .claude,
                status: .needsApproval,
                title: id,
                subtitle: nil,
                chips: ["Claude"],
                duration: nil)
        }
        let content = IslandContent(
            usage: nil,
            cards: cards,
            attention: IslandAttentionDetail(
                provider: .claude, status: .needsApproval, title: "two", project: nil, sessionID: "two"),
            compactLabel: "waiting",
            sessionCount: 2,
            leadProvider: .claude,
            leadStatus: .needsApproval,
            acknowledgement: nil)
            .assigningCompanions(using: IslandCompanionAssignments(defaults: defaults))
        #expect(content.cards[0].companionIndex != content.cards[1].companionIndex)
        #expect(content.attention?.companionIndex == content.cards[1].companionIndex)
        #expect(content.acknowledging("done").cards == content.cards)
    }

    @Test
    func `motion cycles paws and completes once while reduced motion preserves attention`() {
        #expect([0.0, 0.2, 0.4, 0.6, 0.8, 1.2].map {
            IslandCompanionMotion.frame(status: .running, elapsed: $0, reduceMotion: false)
        } == [0, 1, 0, 2, 0, 0])
        #expect(IslandCompanionMotion.frame(status: .completed, elapsed: 0.5, reduceMotion: false) == 4)
        #expect(IslandCompanionMotion.frame(status: .completed, elapsed: 0.9, reduceMotion: false) == 0)
        #expect(IslandCompanionMotion.frame(status: .running, elapsed: 0.6, reduceMotion: true) == 0)
        #expect(IslandCompanionMotion.frame(status: .needsApproval, elapsed: 2, reduceMotion: true) == 3)
        #expect(IslandCompanionMotion.frame(status: .failed, elapsed: 2, reduceMotion: true) == 5)
    }
}
