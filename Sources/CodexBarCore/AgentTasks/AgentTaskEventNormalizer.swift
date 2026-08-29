import Crypto
import Foundation

public enum AgentTaskEventNormalizer {
    private static let hookKinds: [String: AgentTaskEventKind] = [
        "SessionStart": .sessionStarted,
        "UserPromptSubmit": .turnStarted,
        "PermissionRequest": .approvalRequested,
        "PostToolUse": .toolCompleted,
        "Stop": .turnCompleted,
        "StopFailure": .turnFailed,
        "SessionEnd": .sessionEnded,
    ]

    public static func normalize(
        _ envelope: AgentTaskWireEnvelope,
        receivedAt: Date)
        -> AgentTaskEvent?
    {
        guard envelope.schemaVersion == AgentTaskWireEnvelope.currentSchemaVersion,
              AgentTaskWireEnvelope.acceptsPayload(envelope.payload),
              let rawObject = try? JSONSerialization.jsonObject(with: envelope.payload),
              let object = rawObject as? [String: Any],
              let sessionID = self.nonEmptyString(object["session_id"]),
              let hookName = self.nonEmptyString(object["hook_event_name"]),
              let kind = self.hookKinds[hookName]
        else { return nil }

        let occurredAt = self.nonEmptyString(object["timestamp"])
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? receivedAt
        let digest = SHA256.hash(data: envelope.payload)
            .map { String(format: "%02x", $0) }
            .joined()
        return AgentTaskEvent(
            id: "\(envelope.provider.rawValue):\(digest)",
            provider: envelope.provider,
            sessionID: sessionID,
            turnID: self.nonEmptyString(object["turn_id"]),
            kind: kind,
            occurredAt: occurredAt,
            projectPath: self.nonEmptyString(object["cwd"]),
            transcriptPath: self.nonEmptyString(object["transcript_path"]),
            taskTitle: nil,
            source: .hook)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
