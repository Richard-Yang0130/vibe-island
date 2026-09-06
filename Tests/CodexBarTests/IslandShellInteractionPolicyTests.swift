import CoreGraphics
import Foundation
import Testing
@testable import CodexBar

struct IslandShellInteractionPolicyTests {
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
            now: collapsedAt.addingTimeInterval(0.31),
            collapsedAt: collapsedAt))
    }
}
