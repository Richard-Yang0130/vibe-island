import Foundation

/// Repairs missing terminal hooks using the lifecycle events written by Codex itself.
public enum CodexTaskCompletionReader {
    public static func read(for state: AgentTaskSessionState) -> AgentTaskEvent? {
        guard state.provider == .codex,
              let path = state.transcriptPath,
              let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        // ponytail: inspect at most 1 MiB per active session; use incremental reading if rollouts exceed this per turn.
        let offset = size > 1024 * 1024 ? size - 1024 * 1024 : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: 1024 * 1024)
        else { return nil }
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        // A partially written final line is not an event yet.
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let type = payload["type"] as? String,
                  ["task_started", "task_complete", "turn_aborted"].contains(type)
            else { continue }
            guard type != "task_started",
                  let timestamp = object["timestamp"] as? String,
                  let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp),
                  let turnID = payload["turn_id"] as? String,
                  state.containsCurrentTurn(at: date, turnID: turnID)
            else { return nil }
            let kind: AgentTaskEventKind = type == "turn_aborted" ? .turnInterrupted
                : (payload["error"] == nil || payload["error"] is NSNull ? .turnCompleted : .turnFailed)
            return AgentTaskEvent(
                id: "codex:rollout:\(state.sessionID):\(turnID):\(type)",
                provider: .codex,
                sessionID: state.sessionID,
                turnID: turnID,
                kind: kind,
                occurredAt: date,
                projectPath: state.projectPath,
                transcriptPath: path,
                taskTitle: state.taskTitle,
                source: .codexAppServer)
        }
        return nil
    }
}
