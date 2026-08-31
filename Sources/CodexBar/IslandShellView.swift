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
    let indicators: NotchCollapsedPresentation
    let reduceMotion: Bool
    let actions: IslandShellActions

    private var shape: IslandShellShape {
        IslandShellShape(
            shoulderRadius: self.presentation.shoulderRadius,
            bottomRadius: self.presentation.bottomRadius)
    }

    var body: some View {
        self.surface
            .overlay {
                if self.presentation.phase == .compact {
                    IslandCompactStatusView(
                        indicators: self.indicators,
                        reduceMotion: self.reduceMotion)
                }
            }
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

    private var surface: some View {
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
    }

    private var contentLayers: some View {
        let compactVisible = self.presentation.phase == .compact && !self.presentation.hasPhysicalNotch
        let expandedVisible = self.presentation.phase == .expanded
        let profile = IslandShellMotion.profile(reduceMotion: self.reduceMotion)

        return ZStack {
            IslandCompactFixtureView(presentation: self.presentation)
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

private struct IslandCompactStatusView: View {
    let indicators: NotchCollapsedPresentation
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(self.indicators.lights.filter(\.showsEdgeGlow)) { light in
                    IslandAttentionEdge(light: light, reduceMotion: self.reduceMotion)
                }
                ForEach(self.indicators.lights.filter { $0.state != .hidden }) { light in
                    IslandStatusDot(light: light, reduceMotion: self.reduceMotion)
                        .position(
                            x: light.side == .left ? -2.5 : geometry.size.width + 2.5,
                            y: geometry.size.height / 2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct IslandStatusDot: View {
    let light: NotchLightPresentation
    let reduceMotion: Bool
    @State private var isBright = false

    private var profile: NotchIndicatorMotionProfile {
        NotchIndicatorMotion.dot(state: self.light.state, reduceMotion: self.reduceMotion)
    }

    var body: some View {
        Circle()
            .fill(self.light.color.swiftUIColor)
            .frame(width: 5, height: 5)
            .shadow(color: self.light.color.swiftUIColor.opacity(0.75), radius: 3)
            .opacity(self.isBright ? self.profile.maximumOpacity : self.profile.minimumOpacity)
            .onAppear { self.startAnimation() }
            .onChange(of: self.light.state) { _, _ in self.startAnimation() }
            .onChange(of: self.reduceMotion) { _, _ in self.startAnimation() }
    }

    private func startAnimation() {
        self.isBright = self.profile.duration == nil
        guard let duration = self.profile.duration else { return }
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            self.isBright = true
        }
    }
}

private struct IslandAttentionEdge: View {
    let light: NotchLightPresentation
    let reduceMotion: Bool
    @State private var isBright = false

    private var profile: NotchIndicatorMotionProfile {
        NotchIndicatorMotion.edge(reduceMotion: self.reduceMotion)
    }

    var body: some View {
        IslandHalfEdgeShape(side: self.light.side)
            .stroke(self.light.color.swiftUIColor, lineWidth: 1)
            .shadow(color: self.light.color.swiftUIColor.opacity(0.8), radius: 4)
            .opacity(self.isBright ? self.profile.maximumOpacity : self.profile.minimumOpacity)
            .onAppear { self.startAnimation() }
            .onChange(of: self.reduceMotion) { _, _ in self.startAnimation() }
    }

    private func startAnimation() {
        self.isBright = self.profile.duration == nil
        guard let duration = self.profile.duration else { return }
        withAnimation(.easeInOut(duration: duration).repeatForever(autoreverses: true)) {
            self.isBright = true
        }
    }
}

private struct IslandHalfEdgeShape: Shape {
    let side: NotchIndicatorSide

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        if self.side == .left {
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
