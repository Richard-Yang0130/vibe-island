import CodexBarCore
import Foundation
import Observation

struct AgentTaskHookInspection: Equatable {
    let provider: AgentTaskProvider
    let document: AgentTaskHookDocumentStatus
    let configURL: URL
    /// True when our handlers are installed at all, regardless of approval-mode drift.
    var hasManagedHooks = false
}

enum AgentTaskHookInstallerError: Error {
    case writeFailed
}

struct AgentTaskHookInstaller {
    let homeDirectory: URL
    let helperURL: URL
    /// Whether `PermissionRequest` is installed as a blocking handler. Off keeps every hook
    /// fire-and-forget, which is the pre-approvals behaviour.
    let approvalsEnabled: Bool

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        helperURL: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/CodexBarCLI"),
        approvalsEnabled: Bool = false)
    {
        self.homeDirectory = homeDirectory
        self.helperURL = helperURL
        self.approvalsEnabled = approvalsEnabled
    }

    func configURL(for provider: AgentTaskProvider) -> URL {
        switch provider {
        case .codex:
            self.homeDirectory.appendingPathComponent(".codex/hooks.json")
        case .claude:
            self.homeDirectory.appendingPathComponent(".claude/settings.json")
        }
    }

    func inspect(_ provider: AgentTaskProvider) -> AgentTaskHookInspection {
        let configURL = self.configURL(for: provider)
        guard let data = try? Data(contentsOf: configURL) else {
            return AgentTaskHookInspection(provider: provider, document: .notInstalled, configURL: configURL)
        }
        let document = AgentTaskHookDocument.inspect(
            provider: provider,
            data: data,
            approvalsEnabled: self.approvalsEnabled)
        let isValidObject = (try? JSONSerialization.jsonObject(with: data)) is [String: Any]
        return AgentTaskHookInspection(
            provider: provider,
            document: isValidObject ? document : .needsRepair,
            configURL: configURL,
            hasManagedHooks: isValidObject
                && AgentTaskHookDocument.hasManagedHooks(provider: provider, data: data))
    }

    func install(_ provider: AgentTaskProvider) throws {
        let destination = self.configURL(for: provider)
        let current = (try? Data(contentsOf: destination)) ?? Data()
        let installed = try AgentTaskHookDocument.install(
            provider: provider,
            data: current,
            helperPath: self.helperURL.path,
            approvalsEnabled: self.approvalsEnabled)
        try self.replaceAtomically(installed, at: destination)
    }

    func remove(_ provider: AgentTaskProvider) throws {
        let destination = self.configURL(for: provider)
        guard let current = try? Data(contentsOf: destination) else { return }
        let removed = try AgentTaskHookDocument.uninstall(provider: provider, data: current)
        try self.replaceAtomically(removed, at: destination)
    }

    private func replaceAtomically(_ data: Data, at destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600])
        else { throw AgentTaskHookInstallerError.writeFailed }

        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}

enum AgentTaskHookHealth: Equatable {
    case notDetected
    case notConfigured
    case installedAwaitingEvent
    case healthy(lastEventAt: Date)
    case needsRepair(String)
}

extension AgentTaskHookHealth {
    var isConfiguredForTaskStatus: Bool {
        switch self {
        case .installedAwaitingEvent, .healthy: true
        case .notDetected, .notConfigured, .needsRepair: false
        }
    }
}

@MainActor
@Observable
final class AgentTaskHookHealthCenter {
    static let shared = AgentTaskHookHealthCenter()

    private var values: [AgentTaskProvider: AgentTaskHookHealth] = [:]

    func health(for provider: AgentTaskProvider) -> AgentTaskHookHealth {
        self.values[provider] ?? .notConfigured
    }

    func set(_ health: AgentTaskHookHealth, for provider: AgentTaskProvider) {
        self.values[provider] = health
    }

    func markEventReceived(provider: AgentTaskProvider, at date: Date) {
        self.set(.healthy(lastEventAt: date), for: provider)
    }
}
