#if DEBUG
import AppKit
import CodexBarCore
import SwiftUI

/// A separate entry point: no AppDelegate, SettingsStore, UsageStore, hooks, or provider clients.
@MainActor
enum IslandCompanionPreview {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = PreviewDelegate()
        app.delegate = delegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Vibeisland Keyboard Squad QA"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: IslandCompanionPreviewView())
        window.minSize = NSSize(width: 760, height: 700)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime((delegate, window)) { app.run() }
    }

    private final class PreviewDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
            true
        }
    }
}

private struct IslandCompanionPreviewView: View {
    @State private var scene = IslandScene.overview
    @State private var count = 10
    @State private var reduceMotion = false
    @State private var physicalNotch = false
    @State private var sceneStartedAt = Date()
    @State private var logs = ["QA ready — no external services or persistent writes"]

    private let scenes: [IslandScene] = [.compact, .overview, .approval, .ask, .done]
    private let names = [
        "黑耳奶白猫", "橘猫", "哈士奇", "柯基", "小狐狸", "小熊猫", "海獭", "熊猫", "企鹅", "垂耳兔",
    ]

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Picker("Scene", selection: self.$scene) {
                    ForEach(self.scenes, id: \.self) { scene in
                        Text(scene.rawValue).tag(scene)
                    }
                }
                .pickerStyle(.segmented)
                Picker("Sessions", selection: self.$count) {
                    ForEach([1, 6, 10, 11], id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                .frame(width: 140)
            }
            HStack {
                Toggle("Reduce Motion", isOn: self.$reduceMotion)
                Toggle("Physical notch geometry", isOn: self.$physicalNotch)
                Spacer()
                Text("Real native components · safe fixtures")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            ZStack(alignment: .top) {
                Color(white: 0.12)
                IslandShellView(
                    presentation: IslandShellPresentation(
                        scene: self.scene,
                        anchorSize: CGSize(width: self.physicalNotch ? 156 : 60, height: 32),
                        hasPhysicalNotch: self.physicalNotch,
                        showsCompactQuota: true,
                        cardCount: self.count),
                    content: self.content,
                    reduceMotion: self.reduceMotion,
                    actions: self.actions)
                    .padding(.top, 24)
            }
            .frame(maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Action log").font(.headline)
                    Spacer()
                    Button("Clear") { self.logs = [] }
                }
                ScrollView {
                    Text(self.logs.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 106)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 660)
        .onChange(of: self.scene) { _, scene in
            self.sceneStartedAt = Date()
            self.record("scene: \(scene.rawValue)")
        }
    }

    private var content: IslandContent {
        let cards = (0..<self.count).map { index in
            let provider: AgentTaskProvider = index.isMultiple(of: 2) ? .claude : .codex
            let sessionID = "qa-session-\(index + 1)"
            var card = IslandSessionCard(
                id: "\(provider.rawValue):\(sessionID)",
                sessionID: sessionID,
                provider: provider,
                status: self.scene == .done ? .completed : .running,
                title: "\(index + 1). \(self.names[index % 10]) — keyboard task",
                subtitle: "Native session identity: \(sessionID)",
                chips: [provider.rawValue, "Terminal"],
                duration: "2m",
                companionIndex: index % 10)
            card.statusUpdatedAt = self.sceneStartedAt
            return card
        }
        var approval = IslandApprovalRequest(
            id: "qa-approval-1",
            provider: .claude,
            toolName: "Bash",
            toolSummary: "printf 'Keyboard Squad QA — display only'",
            projectPath: "/qa/keyboard-squad",
            actions: [.deny, .allowOnce, .allowAlways, .bypass])
        approval.sessionID = "qa-session-1"
        return IslandContent(
            usage: IslandUsageStrip(
                providerName: "Claude",
                metrics: [IslandUsageMetric(
                    id: "5h", window: "5h", percentText: "34%", resetText: "2h", usedFraction: 0.34)]),
            cards: cards,
            attention: self.scene == .ask ? IslandAttentionDetail(
                provider: .claude,
                status: .needsApproval,
                title: "黑耳奶白猫 — waiting for your answer",
                project: "/qa/keyboard-squad",
                sessionID: "qa-session-1") : nil,
            approval: self.scene == .approval ? approval : nil,
            compactLabel: self.scene == .done ? "Completed" : "Working",
            sessionCount: self.count,
            leadProvider: .claude,
            leadStatus: self.scene == .done ? .completed : .running,
            acknowledgement: nil)
    }

    private var actions: IslandShellActions {
        IslandShellActions(
            toggleExpanded: { self.record("toggleExpanded") },
            hoverEntered: { self.record("hoverEntered") },
            openSession: { self.record("openSession: \($0.provider.rawValue) / \($0.sessionID)") },
            dismiss: { self.record("dismiss") },
            decide: { self.record("approval: \($0.id) / \($1)") },
            refresh: { self.record("refresh") },
            settings: { self.record("settings") },
            togglePinned: { self.record("pin") },
            selectProvider: { self.record("provider: \($0.rawValue)") },
            providers: [.claude, .codex])
    }

    private func record(_ message: String) {
        self.logs.append(message)
        if self.logs.count > 40 { self.logs.removeFirst(self.logs.count - 40) }
    }
}
#endif
