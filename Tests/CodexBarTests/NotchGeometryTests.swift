import AppKit
import CoreGraphics
import Testing
@testable import CodexBar

struct NotchGeometryTests {
    @Test
    func `layout derives the notch rect from both auxiliary menu bar areas`() throws {
        let layout = try #require(NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 932),
            leftArea: CGRect(x: 0, y: 904, width: 642, height: 28),
            rightArea: CGRect(x: 798, y: 904, width: 642, height: 28)))

        #expect(layout.anchorRect == CGRect(x: 642, y: 904, width: 156, height: 28))
        #expect(layout.hasPhysicalNotch)
    }

    @Test
    func `dormant frame hugs the notch and reaches slightly below it`() throws {
        let layout = try #require(NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 932),
            leftArea: CGRect(x: 0, y: 904, width: 642, height: 28),
            rightArea: CGRect(x: 798, y: 904, width: 642, height: 28)))

        #expect(layout.dormantFrame.midX == layout.anchorRect.midX)
        #expect(layout.dormantFrame.maxY == 932)
        #expect(layout.dormantFrame.width == layout.anchorRect.width + NotchGeometry.dormantSideGrab * 2)
        #expect(layout.dormantFrame.height == layout.anchorRect.height + NotchGeometry.dormantBottomGrab)
        #expect(layout.dormantFrame.minY < layout.anchorRect.minY)
    }

    @Test
    func `stage frame is centered on the notch and anchored to the top of the screen`() throws {
        let layout = try #require(NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 932),
            leftArea: CGRect(x: 0, y: 904, width: 642, height: 28),
            rightArea: CGRect(x: 798, y: 904, width: 642, height: 28),
            stageWidth: 600,
            stageHeight: 520))

        #expect(layout.stageFrame == CGRect(x: 420, y: 412, width: 600, height: 520))
        #expect(layout.stageFrame.midX == layout.anchorRect.midX)
        #expect(layout.stageFrame.maxY == 932)
        #expect(layout.stageFrame.height > layout.dormantFrame.height)
    }

    @Test
    func `layout clamps oversized frames to the screen bounds`() throws {
        let layout = try #require(NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 180, height: 200),
            leftArea: CGRect(x: 0, y: 172, width: 70, height: 28),
            rightArea: CGRect(x: 110, y: 172, width: 70, height: 28),
            stageWidth: 600,
            stageHeight: 520))

        #expect(layout.stageFrame == CGRect(x: 0, y: 0, width: 180, height: 200))
        #expect(layout.dormantFrame.minX >= 0)
        #expect(layout.dormantFrame.maxX <= 180)
    }

    @Test
    func `notchless layout creates a centered floating anchor below the menu bar`() throws {
        let layout = try #require(NotchGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 932),
            leftArea: nil,
            rightArea: nil,
            menuBarHeight: 25))

        #expect(!layout.hasPhysicalNotch)
        #expect(layout.anchorRect.midX == 720)
        #expect(abs(layout.anchorRect.maxY - (932 - 25 - 6)) < 0.0001)
    }

    @Test
    func `notchless anchor honors negative and offset display origins`() throws {
        let layout = try #require(NotchGeometry.layout(
            screenFrame: CGRect(x: 1920, y: -200, width: 2560, height: 1440),
            leftArea: nil,
            rightArea: nil,
            menuBarHeight: 25))

        #expect(layout.anchorRect.midX == 3200)
        #expect(abs(layout.anchorRect.maxY - (1240 - 25 - 6)) < 0.0001)
        #expect(layout.stageFrame.minX >= 1920)
        #expect(layout.stageFrame.minY >= -200)
    }

    @MainActor
    @Test
    func `island grows out of the notch as the phase advances`() {
        let state = NotchBarState()
        state.notchSize = CGSize(width: 156, height: 32)

        state.phase = .dormant
        #expect(state.totalWidth == 156)
        #expect(state.islandHeight == 40)
        #expect(state.shoulderRadius == 0)

        state.phase = .peek
        #expect(state.totalWidth > 156)
        #expect(state.islandHeight == 40)
        #expect(state.shoulderRadius == NotchGeometry.shoulderRadius)

        state.phase = .expanded
        #expect(state.totalWidth >= NotchGeometry.expandedBodyWidth)
        #expect(state.islandHeight > 32)
    }

    @MainActor
    @Test
    func `detail plan still reserves room when no usage data has arrived`() {
        let plan = NotchDetailPlan(card: nil)

        #expect(plan.primary == nil)
        #expect(plan.visibleRowCount == 0)
        #expect(plan.rowsHeight == 0)
        #expect(plan.stats.isEmpty)
        #expect(plan.height == NotchDetailPlan.heroHeight
            + NotchDetailPlan.footerHeight
            + NotchDetailPlan.bottomInset)
        #expect(!plan.emptyMessage.isEmpty)
    }

    @MainActor
    @Test
    func `panel can host controls without stealing main window status`() {
        let panel = NotchBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
    }

    @MainActor
    @Test
    func `panel refuses to be pushed out from under the menu bar`() {
        let panel = NotchBarPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        let proposed = NSRect(x: 100, y: 800, width: 500, height: 400)

        #expect(panel.constrainFrameRect(proposed, to: nil) == proposed)
    }

    @Test
    func `stage window passes clicks through outside the visible island`() {
        let hoverZone = CGRect(x: 600, y: 700, width: 240, height: 180)

        #expect(!NotchMouseEventPolicy.ignoresMouseEvents(
            pointerLocation: CGPoint(x: 720, y: 800),
            hoverZone: hoverZone))
        #expect(NotchMouseEventPolicy.ignoresMouseEvents(
            pointerLocation: CGPoint(x: 720, y: 500),
            hoverZone: hoverZone))
    }

    @Test
    func `accent ramp escalates from calm to critical as the quota drains`() {
        let calm = NotchPalette.accent(usedFraction: 0.2)
        let warning = NotchPalette.accent(usedFraction: 0.7)
        let critical = NotchPalette.accent(usedFraction: 0.95)

        #expect(calm.start == NotchPalette.mint)
        #expect(warning.start == NotchPalette.sun)
        #expect(critical.start == NotchPalette.coral)
    }

    @Test
    func `used fraction inverts metrics that count remaining quota`() {
        let remaining = UsageMenuCardView.Model.Metric(
            id: "left",
            title: "Session",
            percent: 30,
            percentStyle: .left,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false)
        let used = UsageMenuCardView.Model.Metric(
            id: "used",
            title: "Session",
            percent: 30,
            percentStyle: .used,
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: false)

        #expect(abs(NotchPalette.usedFraction(for: remaining) - 0.7) < 0.0001)
        #expect(abs(NotchPalette.usedFraction(for: used) - 0.3) < 0.0001)
    }
}
