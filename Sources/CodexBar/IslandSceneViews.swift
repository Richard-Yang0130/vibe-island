import CodexBarCore
import SwiftUI

/// Layout tokens transcribed from the interaction prototype. The density only works because the
/// numeric columns are monospaced — swap the mono font for a proportional one and the session list
/// stops lining up immediately.
enum IslandLayout {
    static let paneHorizontalPadding: CGFloat = 16
    static let paneTopPadding: CGFloat = 11
    static let paneBottomPadding: CGFloat = 12
    static let paneSpacing: CGFloat = 8

    static let usageFontSize: CGFloat = 10.5
    static let usageBottomPadding: CGFloat = 9

    static let cardSpacing: CGFloat = 9
    static let cardPadding: CGFloat = 8
    static let cardRadius: CGFloat = 10
    static let cardTitleSize: CGFloat = 13
    static let cardSubtitleSize: CGFloat = 11

    static let chipFontSize: CGFloat = 10
    static let chipRadius: CGFloat = 6

    static let compactSpacing: CGFloat = 9
    static let compactLabelSize: CGFloat = 11
}

extension Color {
    /// Prototype text ramp.
    fileprivate static let islandText1 = Color(white: 0xF0 / 255)
    fileprivate static let islandText2 = Color.white.opacity(0.72)
    fileprivate static let islandText3 = Color(white: 0x8A / 255)
    fileprivate static let islandText4 = Color.white.opacity(0.40)
    fileprivate static let islandDivider = Color.white.opacity(0.06)
    fileprivate static let islandCardHover = Color.white.opacity(0.04)
}

// MARK: - Compact

/// The ambient strip: what the island shows when nothing needs you.
///
/// Content lives in the wings on either side of the camera housing, never across it. The left wing
/// says who and what; the right wing carries the always-visible quota reading.
struct IslandCompactStrip: View {
    let presentation: IslandShellPresentation
    let content: IslandContent
    let reduceMotion: Bool

    private var sideWidth: CGFloat {
        max(0, (self.presentation.bodyWidth - self.presentation.anchorSize.width) / 2)
    }

    private var quota: IslandUsageMetric? {
        self.content.usage?.compactReading
    }

    var body: some View {
        ZStack {
            HStack(spacing: IslandLayout.compactSpacing) {
                IslandCompanionView(
                    index: self.content.cards.first?.companionIndex ?? 0,
                    status: self.content.leadStatus,
                    reduceMotion: self.reduceMotion,
                    size: min(30, self.presentation.height),
                    statusUpdatedAt: self.content.cards.first?.statusUpdatedAt)
                Image(systemName: self.content.leadStatus.requiresUserAction ? "exclamationmark" : "circle.fill")
                    .font(.system(size: self.content.leadStatus.requiresUserAction ? 10 : 5, weight: .bold))
                    .foregroundStyle(self.content.leadStatus.islandColor.color)
                    .accessibilityHidden(true)
                if !self.presentation.hasPhysicalNotch {
                    Text(self.content.compactLabel)
                        .font(.system(size: IslandLayout.compactLabelSize).monospacedDigit())
                        .foregroundStyle(
                            self.content.leadStatus == .running
                                ? Color.islandText2
                                : self.content.leadStatus.islandColor.color)
                        .lineLimit(1)
                }
            }
            .frame(width: self.sideWidth, alignment: .leading)
            .padding(.leading, 4)
            .clipped()
            .position(x: self.sideWidth / 2, y: self.presentation.height / 2)

            self.trailing
                .frame(width: self.sideWidth, alignment: .trailing)
                .padding(.trailing, 4)
                .clipped()
                .position(
                    x: self.presentation.bodyWidth - self.sideWidth / 2,
                    y: self.presentation.height / 2)
        }
        .frame(width: self.presentation.bodyWidth, height: self.presentation.height)
    }

    @ViewBuilder
    private var trailing: some View {
        if let quota = self.quota {
            Text(quota.percentText)
                .font(.system(size: IslandLayout.compactLabelSize).monospacedDigit())
                .foregroundStyle(IslandQuotaColor.color(usedFraction: quota.usedFraction))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        } else {
            Text("\(self.content.sessionCount)")
                .font(.system(size: IslandLayout.compactLabelSize).monospacedDigit())
                .foregroundStyle(Color.islandText3)
        }
    }
}

