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
            containerDuration: 0.30,
            radiusDuration: 0.30,
            opacityDuration: 0.18,
            blurDuration: 0.14,
            scaleDuration: 0.14,
            contentDelay: 0.06,
            blurRadius: 0,
            hiddenScale: 1)
    }

    static func container(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? .easeOut(duration: 0.14)
            : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.30)
    }

    static func radius(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? 0.14 : 0.30)
    }

    static func opacity(reduceMotion: Bool) -> Animation {
        .easeOut(duration: reduceMotion ? 0.14 : 0.18)
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

struct NotchIndicatorMotionProfile: Equatable {
    let minimumOpacity: Double
    let maximumOpacity: Double
    let duration: Double?
}

enum NotchIndicatorMotion {
    static func dot(state: NotchIndicatorState, reduceMotion: Bool) -> NotchIndicatorMotionProfile {
        switch state {
        case .hidden:
            NotchIndicatorMotionProfile(minimumOpacity: 0, maximumOpacity: 0, duration: nil)
        case .idle:
            NotchIndicatorMotionProfile(minimumOpacity: 0.30, maximumOpacity: 0.30, duration: nil)
        case .running:
            if reduceMotion {
                NotchIndicatorMotionProfile(minimumOpacity: 1, maximumOpacity: 1, duration: nil)
            } else {
                NotchIndicatorMotionProfile(minimumOpacity: 0.35, maximumOpacity: 1, duration: 2.4)
            }
        case .attention:
            NotchIndicatorMotionProfile(minimumOpacity: 1, maximumOpacity: 1, duration: nil)
        }
    }

    static func edge(reduceMotion: Bool) -> NotchIndicatorMotionProfile {
        reduceMotion
            ? NotchIndicatorMotionProfile(minimumOpacity: 1, maximumOpacity: 1, duration: nil)
            : NotchIndicatorMotionProfile(minimumOpacity: 0.35, maximumOpacity: 1, duration: 1.2)
    }
}
