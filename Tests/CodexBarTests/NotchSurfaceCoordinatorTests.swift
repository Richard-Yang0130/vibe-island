import CoreGraphics
import Testing
@testable import CodexBar

struct NotchSurfaceCoordinatorTests {
    @Test
    func `surface reconciliation creates and removes exact display ids`() {
        let change = NotchSurfaceReconciler.diff(existing: [1, 2], desired: [2, 3])

        #expect(change.added == [3])
        #expect(change.removed == [1])
        #expect(change.retained == [2])
    }

    @Test
    func `fullscreen suppresses hover and click but not task attention`() {
        #expect(!NotchSurfaceVisibilityPolicy.shouldExpand(trigger: .hover, isFullscreen: true))
        #expect(!NotchSurfaceVisibilityPolicy.shouldExpand(trigger: .click, isFullscreen: true))
        #expect(NotchSurfaceVisibilityPolicy.shouldExpand(trigger: .taskAttention, isFullscreen: true))
    }

    @Test
    func `fullscreen detector requires a window to cover the target display`() {
        let screen = CGRect(x: 1920, y: -200, width: 2560, height: 1440)

        #expect(NotchFullscreenDetector.coversDisplay(windowFrame: screen, screenFrame: screen))
        #expect(!NotchFullscreenDetector.coversDisplay(
            windowFrame: screen.insetBy(dx: 0, dy: 24),
            screenFrame: screen))
    }
}