// MARK: - Usage strip

/// Quota header shared by every expanded scene. Absent entirely when there is no real usage data,
/// rather than showing a placeholder number that looks like a reading.
struct IslandUsageStripView: View {
    let usage: IslandUsageStrip

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(self.usage.metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Text("|")
                        .foregroundStyle(.white.opacity(0.14))
                        .padding(.horizontal, IslandLayout.usageBottomPadding)
                }
                HStack(spacing: 5) {
                    if index == 0 {
                        Text(self.usage.providerName)
                            .fontWeight(.bold)
                            .foregroundStyle(Color.islandText1)
                    }
                    Text(metric.window)
                    Text(metric.percentText)
                        .fontWeight(.bold)
                        .foregroundStyle(IslandQuotaColor.color(usedFraction: metric.usedFraction))
                    if let reset = metric.resetText {
                        Text(reset).foregroundStyle(Color.islandText4)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.custom(IslandShellFont.familyName, size: IslandLayout.usageFontSize))
        .foregroundStyle(Color.islandText3)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            if let metric = self.usage.metrics.first {
                GeometryReader { geometry in
                    Capsule().fill(.white.opacity(0.08))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(IslandQuotaColor.color(usedFraction: metric.usedFraction))
                                .frame(width: geometry.size.width * min(1, max(0, metric.usedFraction)))
                        }
                }
                .frame(height: 3)
                .accessibilityHidden(true)
            }
        }
        .padding(.top, IslandLayout.usageBottomPadding)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.islandDivider).frame(height: 1)
        }
    }
}

// MARK: - Chips

private struct IslandChip: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(self.text)
            .font(.system(size: IslandLayout.chipFontSize))
            .foregroundStyle(self.tint ?? Color.islandText3)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                (self.tint ?? .white).opacity(self.tint == nil ? 0.06 : 0.13),
                in: RoundedRectangle(cornerRadius: IslandLayout.chipRadius))
            .fixedSize()
    }
}

// MARK: - Session card

struct IslandSessionCardView: View {
    let card: IslandSessionCard
    let isSelected: Bool
    let reduceMotion: Bool
    let onTap: (IslandSessionCard) -> Void

    @State private var isHovering = false

