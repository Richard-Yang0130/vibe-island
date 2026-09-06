import AppKit
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
            self?.notchSurfaces?.refreshAll()
            if let attention = self?.agentTaskStatus.currentAttention {
                self?.notchSurfaces?.present(attention)
            } else {
                self?.notchSurfaces?.collapseAttention()
            }
        }
        self.synchronizeAgentTaskStatusForSettingsChange()
    }

    func synchronizeAgentTaskStatusForSettingsChange() {
        self.synchronizeAgentTaskApprovalsForSettingsChange()
        guard self.settings.agentTaskStatusEnabled != self.lastAgentTaskStatusEnabled else { return }
        self.lastAgentTaskStatusEnabled = self.settings.agentTaskStatusEnabled
        if self.settings.agentTaskStatusEnabled {
            self.startAgentTaskEventServer()
        } else {
            self.agentTaskStatus.stopCompletionMonitoring()
            self.agentTaskEventServer?.stop()
            self.agentTaskEventServer = nil
        }
    }

    /// Approvals ride on top of task status: without the telemetry hooks there is nothing to
    /// approve, so the master switch gates both.
    func synchronizeAgentTaskApprovalsForSettingsChange() {
        let enabled = self.settings.agentTaskStatusEnabled && self.settings.agentTaskApprovalsEnabled
        guard enabled != self.lastAgentTaskApprovalsEnabled else { return }
        self.lastAgentTaskApprovalsEnabled = enabled
        self.agentTaskApprovals.isEnabled = enabled
        self.agentTaskApprovals.denyMessage = L("island_denied_from_codexbar")
        if enabled {
            self.startAgentTaskApprovalServer()
        } else {
            // Release anything still blocked before the socket goes away, or those hooks would sit
            // there until their own timeout fires.
            self.agentTaskApprovals.drain()
            self.agentTaskApprovalServer?.stop()
            self.agentTaskApprovalServer = nil
        }
    }

    private func startAgentTaskApprovalServer() {
        guard !SettingsStore.isRunningTests, self.agentTaskApprovalServer == nil else { return }
        self.agentTaskApprovals.onChange = { [weak self] in
            self?.notchSurfaces?.refreshAll()
        }
        let server = AgentTaskApprovalServer { [weak self] request in
            guard let self else { return nil }
            return await self.agentTaskApprovals.handle(request)
        }
        self.agentTaskApprovalServer = server
        Task { [weak self, weak server] in
            do {
                try await server?.start()
            } catch {
                guard let self, self.agentTaskApprovalServer === server else { return }
                self.agentTaskApprovalServer = nil
                self.agentTaskApprovals.isEnabled = false
            }
        }
    }

    func openAgentTask(_ attention: AgentTaskAttention) {
        let event = attention.event
        if let url = AgentTaskFocusResolver.codexThreadURL(
            provider: event.provider,
            sessionID: event.sessionID),
            NSWorkspace.shared.open(url)
        {
            return
        }
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

    func openDisplayedAgentTask() {
        if let attention = self.agentTaskStatus.currentAttention {
            self.openAgentTask(attention)
            self.agentTaskStatus.dismissCurrentAttention()
            return
        }
        guard let state = self.currentAgentTaskSession(),
              AgentTaskFocusResolver.codexThreadURL(
                  provider: state.provider,
                  sessionID: state.sessionID).map(NSWorkspace.shared.open) != true,
              let session = self.agentSessions.localSessions.first(where: { session in
                  session.id == state.sessionID
                      && session.provider == (state.provider == .codex ? .codex : .claude)
              })
        else { return }
        self.agentSessions.focus(session, remoteHost: nil)
    }

    func openAgentTask(provider: AgentTaskProvider, sessionID: String) {
        if let url = AgentTaskFocusResolver.codexThreadURL(provider: provider, sessionID: sessionID),
           NSWorkspace.shared.open(url)
        {
            return
        }
        let sessionProvider: AgentSession.Provider = provider == .codex ? .codex : .claude
        guard let session = self.agentSessions.localSessions.first(where: {
            $0.id == sessionID && $0.provider == sessionProvider
        }) else { return }
        self.agentSessions.focus(session, remoteHost: nil)
    }

    func currentAgentTaskSession() -> AgentTaskSessionState? {
        let states = AgentTaskProvider.allCases.flatMap { self.agentTaskStatus.aggregate(for: $0).sessions }
        let activeStates = states.filter { $0.status != .idle }
        guard var selected = activeStates.max(by: { lhs, rhs in
            lhs.status.priority == rhs.status.priority
                ? lhs.updatedAt < rhs.updatedAt
                : lhs.status.priority < rhs.status.priority
        })
        else { return nil }

        let sessionProvider: AgentSession.Provider = selected.provider == .codex ? .codex : .claude
        if let live = self.agentSessions.localSessions.first(where: { session in
            session.id == selected.sessionID
                && session.provider == sessionProvider
        }) {
            selected.taskTitle = live.sessionName ?? live.projectName ?? selected.taskTitle
        }
        return selected
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
        self.notchSurfaces?.refreshAll()
    }
}
