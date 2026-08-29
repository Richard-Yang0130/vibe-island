import CodexBarCore
import Observation
import SwiftUI

@MainActor
@Observable
final class AgentTaskHookSettingsModel {
    private let settings: SettingsStore
    private let installer: AgentTaskHookInstaller
    private let healthCenter: AgentTaskHookHealthCenter
    private(set) var detectedProviders: Set<AgentTaskProvider> = []
    private(set) var isWorking = false

    init(
        settings: SettingsStore,
        installer: AgentTaskHookInstaller = AgentTaskHookInstaller(),
        healthCenter: AgentTaskHookHealthCenter = .shared)
    {
        self.settings = settings
        self.installer = installer
        self.healthCenter = healthCenter
    }

    var isEnabled: Bool {
        self.settings.agentTaskStatusEnabled
    }

    func health(for provider: AgentTaskProvider) -> AgentTaskHookHealth {
        self.healthCenter.health(for: provider)
    }

    func refresh() {
        self.detectedProviders = Set(Self.detectedProviders())
        for provider in AgentTaskProvider.allCases {
            guard self.detectedProviders.contains(provider) else {
                self.healthCenter.set(.notDetected, for: provider)
                continue
            }
            switch self.installer.inspect(provider).document {
            case .notInstalled:
                self.healthCenter.set(.notConfigured, for: provider)
            case .needsRepair:
                self.healthCenter.set(.needsRepair("Hook configuration is incomplete."), for: provider)
            case .installed:
                if case .healthy = self.healthCenter.health(for: provider) { continue }
                self.healthCenter.set(.installedAwaitingEvent, for: provider)
            }
        }
    }

    func configure() {
        self.performChange {
            self.detectedProviders = Set(Self.detectedProviders())
            guard !self.detectedProviders.isEmpty else {
                self.settings.agentTaskStatusEnabled = false
                self.refresh()
                return
            }
            for provider in self.detectedProviders {
                self.install(provider)
            }
            self.settings.agentTaskStatusEnabled = self.detectedProviders.contains { provider in
                self.installer.inspect(provider).document == .installed
            }
        }
    }

    func disable() {
        self.performChange {
            self.settings.agentTaskStatusEnabled = false
            for provider in AgentTaskProvider.allCases {
                do {
                    try self.installer.remove(provider)
                } catch {
                    self.healthCenter.set(.needsRepair(error.localizedDescription), for: provider)
                }
            }
            self.refresh()
        }
    }

    func repair(_ provider: AgentTaskProvider) {
        self.performChange {
            self.install(provider)
            self.settings.agentTaskStatusEnabled = self.installer.inspect(provider).document == .installed
        }
    }

    private func install(_ provider: AgentTaskProvider) {
        do {
            try self.installer.install(provider)
            self.healthCenter.set(.installedAwaitingEvent, for: provider)
        } catch {
            self.healthCenter.set(.needsRepair(error.localizedDescription), for: provider)
        }
    }

    private func performChange(_ change: () -> Void) {
        guard !self.isWorking else { return }
        self.isWorking = true
        defer { self.isWorking = false }
        change()
    }

    private static func detectedProviders() -> [AgentTaskProvider] {
        var providers: [AgentTaskProvider] = []
        if BinaryLocator.resolveCodexBinary() != nil {
            providers.append(.codex)
        }
        if BinaryLocator.resolveClaudeBinary() != nil {
            providers.append(.claude)
        }
        return providers
    }
}

@MainActor
struct AgentTaskHookSettingsSection: View {
    @State private var model: AgentTaskHookSettingsModel

    init(settings: SettingsStore) {
        self._model = State(initialValue: AgentTaskHookSettingsModel(settings: settings))
    }

    var body: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { self.model.isEnabled },
                    set: { enabled in
                        if enabled {
                            self.model.configure()
                        } else {
                            self.model.disable()
                        }
                    })) {
                SettingsRowLabel(
                    L("agent_task_status_title"),
                    subtitle: L("agent_task_status_subtitle"))
            }
            .disabled(self.model.isWorking)

            ForEach(AgentTaskProvider.allCases, id: \.rawValue) { provider in
                LabeledContent {
                    if case .needsRepair = self.model.health(for: provider) {
                        Button(L("agent_task_needs_repair")) {
                            self.model.repair(provider)
                        }
                        .disabled(self.model.isWorking)
                    }
                } label: {
                    SettingsRowLabel(
                        self.title(for: provider),
                        subtitle: self.statusText(self.model.health(for: provider)))
                }
            }

            if !self.model.isEnabled {
                Button(L("agent_task_configure")) {
                    self.model.configure()
                }
                .disabled(self.model.isWorking)
            }
        } header: {
            Text(L("agent_task_status_title"))
        } footer: {
            SettingsSectionFooter(L("agent_task_privacy"))
        }
        .onAppear {
            self.model.refresh()
        }
    }

    private func title(for provider: AgentTaskProvider) -> String {
        switch provider {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    private func statusText(_ health: AgentTaskHookHealth) -> String {
        switch health {
        case .notDetected, .notConfigured: L("agent_task_not_configured")
        case .installedAwaitingEvent: L("agent_task_waiting_trust")
        case let .healthy(lastEventAt):
            "\(L("agent_task_healthy")) · \(lastEventAt.formatted(date: .abbreviated, time: .shortened))"
        case let .needsRepair(message): "\(L("agent_task_needs_repair")) · \(message)"
        }
    }
}