    var body: some View {
        Button { self.onTap(self.card) } label: {
            HStack(spacing: 10) {
                IslandCompanionView(
                    index: self.card.companionIndex,
                    status: self.card.status,
                    reduceMotion: self.reduceMotion,
                    statusUpdatedAt: self.card.statusUpdatedAt)
                VStack(alignment: .leading, spacing: 5) {
                    Text(self.card.title)
                        .font(.system(size: IslandLayout.cardTitleSize, weight: .semibold))
                        .foregroundStyle(Color.islandText1)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(self.card.chips.joined(separator: " · "))
                            .foregroundStyle(IslandAgentColor.color(for: self.card.provider))
                        if let subtitle = self.card.subtitle {
                            Text(subtitle).foregroundStyle(Color.islandText3)
                        }
                    }
                    .font(.system(size: 10.5))
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(self.card.status.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(self.card.status.islandColor.color)
                    if let duration = self.card.duration {
                        Text(duration)
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(Color.islandText3)
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 7)
            .frame(height: IslandSceneMetrics.sessionRowHeight)
            .background(self.background, in: RoundedRectangle(cornerRadius: IslandLayout.cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.card.title), \(self.card.status.displayName)")
    }

    private var background: Color {
        if self.isSelected { return .white.opacity(0.08) }
        return self.isHovering ? .islandCardHover : .clear
    }
}

// MARK: - Pane scaffold

private struct IslandPane<Content: View>: View {
    let usage: IslandUsageStrip?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: IslandLayout.paneSpacing) {
            self.content
            Spacer(minLength: 0)
            if let usage {
                IslandUsageStripView(usage: usage)
            }
        }
        .padding(.horizontal, IslandLayout.paneHorizontalPadding)
        .padding(.top, IslandLayout.paneTopPadding)
        .padding(.bottom, IslandLayout.paneBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Scenes

struct IslandOverviewPane: View {
    let content: IslandContent
    let reduceMotion: Bool
    let onOpenSession: (IslandSessionCard) -> Void

    var body: some View {
        IslandPane(usage: self.content.usage) {
            if self.content.cards.isEmpty {
                Text(L("agent_task_none"))
                    .font(.system(size: IslandLayout.cardTitleSize))
                    .foregroundStyle(Color.islandText4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // Every running session, not a "+N" that hides the one you were looking for. The
                // island grows to fit; past `maxVisibleSessions` the list scrolls instead.
                ScrollView {
                    LazyVStack(spacing: IslandSceneMetrics.sessionRowSpacing) {
                        ForEach(self.content.cards) { card in
                            IslandSessionCardView(
                                card: card,
                                isSelected: false,
                                reduceMotion: self.reduceMotion,
                                onTap: self.onOpenSession)
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
    }
}

/// Approval and question share a layout: state header, the blocked session, and the one action we
/// can honestly offer. See `IslandAttentionDetail` for why there are no decision buttons yet.
struct IslandAttentionPane: View {
    let content: IslandContent
    let detail: IslandAttentionDetail
    let scene: IslandScene
    let reduceMotion: Bool
    let onOpenSession: (IslandSessionCard) -> Void
    let onDismiss: () -> Void

    private var tint: Color {
        (self.scene == .ask ? IslandStatusColor.question : self.detail.status.islandColor).color
    }

    var body: some View {
        IslandPane(usage: self.content.usage) {
            HStack(spacing: 6) {
                IslandCompanionView(
                    index: self.detail.companionIndex,
                    status: .needsApproval,
                    reduceMotion: self.reduceMotion,
                    size: 30)
                IslandSpriteView(
                    sprite: self.scene == .ask ? .ask : .alert,
                    color: self.tint)
                Text(self.scene == .ask
                    ? L("island_waiting_answer")
                    : self.detail.status.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(self.tint)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(self.detail.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.islandText1)
                    .lineLimit(1)
                if let project = self.detail.project {
                    Text(project)
                        .font(.custom(IslandShellFont.familyName, size: IslandLayout.cardSubtitleSize))
                        .foregroundStyle(Color.islandText4)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text(L("island_answer_in_terminal"))
                .font(.system(size: 10.5))
                .foregroundStyle(Color.islandText3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                IslandActionButton(title: L("Dismiss"), style: .quiet, action: self.onDismiss)
                IslandActionButton(title: L("agent_task_open"), style: .prominent) {
                    guard let card = self.content.cards.first(where: {
                        $0.provider == self.detail.provider && $0.sessionID == self.detail.sessionID
                    }) else { return }
                    self.onOpenSession(card)
                }
            }
        }
    }
}

/// The decidable approval. Shows the tool and the exact command, then the risk ramp.
///
/// Colour encodes escalating risk, not operation type: grey → white → orange → red. Red is not
/// "cancel", it is "give up control", which is why Deny sits at the quiet end.
struct IslandApprovalPane: View {
    let content: IslandContent
    let request: IslandApprovalRequest
    let reduceMotion: Bool
    let onDecide: (IslandApprovalRequest, AgentTaskApprovalAction) -> Void

    var body: some View {
        IslandPane(usage: self.content.usage) {
            HStack(spacing: 6) {
                IslandCompanionView(
                    index: self.request.companionIndex,
                    status: .needsApproval,
                    reduceMotion: self.reduceMotion,
                    size: 30)
                IslandSpriteView(sprite: .alert, color: IslandStatusColor.alert.color)
                Text(self.request.toolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(IslandStatusColor.alert.color)
                Spacer(minLength: 0)
                IslandChip(
                    text: IslandAgentColor.displayName(for: self.request.provider),
                    tint: IslandAgentColor.color(for: self.request.provider))
            }

            if let summary = self.request.toolSummary {
                ScrollView {
                    Text(summary)
                        .font(.custom(IslandShellFont.familyName, size: 10))
                        .foregroundStyle(Color.islandText1)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 40)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(white: 0.05),
                    in: RoundedRectangle(cornerRadius: IslandLayout.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: IslandLayout.cardRadius)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
            }

            if let project = self.request.projectPath {
                Text(project)
                    .font(.custom(IslandShellFont.familyName, size: 9.5))
                    .foregroundStyle(Color.islandText4)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 6) {
                ForEach(self.request.actions, id: \.self) { action in
                    IslandRiskButton(action: action) {
                        self.onDecide(self.request, action)
                    }
                }
            }
        }
    }
}

struct IslandApprovalFailurePane: View {
    let usage: IslandUsageStrip?
    let request: IslandApprovalRequest
    let onOpenSession: (IslandSessionCard) -> Void
    let onDismiss: () -> Void

    var body: some View {
        IslandPane(usage: self.usage) {
            Text(L("island_approval_delivery_failed"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandStatusColor.danger.color)
            Text(self.request.toolName)
                .font(.system(size: 11))
                .foregroundStyle(Color.islandText2)
            Text(L("island_answer_in_terminal"))
                .font(.system(size: 10.5))
                .foregroundStyle(Color.islandText3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                IslandActionButton(title: L("Dismiss"), style: .quiet, action: self.onDismiss)
                IslandActionButton(title: L("agent_task_open"), style: .prominent) {
                    guard let sessionID = self.request.sessionID else { return }
                    self.onOpenSession(IslandSessionCard(
                        id: self.request.id,
                        sessionID: sessionID,
                        provider: self.request.provider,
                        status: .failed,
                        title: self.request.toolName,
                        subtitle: nil,
                        chips: [],
                        duration: nil))
                }
                .disabled(self.request.sessionID == nil)
            }
        }
    }
}

private struct IslandRiskButton: View {
    let action: AgentTaskApprovalAction
    let perform: () -> Void

    @State private var isHovering = false

    private var title: String {
        switch self.action {
        case .deny: L("Deny")
        case .allowOnce: L("island_allow_once")
        case .allowAlways: L("island_allow_all")
        case .bypass: L("island_bypass")
        }
    }

    private var background: Color {
        switch self.action {
        case .deny: .white.opacity(0.06)
        case .allowOnce: Color(white: 0.94)
        case .allowAlways: IslandStatusColor.alert.color
        case .bypass: IslandStatusColor.danger.color
        }
    }

    private var foreground: Color {
        switch self.action {
        case .deny: .islandText1
        case .allowOnce, .allowAlways: Color(white: 0.10)
        case .bypass: .white
        }
    }

    var body: some View {
        Button(action: self.perform) {
            Text(self.title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(self.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(self.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(self.isHovering ? 0.14 : 0))
                }
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
        .accessibilityLabel(self.title)
    }
}

struct IslandDonePane: View {
    let content: IslandContent
    let reduceMotion: Bool
    let onOpenSession: (IslandSessionCard) -> Void

    var body: some View {
        IslandPane(usage: self.content.usage) {
            ScrollView {
                LazyVStack(spacing: IslandSceneMetrics.sessionRowSpacing) {
                    ForEach(self.content.cards) { card in
                        IslandSessionCardView(
                            card: card,
                            isSelected: false,
                            reduceMotion: self.reduceMotion,
                            onTap: self.onOpenSession)
                    }
                }
            }
            .scrollIndicators(.visible)
            Text(L("island_jump_hint"))
                .font(.system(size: 10))
                .foregroundStyle(Color.islandText4)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

/// Narrow confirmation strip. Falls back to `compact` on its own so it never interrupts whatever
/// the user went back to doing.
struct IslandAckStrip: View {
    let content: IslandContent
    let reduceMotion: Bool

    var body: some View {
        HStack(spacing: 8) {
            IslandCompanionView(
                index: self.content.cards.first?.companionIndex ?? 0,
                status: .completed,
                reduceMotion: self.reduceMotion)
            Text(self.content.acknowledgement ?? "")
                .font(.custom(IslandShellFont.familyName, size: 11))
                .foregroundStyle(IslandStatusColor.idle.color)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Buttons

private struct IslandActionButton: View {
    enum Style {
        case quiet
        case prominent
    }

    let title: String
    let style: Style
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            Text(self.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(self.style == .prominent ? .black : Color.islandText1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(self.background, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
    }

    private var background: Color {
        switch self.style {
        case .quiet: .white.opacity(self.isHovering ? 0.12 : 0.06)
        case .prominent: Color(white: self.isHovering ? 1 : 0.94)
        }
    }
}
