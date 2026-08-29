import CodexBarCore
import Foundation

@MainActor
enum AgentTaskEventIntake {
    @discardableResult
    static func receive(
        _ envelope: AgentTaskWireEnvelope,
        at receivedAt: Date,
        into store: AgentTaskStatusStore)
        -> Bool
    {
        guard let event = AgentTaskEventNormalizer.normalize(envelope, receivedAt: receivedAt) else {
            return false
        }
        store.receive(event)
        return true
    }
}

extension StatusItemController {
    func wireAgentTaskStatus() {
        self.agentTaskStatus.onChange = { [weak self] in
            self?.notchBar?.refreshPillContent()
        }
        self.synchronizeAgentTaskStatusForSettingsChange()
    }

    func synchronizeAgentTaskStatusForSettingsChange() {
        guard self.settings.agentTaskStatusEnabled != self.lastAgentTaskStatusEnabled else { return }
        self.lastAgentTaskStatusEnabled = self.settings.agentTaskStatusEnabled
        if self.settings.agentTaskStatusEnabled {
            self.startAgentTaskEventServer()
        } else {
            self.agentTaskEventServer?.stop()
            self.agentTaskEventServer = nil
        }
    }

    func openAgentTask(_ attention: AgentTaskAttention) {
        let event = attention.event
        if let session = AgentTaskFocusResolver.resolve(
            event: event,
            sessions: self.agentSessions.localSessions)
        {
            self.agentSessions.focus(session, remoteHost: nil)
            return
        }

        _ = SessionWindowFocuser.focus(
            AgentSession(
                id: event.sessionID,
                provider: event.provider == .codex ? .codex : .claude,
                source: .desktopApp,
                state: .active,
                pid: nil,
                cwd: event.projectPath,
                projectName: event.projectPath.map { URL(fileURLWithPath: $0).lastPathComponent },
                startedAt: nil,
                lastActivityAt: event.occurredAt,
                transcriptPath: event.transcriptPath,
                host: "local"),
            promptForAccessibility: false)
    }

    private func startAgentTaskEventServer() {
        guard !SettingsStore.isRunningTests, self.agentTaskEventServer == nil else { return }
        let server = AgentTaskEventSocketServer { [weak self] envelope in
            self?.receiveAgentTaskEnvelope(envelope)
        }
        self.agentTaskEventServer = server
        Task { [weak self, weak server] in
            do {
                try await server?.start()
            } catch {
                guard let self, self.agentTaskEventServer === server else { return }
                self.agentTaskEventServer = nil
            }
        }
    }

    private func receiveAgentTaskEnvelope(_ envelope: AgentTaskWireEnvelope) {
        let receivedAt = Date()
        guard AgentTaskEventIntake.receive(envelope, at: receivedAt, into: self.agentTaskStatus) else { return }
        AgentTaskHookHealthCenter.shared.markEventReceived(provider: envelope.provider, at: receivedAt)
        self.notchBar?.refreshPillContent()
    }
}
