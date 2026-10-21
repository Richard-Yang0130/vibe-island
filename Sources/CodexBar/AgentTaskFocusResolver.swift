import CodexBarCore
import Foundation

enum AgentTaskFocusResolver {
    @MainActor
    static func open(
        provider: AgentTaskProvider,
        sessionID: String,
        sessions: [AgentSession],
        openThread: () -> Bool,
        focus: (AgentSession) -> SessionFocusResult) -> Bool
    {
        if provider == .codex || provider == .deepseekHarness, openThread() {
            return true
        }
        guard let sessionProvider = self.sessionProvider(for: provider) else { return false }
        guard let session = sessions.first(where: {
            $0.id == sessionID && $0.provider == sessionProvider
        }) else { return false }
        return focus(session) != .failed
    }

    static func codexThreadURL(
        provider: AgentTaskProvider,
        sessionID: String,
        threadReader: CodexThreadMetadataReader = CodexThreadMetadataReader()) -> URL?
    {
        guard provider == .codex, threadReader.containsResumableThread(sessionID) else { return nil }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(sessionID)"
        return components.url
    }

    static func desktopURL(
        provider: AgentTaskProvider,
        sessionID: String,
        threadReader: CodexThreadMetadataReader = CodexThreadMetadataReader()) -> URL?
    {
        switch provider {
        case .deepseekHarness: URL(string: "dsh://open")
        case .codex: self.codexThreadURL(provider: provider, sessionID: sessionID, threadReader: threadReader)
        case .claude: nil
        }
    }

    static func resolve(event: AgentTaskEvent, sessions: [AgentSession]) -> AgentSession? {
        guard let provider = self.sessionProvider(for: event.provider) else { return nil }
        let matchingProvider = sessions.filter { $0.provider == provider }

        if let exact = matchingProvider.first(where: { $0.id == event.sessionID }) {
            return exact
        }
        if let transcriptPath = event.transcriptPath,
           let transcript = matchingProvider.first(where: { $0.transcriptPath == transcriptPath })
        {
            return transcript
        }
        if let projectPath = event.projectPath {
            return matchingProvider.first { $0.cwd == projectPath && $0.pid != nil }
        }
        return nil
    }

    static func sessionProvider(for provider: AgentTaskProvider) -> AgentSession.Provider? {
        switch provider {
        case .codex: .codex
        case .claude: .claude
        case .deepseekHarness: nil
        }
    }
}
