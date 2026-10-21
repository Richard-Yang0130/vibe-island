import CodexBarCore
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
    let openSession: @MainActor (IslandSessionCard) -> Void
    let dismiss: @MainActor () -> Void
    let decide: @MainActor (IslandApprovalRequest, AgentTaskApprovalAction) -> Void
    var refresh: @MainActor () -> Void = {}
    var settings: @MainActor () -> Void = {}
    var togglePinned: @MainActor () -> Void = {}
    var selectProvider: @MainActor (UsageProvider) -> Void = { _ in }
    var providers: [UsageProvider] = []
    var pinned = false
}

/// The island container. It owns the silhouette, the glow and the cross-fade between content
/// layers; it never assembles business content itself.
///
/// Geometry and content run on two independent animation channels — the container morphs on one
/// curve while the layers cross-fade on another, 60ms later. Driving both from a single animation
/// is what produces the "list reflowing while the box resizes" look this design avoids.
struct IslandShellView: View {
    let presentation: IslandShellPresentation
    let content: IslandContent
    let reduceMotion: Bool
    let actions: IslandShellActions
    var failedApproval: IslandApprovalRequest?

    private var shape: IslandShellShape {
        IslandShellShape(
            shoulderRadius: self.presentation.shoulderRadius,
            bottomRadius: self.presentation.bottomRadius)
    }

    var body: some View {
        self.surface
            .environment(\.colorScheme, .dark)
            .contentShape(self.shape)
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
        .background {
            // Outer glow rather than a stroke: the body is pure black so it fuses with the
            // hardware notch, and a border would break that.
            if let glow = self.presentation.glow {
                self.shape
                    .fill(Color.black)
                    .shadow(
                        color: glow.color.color.opacity(glow.opacity),
                        radius: glow.radius)
            }
        }
        .animation(
            IslandShellMotion.radius(reduceMotion: self.reduceMotion),
            value: self.presentation.scene)
    }

