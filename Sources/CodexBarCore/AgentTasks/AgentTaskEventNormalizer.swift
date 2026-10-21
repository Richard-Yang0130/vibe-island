import Foundation

public enum AgentTaskEventNormalizer {
    private static let hookKinds: [String: AgentTaskEventKind] = [
        "SessionStart": .sessionStarted,
        "UserPromptSubmit": .turnStarted,
        "PermissionRequest": .approvalRequested,
        "PostToolUse": .toolCompleted,
        "Stop": .turnCompleted,
        "StopFailure": .turnFailed,
        "Interrupt": .turnInterrupted,
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

        let timestamp = self.nonEmptyString(object["timestamp"]).flatMap(self.date)
        let isHarness = envelope.provider == .deepseekHarness
        let sequence = object["harness_event_seq"] as? Int
        if isHarness {
            guard envelope.eventID != nil, timestamp != nil,
                  let sequence, sequence >= 0,
                  self.nonEmptyString(object["turn_id"]) != nil,
                  self.nonEmptyString(object["harness_event_type"]) != nil
            else { return nil }
        }
        let occurredAt = timestamp ?? receivedAt
        return AgentTaskEvent(
            id: "\(envelope.provider.rawValue):\((envelope.eventID ?? UUID()).uuidString)",
            provider: envelope.provider,
            sessionID: sessionID,
            turnID: self.nonEmptyString(object["turn_id"]),
            kind: kind,
            occurredAt: occurredAt,
            projectPath: self.nonEmptyString(object["cwd"]),
            transcriptPath: self.nonEmptyString(object["transcript_path"]),
            taskTitle: isHarness ? self.nonEmptyString(object["task_title"]).map { String($0.prefix(160)) } : nil,
            source: isHarness ? .harnessBridge : .hook,
            sequence: isHarness ? sequence : nil)
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
