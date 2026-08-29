import AppKit
import CoreGraphics

enum NotchSurfaceReconciler {
    struct Change: Equatable {
        let added: [CGDirectDisplayID]
        let removed: [CGDirectDisplayID]
        let retained: [CGDirectDisplayID]
    }

    static func diff(
        existing: Set<CGDirectDisplayID>,
        desired: Set<CGDirectDisplayID>)
        -> Change
    {
        Change(
            added: desired.subtracting(existing).sorted(),
            removed: existing.subtracting(desired).sorted(),
            retained: existing.intersection(desired).sorted())
    }
}

enum NotchSurfaceVisibilityPolicy {
    enum Trigger {
        case hover
        case click
        case taskAttention
    }

    static func shouldExpand(trigger: Trigger, isFullscreen: Bool) -> Bool {
        !isFullscreen || trigger == .taskAttention
    }
}

enum NotchFullscreenDetector {
    static func coversDisplay(windowFrame: CGRect, screenFrame: CGRect) -> Bool {
        let tolerance: CGFloat = 1
        return abs(windowFrame.minX - screenFrame.minX) <= tolerance
            && abs(windowFrame.minY - screenFrame.minY) <= tolerance
            && abs(windowFrame.width - screenFrame.width) <= tolerance
            && abs(windowFrame.height - screenFrame.height) <= tolerance
    }

    @MainActor
    static func isFullscreen(on screen: NSScreen) -> Bool {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let windowInfo = CGWindowListCopyWindowInfo(
                  [.optionOnScreenOnly, .excludeDesktopElements],
                  kCGNullWindowID) as? [[String: Any]]
        else { return false }

        let primaryMaxY = NSScreen.screens.first { candidate in
            guard let number = candidate.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return number.uint32Value == CGMainDisplayID()
        }?.frame.maxY ?? NSScreen.screens.first?.frame.maxY ?? 0

        return windowInfo.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                == application.processIdentifier,
                (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return false }
            let appKitFrame = CGRect(
                x: quartzFrame.minX,
                y: primaryMaxY - quartzFrame.maxY,
                width: quartzFrame.width,
                height: quartzFrame.height)
            return self.coversDisplay(windowFrame: appKitFrame, screenFrame: screen.frame)
        }
    }
}

@MainActor
final class NotchSurfaceCoordinator {
    typealias ControllerFactory = @MainActor (
        CGDirectDisplayID,
        NSScreen,
        NotchBarLayout) -> NotchBarController

    private var controllers: [CGDirectDisplayID: NotchBarController] = [:]
    private let makeController: ControllerFactory

    init(makeController: @escaping ControllerFactory) {
        self.makeController = makeController
    }

    var isActive: Bool {
        !self.controllers.isEmpty
    }

    func reconcileScreens(_ screens: [NSScreen] = NSScreen.screens) {
        let pairs: [(CGDirectDisplayID, (NSScreen, NotchBarLayout))] = screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let layout = NotchGeometry.layout(on: screen)
            else { return nil }
            return (number.uint32Value, (screen, layout))
        }
        let desired = Dictionary(uniqueKeysWithValues: pairs)
        let change = NotchSurfaceReconciler.diff(
            existing: Set(self.controllers.keys),
            desired: Set(desired.keys))

        for id in change.removed {
            self.controllers.removeValue(forKey: id)?.teardown()
        }
        for id in change.retained {
            guard let value = desired[id] else { continue }
            self.controllers[id]?.update(screen: value.0, layout: value.1)
        }
        for id in change.added {
            guard let value = desired[id] else { continue }
            self.controllers[id] = self.makeController(id, value.0, value.1)
        }
    }

    func refreshAll() {
        self.controllers.values.forEach { $0.refreshContent() }
    }

    func toggle(pointer: CGPoint = NSEvent.mouseLocation) {
        self.targetController(pointer: pointer)?.toggle()
    }

    func present(_ attention: AgentTaskAttention, pointer: CGPoint = NSEvent.mouseLocation) {
        let target = self.targetController(pointer: pointer)
        for controller in self.controllers.values {
            if controller === target {
                controller.present(attention)
            } else {
                controller.collapseForExternalAttention()
            }
        }
    }

    func expansionOrigin(pointer: CGPoint = NSEvent.mouseLocation) -> CGPoint? {
        self.targetController(pointer: pointer)?.expansionOriginInScreen
    }

    func teardown() {
        self.controllers.values.forEach { $0.teardown() }
        self.controllers.removeAll()
    }

    private func targetController(pointer: CGPoint) -> NotchBarController? {
        self.controllers.values.first { $0.screenFrame.contains(pointer) }
            ?? self.controllers.values.first { $0.isOnMainScreen }
            ?? self.controllers.values.first
    }
}