    /// Layers hang from the top edge of the container.
    ///
    /// This alignment is load-bearing, not cosmetic. Each layer is pinned to its own scene's
    /// constant size, so the ZStack sizes itself to the *tallest* layer — 175pt for the overview.
    /// With the default centre alignment, the 28pt compact strip lands ~73pt down, far outside the
    /// 28pt silhouette it gets clipped to, and simply never appears.
    @ViewBuilder
    private var contentLayers: some View {
        let scene = self.presentation.scene
        ZStack(alignment: .top) {
            // Skipped only when compact is literally just the hardware cut-out; there are no
            // wings to draw into then.
            self.layer(scene: .compact, visible: scene == .compact && !self.presentation.compactHugsNotch) {
                Button(action: self.actions.toggleExpanded) {
                    IslandCompactStrip(
                        presentation: self.presentation,
                        content: self.content,
                        reduceMotion: self.reduceMotion)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(self.content.leadProvider.rawValue), \(self.content.leadStatus.displayName)")
            }

            self.layer(scene: .overview, visible: scene == .overview) {
                IslandOverviewPane(
                    content: self.content,
                    reduceMotion: self.reduceMotion,
                    onOpenSession: self.actions.openSession)
            }

            self.layer(scene: .approval, visible: scene == .approval || scene == .ask) {
                if let failedApproval = self.failedApproval, scene == .approval {
                    IslandApprovalFailurePane(
                        usage: self.content.usage,
                        request: failedApproval,
                        onOpenSession: self.actions.openSession,
                        onDismiss: self.actions.dismiss)
                } else if let approval = self.content.approval, scene == .approval {
                    // The decidable path: the blocking hook gave us the tool and its input.
                    IslandApprovalPane(
                        content: self.content,
                        request: approval,
                        reduceMotion: self.reduceMotion,
                        onDecide: self.actions.decide)
                } else if let detail = self.content.attention {
                    IslandAttentionPane(
                        content: self.content,
                        detail: detail,
                        scene: scene,
                        reduceMotion: self.reduceMotion,
                        onOpenSession: self.actions.openSession,
                        onDismiss: self.actions.dismiss)
                } else {
                    // The request was resolved elsewhere while the scene was up. Showing the
                    // session list beats leaving an empty black box on screen.
                    IslandOverviewPane(
                        content: self.content,
                        reduceMotion: self.reduceMotion,
                        onOpenSession: self.actions.openSession)
                }
            }

            self.layer(scene: .done, visible: scene == .done) {
                IslandDonePane(
                    content: self.content,
                    reduceMotion: self.reduceMotion,
                    onOpenSession: self.actions.openSession)
            }

            self.layer(scene: .ack, visible: scene == .ack) {
                Button(action: self.actions.toggleExpanded) {
                    IslandAckStrip(content: self.content, reduceMotion: self.reduceMotion)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(
            width: self.presentation.totalWidth,
            height: self.presentation.height,
            alignment: .top)
    }

    /// One cross-faded content layer, stacked absolutely so layers never push each other around.
    ///
    /// The frame comes from the layer's *own* scene, not from the currently animating presentation.
    /// That is the whole point: sizing content off the animating geometry re-runs the pane's layout
    /// — cards, chips, sprites, text — on every frame of the 0.5s morph, which is exactly the
    /// "container resizing drags the content along" stutter this design set out to avoid. Pinned to
    /// a constant, each pane lays out once and the container simply clips it.
    @ViewBuilder
    private func layer(
        scene: IslandScene,
        visible: Bool,
        @ViewBuilder _ body: () -> some View)
        -> some View
    {
        let profile = IslandShellMotion.profile(reduceMotion: self.reduceMotion)
        VStack(spacing: 0) {
            body()
            if scene.isExpanded { self.toolbar }
        }
        .frame(
            width: self.layoutWidth(for: scene),
            height: self.layoutHeight(for: scene),
            alignment: .top)
        .opacity(visible ? 1 : 0)
        .blur(radius: visible ? 0 : profile.blurRadius)
        .scaleEffect(visible ? 1 : profile.hiddenScale)
        .allowsHitTesting(visible)
        .accessibilityHidden(!visible)
        .environment(\.islandCompanionVisible, visible)
        .animation(IslandShellMotion.opacity(reduceMotion: self.reduceMotion), value: visible)
        .animation(IslandShellMotion.blur(reduceMotion: self.reduceMotion), value: visible)
        .animation(IslandShellMotion.scale(reduceMotion: self.reduceMotion), value: visible)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Menu {
                ForEach(self.actions.providers, id: \.self) { provider in
                    Button(provider.rawValue) { self.actions.selectProvider(provider) }
                }
            } label: {
                Image(systemName: "square.stack.3d.up")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(L("Providers"))
            .accessibilityLabel(L("Providers"))
            Button(action: self.actions.refresh) { Image(systemName: "arrow.clockwise") }
                .help(L("Refresh"))
            Spacer()
            Button(action: self.actions.togglePinned) {
                Image(systemName: self.actions.pinned ? "pin.fill" : "pin")
            }
            .help(L("Pin"))
            Button(action: self.actions.settings) { Image(systemName: "gearshape") }
                .help(L("Settings..."))
                .accessibilityLabel(L("Settings..."))
            Button(action: self.actions.toggleExpanded) { Image(systemName: "chevron.up") }
                .help(L("Dismiss"))
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.65))
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
        .frame(height: IslandSceneMetrics.toolbarHeight)
        .background(.white.opacity(0.025))
    }

    /// Constant layout width for a scene's content, independent of the animating container.
    private func layoutWidth(for scene: IslandScene) -> CGFloat {
        IslandSceneMetrics.bodyWidth(scene)
            ?? IslandShellPresentation(
                scene: scene,
                anchorSize: self.presentation.anchorSize,
                hasPhysicalNotch: self.presentation.hasPhysicalNotch,
                showsCompactQuota: self.presentation.showsCompactQuota,
                cardCount: self.presentation.cardCount).bodyWidth
    }

    private func layoutHeight(for scene: IslandScene) -> CGFloat {
        IslandSceneMetrics.height(scene, cardCount: self.presentation.cardCount)
            ?? (self.presentation.hasPhysicalNotch
                ? self.presentation.anchorSize.height
                : IslandShellMetrics.compactHeight)
    }
}
