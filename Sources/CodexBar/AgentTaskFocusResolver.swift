import CodexBarCore
import Foundation

enum AgentTaskFocusResolver {
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

    static func resolve(event: AgentTaskEvent, sessions: [AgentSession]) -> AgentSession? {
        let provider = self.sessionProvider(for: event.provider)
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

    private static func sessionProvider(for provider: AgentTaskProvider) -> AgentSession.Provider {
        switch provider {
        case .codex: .codex
        case .claude: .claude
        }
    }
}
