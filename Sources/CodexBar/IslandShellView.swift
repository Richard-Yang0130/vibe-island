import SwiftUI

struct IslandShellShape: Shape {
    var shoulderRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(self.shoulderRadius, self.bottomRadius) }
        set {
            self.shoulderRadius = newValue.first
            self.bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = max(0, min(self.shoulderRadius, rect.width / 2))
        let bottom = max(0, min(self.bottomRadius, min(rect.height, rect.width / 2)))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder, y: rect.minY + shoulder),
            control: CGPoint(x: rect.minX + shoulder, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + shoulder + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + shoulder, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - shoulder, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct IslandShellActions {
    let toggleExpanded: @MainActor () -> Void
    let hoverEntered: @MainActor () -> Void
}

struct IslandShellView: View {
    let presentation: IslandShellPresentation
    let reduceMotion: Bool
    let actions: IslandShellActions

    private var shape: IslandShellShape {
        IslandShellShape(
            shoulderRadius: self.presentation.shoulderRadius,
            bottomRadius: self.presentation.bottomRadius)
    }

    var body: some View {
        ZStack {
            Color.black
            self.contentLayers
        }
        .frame(
            width: self.presentation.totalWidth,
            height: self.presentation.height,
            alignment: .top)
        .clipShape(self.shape)
        .overlay {
            self.shape.stroke(
                LinearGradient(
                    colors: [
                        .clear,
                        .white.opacity(self.presentation.phase == .expanded ? 0.08 : 0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom),
                lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.60), radius: 8, y: 2)
        .shadow(color: .black.opacity(0.30), radius: 24, y: 8)
        .shadow(
            color: .white.opacity(self.presentation.phase == .expanded ? 0.04 : 0),
            radius: 15)
        .contentShape(self.shape)
        .onTapGesture { self.actions.toggleExpanded() }
        .onHover { inside in
            if inside { self.actions.hoverEntered() }
        }
        .animation(
            IslandShellMotion.container(reduceMotion: self.reduceMotion),
            value: self.presentation.totalWidth)
        .animation(
            IslandShellMotion.container(reduceMotion: self.reduceMotion),
            value: self.presentation.height)
        .animation(
            IslandShellMotion.radius(reduceMotion: self.reduceMotion),
            value: self.presentation.bottomRadius)
    }

    private var contentLayers: some View {
        let compactVisible = self.presentation.phase == .compact
        let expandedVisible = self.presentation.phase == .expanded
        let profile = IslandShellMotion.profile(reduceMotion: self.reduceMotion)

        return ZStack {
            IslandCompactFixtureView(fixture: self.presentation.fixture)
                .opacity(compactVisible ? 1 : 0)
                .blur(radius: compactVisible ? 0 : profile.blurRadius)
                .scaleEffect(compactVisible ? 1 : profile.hiddenScale)
                .animation(
                    IslandShellMotion.opacity(reduceMotion: self.reduceMotion),
                    value: compactVisible)
                .animation(
                    IslandShellMotion.blur(reduceMotion: self.reduceMotion),
                    value: compactVisible)
                .animation(
                    IslandShellMotion.scale(reduceMotion: self.reduceMotion),
                    value: compactVisible)

            IslandExpandedFixtureView(fixture: self.presentation.fixture)
                .opacity(expandedVisible ? 1 : 0)
                .blur(radius: expandedVisible ? 0 : profile.blurRadius)
                .scaleEffect(expandedVisible ? 1 : profile.hiddenScale)
                .animation(
                    IslandShellMotion.opacity(reduceMotion: self.reduceMotion),
                    value: expandedVisible)
                .animation(
                    IslandShellMotion.blur(reduceMotion: self.reduceMotion),
                    value: expandedVisible)
                .animation(
                    IslandShellMotion.scale(reduceMotion: self.reduceMotion),
                    value: expandedVisible)
        }
    }
}
