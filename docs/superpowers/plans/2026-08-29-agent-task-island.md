# Agent Task Island Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn CodexBar's in-progress notch prototype into a multi-display task island whose two provider-colored lights and event-first cards are driven by precise Codex and Claude lifecycle hooks.

**Architecture:** Add a privacy-minimized task event model and reducer to `CodexBarCore`, forward provider hook payloads through the already-shipped `CodexBarCLI` over a user-scoped Unix socket, and keep authoritative state in a main-actor `AgentTaskStatusStore`. Refactor the existing `NotchBarController` into one controller per screen, render only two lights while collapsed, and render task events above a compact quota footer while expanded.

**Tech Stack:** Swift 6.2, Swift Testing, Observation, SwiftUI, AppKit, Network.framework Unix-domain sockets, Foundation JSON, SwiftPM.

---

## Scope and sequencing

This plan implements the complete hook-driven feature approved in the design, including settings, task focusing,
notchless displays, multi-display surfaces, and UI verification. It does not create an independent Codex app-server
client: Codex hook releases that expose only `Stop` remain capability-limited to **Task ended**, as required by the
design's no-guessing rule. The normalized event protocol includes an app-server source so an exact attachment mechanism
can be added later without changing the reducer or UI.

The current working tree already contains the uncommitted `NotchBar.swift`, `NotchIslandView.swift`, geometry tests, and
their controller wiring. Preserve those changes and evolve them in place. Do not reset, overwrite, or separately commit
unrelated dirty files.

## File map

### New core files

- `Sources/CodexBarCore/AgentTasks/AgentTaskModels.swift`: normalized provider, event, state, and presentation types.
- `Sources/CodexBarCore/AgentTasks/AgentTaskReducer.swift`: deterministic per-session reducer and provider aggregation.
- `Sources/CodexBarCore/AgentTasks/AgentTaskEventNormalizer.swift`: privacy-minimizing Codex/Claude payload parsing.
- `Sources/CodexBarCore/AgentTasks/AgentTaskWireEnvelope.swift`: versioned bridge envelope and socket path.
- `Sources/CodexBarCore/AgentTasks/AgentTaskHookDocument.swift`: pure JSON hook merge/remove/inspection logic.

### New CLI file

- `Sources/CodexBarCLI/CLIAgentEventCommand.swift`: hidden hook bridge command and Network.framework socket client.

### New app files

- `Sources/CodexBar/AgentTaskStatusStore.swift`: observable task state and attention queue.
- `Sources/CodexBar/AgentTaskEventSocketServer.swift`: user-scoped Unix socket listener.
- `Sources/CodexBar/AgentTaskHookInstaller.swift`: atomic user hook installation and health inspection.
- `Sources/CodexBar/AgentTaskHookSettingsSection.swift`: setup, repair, remove, and per-provider health UI.
- `Sources/CodexBar/AgentTaskFocusResolver.swift`: deterministic exact/fallback focus resolution.
- `Sources/CodexBar/StatusItemController+AgentTasks.swift`: application lifecycle, event intake, and focus wiring.
- `Sources/CodexBar/NotchSurfaceCoordinator.swift`: one surface per display and one expansion target.

### Existing files to modify

- `Sources/CodexBarCLI/CLIEntry.swift`: register and dispatch `agent-event`.
- `Sources/CodexBarCLI/CLIHelp.swift`: include internal command help without advertising it as an end-user workflow.
- `Sources/CodexBar/SettingsStoreState.swift`: persist the Task Status enablement bit.
- `Sources/CodexBar/SettingsStore.swift`: load the new default.
- `Sources/CodexBar/SettingsStore+Defaults.swift`: expose the setting.
- `Sources/CodexBar/SettingsStore+MenuObservation.swift`: observe setting changes.
- `Sources/CodexBar/PreferencesMenuBarPane.swift`: insert the Task Island settings section.
- `Sources/CodexBar/StatusItemController.swift`: own the store, server, and surface coordinator.
- `Sources/CodexBar/StatusItemController+Shutdown.swift`: tear down the server and all surfaces.
- `Sources/CodexBar/MenuBarVisibilityWatcher.swift`: re-evaluate surfaces after display changes.
- `Sources/CodexBar/NotchBar.swift`: accept explicit screen/layout, task snapshots, and attention presentation.
- `Sources/CodexBar/NotchIslandView.swift`: render provider lights and event-first detail.
- `Sources/CodexBar/StatusItemController+Actions.swift`: route hotkeys and celebration origin through the coordinator.
- The 23 exact `Sources/CodexBar/Resources/<locale>.lproj/Localizable.strings` files listed in Task 11: add the approved
  Task Status UI copy without changing unrelated translations.
- `docs/sessions.md`: document local-only, hook-required task status and its privacy boundary.

### New and modified tests

- `Tests/CodexBarTests/AgentTaskReducerTests.swift`
- `Tests/CodexBarTests/AgentTaskEventNormalizerTests.swift`
- `Tests/CodexBarTests/AgentTaskStatusStoreTests.swift`
- `Tests/CodexBarTests/AgentTaskEventBridgeTests.swift`
- `Tests/CodexBarTests/AgentTaskHookDocumentTests.swift`
- `Tests/CodexBarTests/AgentTaskHookInstallerTests.swift`
- `Tests/CodexBarTests/AgentTaskFocusResolverTests.swift`
- `Tests/CodexBarTests/NotchGeometryTests.swift`
- `Tests/CodexBarTests/NotchSurfaceCoordinatorTests.swift`
- `Tests/CodexBarTests/NotchTaskPresentationTests.swift`
- `Tests/CodexBarTests/SettingsStoreCoverageTests.swift`

## Task 1: Define authoritative task events and reducer

**Files:**
- Create: `Sources/CodexBarCore/AgentTasks/AgentTaskModels.swift`
- Create: `Sources/CodexBarCore/AgentTasks/AgentTaskReducer.swift`
- Test: `Tests/CodexBarTests/AgentTaskReducerTests.swift`

- [ ] **Step 1: Write failing reducer tests**

```swift
import Foundation
import Testing
@testable import CodexBarCore

struct AgentTaskReducerTests {
    @Test
    func `approval outranks running and terminal events cannot move backwards`() {
        let startedAt = Date(timeIntervalSince1970: 100)
        var reducer = AgentTaskReducer()
        reducer.apply(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1", at: startedAt))
        reducer.apply(.fixture(kind: .approvalRequested, sessionID: "b", turnID: "t2", at: startedAt.addingTimeInterval(1)))

        #expect(reducer.aggregate(for: .codex).status == .needsApproval)

        reducer.apply(.fixture(kind: .turnCompleted, sessionID: "a", turnID: "t1", at: startedAt.addingTimeInterval(2)))
        reducer.apply(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1", at: startedAt.addingTimeInterval(1.5)))

        #expect(reducer.session(provider: .codex, sessionID: "a")?.status == .completed)
    }

    @Test
    func `session end removes only the matching session`() {
        var reducer = AgentTaskReducer()
        reducer.apply(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1"))
        reducer.apply(.fixture(kind: .turnStarted, sessionID: "b", turnID: "t2"))
        reducer.apply(.fixture(kind: .sessionEnded, sessionID: "a", turnID: nil))

        #expect(reducer.session(provider: .codex, sessionID: "a") == nil)
        #expect(reducer.session(provider: .codex, sessionID: "b")?.status == .running)
    }
}
```

Add a test-only `AgentTaskEvent.fixture` extension in the same test file so all inputs are explicit and no production
fixture API is introduced.

```swift
extension AgentTaskEvent {
    static func fixture(
        kind: AgentTaskEventKind,
        provider: AgentTaskProvider = .codex,
        sessionID: String,
        turnID: String?,
        projectPath: String? = nil,
        transcriptPath: String? = nil,
        title: String? = nil,
        at: Date = Date(timeIntervalSince1970: 100))
        -> AgentTaskEvent
    {
        AgentTaskEvent(
            id: "\(provider.rawValue):\(sessionID):\(turnID ?? "-"):\(kind.rawValue):\(at.timeIntervalSince1970)",
            provider: provider,
            sessionID: sessionID,
            turnID: turnID,
            kind: kind,
            occurredAt: at,
            projectPath: projectPath,
            transcriptPath: transcriptPath,
            taskTitle: title,
            source: .hook)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
swift test --filter AgentTaskReducerTests
```

Expected: compilation fails because `AgentTaskReducer`, `AgentTaskEvent`, and their enums do not exist.

- [ ] **Step 3: Implement the minimal event and reducer types**

```swift
public enum AgentTaskProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public enum AgentTaskEventSource: String, Codable, Sendable {
    case hook
    case codexAppServer
}

public enum AgentTaskEventKind: String, Codable, Sendable {
    case sessionStarted
    case turnStarted
    case toolCompleted
    case approvalRequested
    case turnCompleted
    case turnFailed
    case turnInterrupted
    case sessionEnded
    case connectionLost
}

public enum AgentTaskStatus: String, Codable, Sendable {
    case idle
    case running
    case needsApproval
    case completed
    case failed
    case interrupted
    case disconnected

    public var priority: Int {
        switch self {
        case .needsApproval: 7
        case .failed: 6
        case .running: 5
        case .interrupted: 4
        case .completed: 3
        case .disconnected: 2
        case .idle: 1
        }
    }
}

public struct AgentTaskEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let provider: AgentTaskProvider
    public let sessionID: String
    public let turnID: String?
    public let kind: AgentTaskEventKind
    public let occurredAt: Date
    public let projectPath: String?
    public let transcriptPath: String?
    public let taskTitle: String?
    public let source: AgentTaskEventSource
}

public struct AgentTaskSessionState: Equatable, Sendable {
    public let provider: AgentTaskProvider
    public let sessionID: String
    public var turnID: String?
    public var status: AgentTaskStatus
    public var updatedAt: Date
    public var projectPath: String?
    public var transcriptPath: String?
    public var taskTitle: String?
}

public struct AgentTaskProviderAggregate: Equatable, Sendable {
    public let provider: AgentTaskProvider
    public let status: AgentTaskStatus
    public let sessions: [AgentTaskSessionState]
}
```

Give every cross-target struct above an explicit public initializer. Implement the reducer as follows, with a stable
provider/session key and a separate terminal-turn key:

```swift
public struct AgentTaskReducer: Sendable {
    private var sessions: [String: AgentTaskSessionState] = [:]
    private var terminalTurns = Set<String>()

    public init() {}

    public mutating func apply(_ event: AgentTaskEvent) {
        let sessionKey = Self.sessionKey(event.provider, event.sessionID)
        if event.kind == .sessionEnded {
            self.sessions.removeValue(forKey: sessionKey)
            return
        }
        if let existing = self.sessions[sessionKey], event.occurredAt < existing.updatedAt { return }

        let turnKey = event.turnID.map { "\(sessionKey):\($0)" }
        if let turnKey,
           self.terminalTurns.contains(turnKey),
           event.kind == .turnStarted || event.kind == .toolCompleted || event.kind == .approvalRequested
        {
            return
        }

        let status: AgentTaskStatus = switch event.kind {
        case .sessionStarted: .idle
        case .turnStarted, .toolCompleted: .running
        case .approvalRequested: .needsApproval
        case .turnCompleted: .completed
        case .turnFailed: .failed
        case .turnInterrupted: .interrupted
        case .connectionLost: .disconnected
        case .sessionEnded: .idle
        }
        if let turnKey, [.turnCompleted, .turnFailed, .turnInterrupted].contains(event.kind) {
            self.terminalTurns.insert(turnKey)
        }
        self.sessions[sessionKey] = AgentTaskSessionState(
            provider: event.provider,
            sessionID: event.sessionID,
            turnID: event.turnID,
            status: status,
            updatedAt: event.occurredAt,
            projectPath: event.projectPath,
            transcriptPath: event.transcriptPath,
            taskTitle: event.taskTitle)
    }

    public func session(provider: AgentTaskProvider, sessionID: String) -> AgentTaskSessionState? {
        self.sessions[Self.sessionKey(provider, sessionID)]
    }

    public func aggregate(for provider: AgentTaskProvider) -> AgentTaskProviderAggregate {
        let matches = self.sessions.values.filter { $0.provider == provider }
            .sorted { lhs, rhs in
                if lhs.status.priority != rhs.status.priority { return lhs.status.priority > rhs.status.priority }
                return lhs.updatedAt > rhs.updatedAt
            }
        return AgentTaskProviderAggregate(provider: provider, status: matches.first?.status ?? .idle, sessions: matches)
    }

    private static func sessionKey(_ provider: AgentTaskProvider, _ sessionID: String) -> String {
        "\(provider.rawValue):\(sessionID)"
    }
}
```

- [ ] **Step 4: Run the reducer tests**

Run:

```bash
swift test --filter AgentTaskReducerTests
```

Expected: all reducer tests pass.

- [ ] **Step 5: Commit the reducer**

```bash
git add Sources/CodexBarCore/AgentTasks/AgentTaskModels.swift \
  Sources/CodexBarCore/AgentTasks/AgentTaskReducer.swift \
  Tests/CodexBarTests/AgentTaskReducerTests.swift
git commit -m "Add agent task state reducer"
```

## Task 2: Normalize provider hook payloads without retaining private content

**Files:**
- Create: `Sources/CodexBarCore/AgentTasks/AgentTaskWireEnvelope.swift`
- Create: `Sources/CodexBarCore/AgentTasks/AgentTaskEventNormalizer.swift`
- Test: `Tests/CodexBarTests/AgentTaskEventNormalizerTests.swift`

- [ ] **Step 1: Write failing normalization tests with realistic payload shapes**

```swift
import Foundation
import Testing
@testable import CodexBarCore

struct AgentTaskEventNormalizerTests {
    @Test
    func `claude permission payload keeps identity and drops command text`() throws {
        let payload = Data(#"{"session_id":"s1","hook_event_name":"PermissionRequest","cwd":"/repo","tool_input":{"command":"private command"}}"#.utf8)
        let event = try #require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .claude, payload: payload),
            receivedAt: Date(timeIntervalSince1970: 200)))

        #expect(event.kind == .approvalRequested)
        #expect(event.sessionID == "s1")
        #expect(event.projectPath == "/repo")
        #expect(!String(describing: event).contains("private command"))
    }

    @Test
    func `codex stop failure mapping is capability aware`() throws {
        let payload = Data(#"{"session_id":"s2","turn_id":"t2","hook_event_name":"Stop"}"#.utf8)
        let event = try #require(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .codex, payload: payload),
            receivedAt: .now))

        #expect(event.kind == .turnCompleted)
    }

    @Test
    func `unknown and oversized payloads are rejected`() {
        #expect(AgentTaskEventNormalizer.normalize(
            AgentTaskWireEnvelope(schemaVersion: 1, provider: .codex, payload: Data(#"{"hook_event_name":"Unknown"}"#.utf8)),
            receivedAt: .now) == nil)
        #expect(AgentTaskWireEnvelope.acceptsPayload(Data(repeating: 0, count: 65_537)) == false)
    }
}
```

- [ ] **Step 2: Run the normalizer tests and verify they fail**

Run:

```bash
swift test --filter AgentTaskEventNormalizerTests
```

Expected: compilation fails because the envelope and normalizer do not exist.

- [ ] **Step 3: Implement the versioned envelope and allow-listed normalizer**

```swift
public struct AgentTaskWireEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumPayloadBytes = 64 * 1024

    public let schemaVersion: Int
    public let provider: AgentTaskProvider
    public let payload: Data

    public init(schemaVersion: Int, provider: AgentTaskProvider, payload: Data) {
        self.schemaVersion = schemaVersion
        self.provider = provider
        self.payload = payload
    }

    public static func acceptsPayload(_ payload: Data) -> Bool {
        !payload.isEmpty && payload.count <= self.maximumPayloadBytes
    }
}

public enum AgentTaskSocketPath {
    public static func path(uid: UInt32) -> String {
        "/tmp/codexbar-\(uid)-agent-task.sock"
    }

    public static var currentUserPath: String {
        #if canImport(Darwin)
        self.path(uid: Darwin.getuid())
        #elseif canImport(Glibc)
        self.path(uid: Glibc.getuid())
        #elseif canImport(Musl)
        self.path(uid: Musl.getuid())
        #endif
    }
}
```

In `AgentTaskEventNormalizer`, parse with `JSONSerialization`, read only `session_id`, `turn_id`, `cwd`,
`transcript_path`, `timestamp`, and `hook_event_name`, and map:

```swift
private static let hookKinds: [String: AgentTaskEventKind] = [
    "SessionStart": .sessionStarted,
    "UserPromptSubmit": .turnStarted,
    "PermissionRequest": .approvalRequested,
    "PostToolUse": .toolCompleted,
    "Stop": .turnCompleted,
    "StopFailure": .turnFailed,
    "SessionEnd": .sessionEnded,
]
```

Implement the complete normalization funnel:

```swift
public enum AgentTaskEventNormalizer {
    public static func normalize(
        _ envelope: AgentTaskWireEnvelope,
        receivedAt: Date)
        -> AgentTaskEvent?
    {
        guard envelope.schemaVersion == AgentTaskWireEnvelope.currentSchemaVersion,
              AgentTaskWireEnvelope.acceptsPayload(envelope.payload),
              let object = try? JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
              let sessionID = object["session_id"] as? String,
              !sessionID.isEmpty,
              let hookName = object["hook_event_name"] as? String,
              let kind = Self.hookKinds[hookName]
        else { return nil }

        let occurredAt = (object["timestamp"] as? String)
            .flatMap { ISO8601DateFormatter().date(from: $0) } ?? receivedAt
        let digest = SHA256.hash(data: envelope.payload)
            .map { String(format: "%02x", $0) }
            .joined()
        return AgentTaskEvent(
            id: "\(envelope.provider.rawValue):\(digest)",
            provider: envelope.provider,
            sessionID: sessionID,
            turnID: object["turn_id"] as? String,
            kind: kind,
            occurredAt: occurredAt,
            projectPath: object["cwd"] as? String,
            transcriptPath: object["transcript_path"] as? String,
            taskTitle: nil,
            source: .hook)
    }
}
```

Import `Crypto` for the stable SHA-256 event identity. Do not read `prompt`,
`tool_input`, `tool_response`, `last_assistant_message`, `message`, or error details. Return `nil` for unsupported schema
versions, missing session IDs, unknown events, invalid JSON, or oversized payloads.

- [ ] **Step 4: Run both core test suites**

Run:

```bash
swift test --filter AgentTaskEventNormalizerTests
swift test --filter AgentTaskReducerTests
```

Expected: both suites pass.

- [ ] **Step 5: Commit the wire protocol and normalizer**

```bash
git add Sources/CodexBarCore/AgentTasks/AgentTaskWireEnvelope.swift \
  Sources/CodexBarCore/AgentTasks/AgentTaskEventNormalizer.swift \
  Tests/CodexBarTests/AgentTaskEventNormalizerTests.swift
git commit -m "Normalize agent task hook events"
```

## Task 3: Add the observable task store and attention queue

**Files:**
- Create: `Sources/CodexBar/AgentTaskStatusStore.swift`
- Test: `Tests/CodexBarTests/AgentTaskStatusStoreTests.swift`

- [ ] **Step 1: Write failing store and queue tests**

```swift
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AgentTaskStatusStoreTests {
    @Test
    func `running changes only the light while approval and completion enqueue attention`() {
        let store = AgentTaskStatusStore()
        store.receive(.fixture(kind: .turnStarted, sessionID: "a", turnID: "t1"))
        #expect(store.aggregate(for: .codex).status == .running)
        #expect(store.currentAttention == nil)

        store.receive(.fixture(kind: .turnCompleted, sessionID: "a", turnID: "t1"))
        #expect(store.currentAttention?.status == .completed)

        store.receive(.fixture(kind: .approvalRequested, sessionID: "b", turnID: "t2"))
        #expect(store.currentAttention?.status == .needsApproval)
    }

    @Test
    func `duplicate event is delivered once`() {
        let store = AgentTaskStatusStore()
        let event = AgentTaskEvent.fixture(kind: .turnCompleted, sessionID: "a", turnID: "t1")
        store.receive(event)
        store.receive(event)
        #expect(store.pendingAttentionCount == 1)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify they fail**

Run:

```bash
swift test --filter AgentTaskStatusStoreTests
```

Expected: compilation fails because `AgentTaskStatusStore` is missing.

- [ ] **Step 3: Implement the store with deterministic queue ordering**

```swift
@MainActor
@Observable
final class AgentTaskStatusStore {
    private var reducer = AgentTaskReducer()
    private var seenEventIDs = Set<String>()
    private var attentionQueue: [AgentTaskAttention] = []

    private(set) var currentAttention: AgentTaskAttention?
    private(set) var lastEventAtByProvider: [AgentTaskProvider: Date] = [:]
    var onChange: (@MainActor () -> Void)?

    func receive(_ event: AgentTaskEvent) {
        guard self.seenEventIDs.insert(event.id).inserted else { return }
        self.reducer.apply(event)
        self.lastEventAtByProvider[event.provider] = event.occurredAt
        if let attention = AgentTaskAttention(event: event) {
            self.enqueue(attention)
        }
        self.onChange?()
    }

    func aggregate(for provider: AgentTaskProvider) -> AgentTaskProviderAggregate {
        self.reducer.aggregate(for: provider)
    }

    func dismissCurrentAttention() {
        self.currentAttention = nil
        self.promoteNextAttention()
        self.onChange?()
    }
}
```

Define `AgentTaskAttention` and complete the queue methods:

```swift
struct AgentTaskAttention: Equatable, Identifiable, Sendable {
    let id: String
    let event: AgentTaskEvent
    let status: AgentTaskStatus
    var priority: Int { self.status.priority }

    init?(event: AgentTaskEvent) {
        let status: AgentTaskStatus = switch event.kind {
        case .approvalRequested: .needsApproval
        case .turnCompleted: .completed
        case .turnFailed: .failed
        case .turnInterrupted: .interrupted
        case .connectionLost: .disconnected
        case .sessionStarted, .turnStarted, .toolCompleted, .sessionEnded: return nil
        }
        self.id = event.id
        self.event = event
        self.status = status
    }
}

extension AgentTaskStatusStore {
    var pendingAttentionCount: Int {
        (self.currentAttention == nil ? 0 : 1) + self.attentionQueue.count
    }

    private func enqueue(_ attention: AgentTaskAttention) {
        guard let current = self.currentAttention else {
            self.currentAttention = attention
            return
        }
        if attention.priority > current.priority {
            self.attentionQueue.insert(current, at: 0)
            self.currentAttention = attention
            return
        }
        let insertion = self.attentionQueue.firstIndex { $0.priority < attention.priority }
            ?? self.attentionQueue.endIndex
        self.attentionQueue.insert(attention, at: insertion)
    }

    private func promoteNextAttention() {
        self.currentAttention = self.attentionQueue.isEmpty ? nil : self.attentionQueue.removeFirst()
    }
}
```

- [ ] **Step 4: Run the store and reducer tests**

Run:

```bash
swift test --filter AgentTaskStatusStoreTests
swift test --filter AgentTaskReducerTests
```

Expected: all tests pass.

- [ ] **Step 5: Commit the store**

```bash
git add Sources/CodexBar/AgentTaskStatusStore.swift \
  Tests/CodexBarTests/AgentTaskStatusStoreTests.swift
git commit -m "Add agent task attention store"
```

## Task 4: Forward hook events through the shipped CLI and Unix socket

**Files:**
- Create: `Sources/CodexBarCLI/CLIAgentEventCommand.swift`
- Create: `Sources/CodexBar/AgentTaskEventSocketServer.swift`
- Modify: `Sources/CodexBarCLI/CLIEntry.swift`
- Modify: `Sources/CodexBarCLI/CLIHelp.swift`
- Test: `Tests/CodexBarTests/AgentTaskEventBridgeTests.swift`

- [ ] **Step 1: Write failing bridge envelope and fail-open tests**

```swift
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore

struct AgentTaskEventBridgeTests {
    @Test
    func `bridge wraps stdin and sends it once`() async {
        var sent: Data?
        let success = await CodexBarCLI.forwardAgentEvent(
            provider: .claude,
            stdin: Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8),
            send: { data, _ in sent = data; return true })

        #expect(success)
        let envelope = try #require(try? JSONDecoder().decode(AgentTaskWireEnvelope.self, from: sent ?? Data()))
        #expect(envelope.provider == .claude)
    }

    @Test
    func `bridge reports success to hook when receiver is unavailable`() async {
        let success = await CodexBarCLI.forwardAgentEvent(
            provider: .codex,
            stdin: Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8),
            send: { _, _ in false })
        #expect(success)
    }
}
```

- [ ] **Step 2: Run the bridge tests and verify they fail**

Run:

```bash
swift test --filter AgentTaskEventBridgeTests
```

Expected: compilation fails because `forwardAgentEvent` and the socket server do not exist.

- [ ] **Step 3: Implement the hidden CLI command and socket listener**

Add `AgentEventOptions` with required `--provider` and required marker
`--managed-by com.steipete.codexbar.task-status.v1`. Register `agent-event` in `commandDescriptors`, dispatch it before
provider commands, and read at most `AgentTaskWireEnvelope.maximumPayloadBytes + 1` bytes from stdin.

```swift
struct AgentEventOptions: CommanderParsable {
    @Option(name: .long("provider"), help: "codex | claude")
    var provider: String?

    @Option(name: .long("managed-by"), help: "Internal hook owner marker")
    var managedBy: String?
}

extension CodexBarCLI {
    static func forwardAgentEvent(
        provider: AgentTaskProvider,
        stdin: Data,
        send: @escaping @Sendable (Data, String) async -> Bool = AgentTaskBridgeClient.send)
        async -> Bool
    {
        guard AgentTaskWireEnvelope.acceptsPayload(stdin),
              let encoded = try? JSONEncoder().encode(AgentTaskWireEnvelope(
                  schemaVersion: AgentTaskWireEnvelope.currentSchemaVersion,
                  provider: provider,
                  payload: stdin))
        else { return true }
        _ = await send(encoded, AgentTaskSocketPath.currentUserPath)
        return true
    }
}
```

Implement `AgentTaskBridgeClient` with `NWConnection(to: .unix(path:), using: .tcp)`, a private dispatch queue, a
250-millisecond deadline, one send, and unconditional cancellation. On platforms without Network.framework, return
`false`; the command still exits zero.

Implement `AgentTaskEventSocketServer` with `NWListener`, `requiredLocalEndpoint = .unix(path:)`, `umask(0o077)` during
bind, `chmod(path, 0o600)`, a 64-KiB receive limit, one envelope per connection, and a main-actor callback.

- [ ] **Step 4: Run bridge tests and a real temporary-socket integration test**

Add one test that starts `AgentTaskEventSocketServer` on a UUID path under `/tmp`, sends an encoded envelope with the
client, and waits for exactly one callback.

Run:

```bash
swift test --filter AgentTaskEventBridgeTests
```

Expected: all bridge tests pass; the receiver-unavailable case completes in less than one second.

- [ ] **Step 5: Commit the bridge**

```bash
git add Sources/CodexBarCLI/CLIAgentEventCommand.swift \
  Sources/CodexBarCLI/CLIEntry.swift \
  Sources/CodexBarCLI/CLIHelp.swift \
  Sources/CodexBar/AgentTaskEventSocketServer.swift \
  Tests/CodexBarTests/AgentTaskEventBridgeTests.swift
git commit -m "Bridge agent hook events locally"
```

## Task 5: Merge and remove managed hook entries safely

**Files:**
- Create: `Sources/CodexBarCore/AgentTasks/AgentTaskHookDocument.swift`
- Test: `Tests/CodexBarTests/AgentTaskHookDocumentTests.swift`

- [ ] **Step 1: Write failing semantic-preservation tests**

```swift
import Foundation
import Testing
@testable import CodexBarCore

struct AgentTaskHookDocumentTests {
    @Test
    func `install preserves unrelated settings and hooks`() throws {
        let input = Data(#"{"theme":"dark","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"/other/hook"}]}]}}"#.utf8)
        let installed = try AgentTaskHookDocument.install(
            provider: .claude,
            data: input,
            helperPath: "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI")
        let root = try #require(JSONSerialization.jsonObject(with: installed) as? [String: Any])
        #expect(root["theme"] as? String == "dark")
        #expect(AgentTaskHookDocument.inspect(provider: .claude, data: installed) == .installed)
        #expect(AgentTaskHookDocument.uninstall(provider: .claude, data: installed) != input)
    }

    @Test
    func `reinstall is idempotent and uninstall removes only managed entries`() throws {
        let first = try AgentTaskHookDocument.install(provider: .codex, data: Data(#"{}"#.utf8), helperPath: "/app/cli")
        let second = try AgentTaskHookDocument.install(provider: .codex, data: first, helperPath: "/app/cli")
        #expect(try JSONSerialization.jsonObject(with: first) as? NSDictionary ==
            JSONSerialization.jsonObject(with: second) as? NSDictionary)
        #expect(try JSONSerialization.jsonObject(with:
            AgentTaskHookDocument.uninstall(provider: .codex, data: second)) as? NSDictionary == [:])
    }
}
```

- [ ] **Step 2: Run the hook document tests and verify they fail**

Run:

```bash
swift test --filter AgentTaskHookDocumentTests
```

Expected: compilation fails because `AgentTaskHookDocument` is missing.

- [ ] **Step 3: Implement exact managed command generation and recursive filtering**

```swift
public enum AgentTaskHookDocumentStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case needsRepair
}

public enum AgentTaskHookDocument {
    public static let ownerMarker = "com.steipete.codexbar.task-status.v1"
    public static let codexEvents = [
        "SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd",
    ]
    public static let claudeEvents = codexEvents + ["StopFailure"]

    public static func command(helperPath: String, provider: AgentTaskProvider) -> String {
        "\(shellQuote(helperPath)) agent-event --provider \(provider.rawValue) --managed-by \(ownerMarker)"
    }
}
```

For each event, add this exact handler shape after removing older CodexBar handlers:

```swift
[
    "matcher": "",
    "hooks": [[
        "type": "command",
        "command": command,
        "timeout": 1,
        "async": true,
    ]],
]
```

Implement the document operations with these helpers:

```swift
public static func install(
    provider: AgentTaskProvider,
    data: Data,
    helperPath: String)
    throws -> Data
{
    var root = try self.root(from: data)
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    let command = self.command(helperPath: helperPath, provider: provider)
    for event in self.events(for: provider) {
        var groups = self.removingManagedHandlers(from: hooks[event] as? [[String: Any]] ?? [])
        groups.append([
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": command,
                "timeout": 1,
                "async": true,
            ]],
        ])
        hooks[event] = groups
    }
    root["hooks"] = hooks
    return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
}

public static func uninstall(provider: AgentTaskProvider, data: Data) throws -> Data {
    var root = try self.root(from: data)
    guard var hooks = root["hooks"] as? [String: Any] else { return data }
    for (event, value) in hooks {
        guard let groups = value as? [[String: Any]] else { continue }
        let cleaned = self.removingManagedHandlers(from: groups)
        if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
    }
    if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
    return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
}

public static func inspect(provider: AgentTaskProvider, data: Data) -> AgentTaskHookDocumentStatus {
    guard let root = try? self.root(from: data),
          let hooks = root["hooks"] as? [String: Any]
    else { return .notInstalled }
    let installed = self.events(for: provider).filter { event in
        guard let groups = hooks[event] as? [[String: Any]] else { return false }
        return groups.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains(where: self.isManagedHandler) == true
        }
    }
    if installed.isEmpty { return .notInstalled }
    return installed.count == self.events(for: provider).count ? .installed : .needsRepair
}

private static func removingManagedHandlers(from groups: [[String: Any]]) -> [[String: Any]] {
    groups.compactMap { original in
        guard var handlers = original["hooks"] as? [[String: Any]] else { return original }
        handlers.removeAll(where: self.isManagedHandler)
        guard !handlers.isEmpty else { return nil }
        var group = original
        group["hooks"] = handlers
        return group
    }
}

private static func isManagedHandler(_ handler: [String: Any]) -> Bool {
    guard let command = handler["command"] as? String else { return false }
    return command.contains(" agent-event ") && command.contains("--managed-by \(self.ownerMarker)")
}

private static func root(from data: Data) throws -> [String: Any] {
    if data.isEmpty { return [:] }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AgentTaskHookDocumentError.invalidRoot
    }
    return root
}

private static func events(for provider: AgentTaskProvider) -> [String] {
    provider == .codex ? self.codexEvents : self.claudeEvents
}

private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

Define `AgentTaskHookDocumentError.invalidRoot` as a small `Error` enum. Identify managed entries only when the parsed
command contains both the exact `agent-event` token and exact owner-marker argument. Preserve every unrelated root key,
matcher group, handler, and hook event. Semantic preservation, not whitespace preservation, is the contract.

- [ ] **Step 4: Run hook document and normalizer tests**

Run:

```bash
swift test --filter AgentTaskHookDocumentTests
swift test --filter AgentTaskEventNormalizerTests
```

Expected: both suites pass.

- [ ] **Step 5: Commit the hook document transformer**

```bash
git add Sources/CodexBarCore/AgentTasks/AgentTaskHookDocument.swift \
  Tests/CodexBarTests/AgentTaskHookDocumentTests.swift
git commit -m "Add managed agent hook documents"
```

## Task 6: Install hooks atomically and expose health in Menu Bar settings

**Files:**
- Create: `Sources/CodexBar/AgentTaskHookInstaller.swift`
- Create: `Sources/CodexBar/AgentTaskHookSettingsSection.swift`
- Modify: `Sources/CodexBar/SettingsStoreState.swift`
- Modify: `Sources/CodexBar/SettingsStore.swift`
- Modify: `Sources/CodexBar/SettingsStore+Defaults.swift`
- Modify: `Sources/CodexBar/SettingsStore+MenuObservation.swift`
- Modify: `Sources/CodexBar/PreferencesMenuBarPane.swift`
- Test: `Tests/CodexBarTests/AgentTaskHookInstallerTests.swift`
- Test: `Tests/CodexBarTests/SettingsStoreCoverageTests.swift`

- [ ] **Step 1: Write failing installer and setting-default tests**

```swift
@Test
func `installer writes provider files with restrictive permissions`() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("codexbar-agent-hooks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    let helper = home.appendingPathComponent("CodexBarCLI")
    FileManager.default.createFile(atPath: helper.path, contents: Data())
    let installer = AgentTaskHookInstaller(homeDirectory: home, helperURL: helper)

    try installer.install(.claude)

    let settings = home.appendingPathComponent(".claude/settings.json")
    #expect(installer.inspect(.claude).document == .installed)
    let attributes = try FileManager.default.attributesOfItem(atPath: settings.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test
func `task status defaults off and persists`() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let settings = SettingsStore(userDefaults: defaults)
    #expect(!settings.agentTaskStatusEnabled)
    settings.agentTaskStatusEnabled = true
    #expect(SettingsStore(userDefaults: defaults).agentTaskStatusEnabled)
}
```

- [ ] **Step 2: Run focused tests and verify they fail**

Run:

```bash
swift test --filter AgentTaskHookInstallerTests
swift test --filter SettingsStoreCoverageTests
```

Expected: compilation fails for the installer and new setting.

- [ ] **Step 3: Implement installer, health model, and settings section**

Add `agentTaskStatusEnabled: Bool` to `SettingsDefaultsState`, load it from `UserDefaults` with a default of `false`,
expose it in `SettingsStore+Defaults`, and touch it in `menuObservationToken`.

Implement paths:

```swift
func configURL(for provider: AgentTaskProvider) -> URL {
    switch provider {
    case .codex: self.homeDirectory.appendingPathComponent(".codex/hooks.json")
    case .claude: self.homeDirectory.appendingPathComponent(".claude/settings.json")
    }
}
```

For install/remove, create the parent directory, transform the current data, write a sibling temporary file with mode
`0o600`, then call `FileManager.replaceItemAt` or move into place when the destination is new. Never write partial JSON to
the destination.

```swift
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
```

Define app-facing health:

```swift
enum AgentTaskHookHealth: Equatable {
    case notDetected
    case notConfigured
    case installedAwaitingEvent
    case healthy(lastEventAt: Date)
    case needsRepair(String)
}
```

Add a main-actor `AgentTaskHookHealthCenter.shared` in the same file. It stores only the in-memory health value for each
provider; the event receiver marks `.healthy(lastEventAt:)`, while settings inspection owns the other states.

`AgentTaskHookSettingsModel` uses `BinaryLocator.resolveCodexBinary` and `resolveClaudeBinary`, inspects documents on
appear, installs both detected providers from **Configure Task Status**, repairs one provider, and removes only managed
hooks when disabled. Add `AgentTaskHookSettingsSection` to the bottom of `MenuBarPane`.

- [ ] **Step 4: Run installer, settings, and configuration validation tests**

Run:

```bash
swift test --filter AgentTaskHookInstallerTests
swift test --filter SettingsStoreCoverageTests
swift test --filter ConfigValidationTests
```

Expected: all tests pass; no test reads real home-directory settings.

- [ ] **Step 5: Commit hook setup and settings**

```bash
git add Sources/CodexBar/AgentTaskHookInstaller.swift \
  Sources/CodexBar/AgentTaskHookSettingsSection.swift \
  Sources/CodexBar/SettingsStoreState.swift \
  Sources/CodexBar/SettingsStore.swift \
  Sources/CodexBar/SettingsStore+Defaults.swift \
  Sources/CodexBar/SettingsStore+MenuObservation.swift \
  Sources/CodexBar/PreferencesMenuBarPane.swift \
  Tests/CodexBarTests/AgentTaskHookInstallerTests.swift \
  Tests/CodexBarTests/SettingsStoreCoverageTests.swift
git commit -m "Configure precise agent task hooks"
```

## Task 7: Wire event intake and exact task focusing into the application

**Files:**
- Create: `Sources/CodexBar/AgentTaskFocusResolver.swift`
- Create: `Sources/CodexBar/StatusItemController+AgentTasks.swift`
- Modify: `Sources/CodexBar/StatusItemController.swift`
- Modify: `Sources/CodexBar/StatusItemController+Shutdown.swift`
- Test: `Tests/CodexBarTests/AgentTaskFocusResolverTests.swift`

- [ ] **Step 1: Write failing focus-resolution and intake tests**

```swift
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct AgentTaskFocusResolverTests {
    @Test
    func `exact session id wins over path fallback`() {
        let event = AgentTaskEvent.fixture(
            kind: .approvalRequested,
            sessionID: "exact",
            turnID: "turn",
            projectPath: "/repo")
        let sessions = [
            AgentSession.fixture(id: "other", provider: .codex, cwd: "/repo"),
            AgentSession.fixture(id: "exact", provider: .codex, cwd: "/elsewhere"),
        ]
        #expect(AgentTaskFocusResolver.resolve(event: event, sessions: sessions)?.id == "exact")
    }

    @Test
    func `provider mismatch never focuses a same-path session`() {
        let event = AgentTaskEvent.fixture(
            kind: .turnCompleted,
            provider: .claude,
            sessionID: "x",
            turnID: nil,
            projectPath: "/repo")
        let sessions = [AgentSession.fixture(id: "x", provider: .codex, cwd: "/repo")]
        #expect(AgentTaskFocusResolver.resolve(event: event, sessions: sessions) == nil)
    }
}
```

Define the test-only fixture in `AgentTaskFocusResolverTests.swift`:

```swift
extension AgentSession {
    static func fixture(
        id: String,
        provider: AgentSession.Provider,
        cwd: String?,
        transcriptPath: String? = nil,
        pid: Int32? = 42)
        -> AgentSession
    {
        AgentSession(
            id: id,
            provider: provider,
            source: .cli,
            state: .active,
            pid: pid,
            cwd: cwd,
            projectName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            startedAt: nil,
            lastActivityAt: .now,
            transcriptPath: transcriptPath,
            host: "test")
    }
}
```

- [ ] **Step 2: Run focus tests and verify they fail**

Run:

```bash
swift test --filter AgentTaskFocusResolverTests
```

Expected: compilation fails because the resolver is missing.

- [ ] **Step 3: Implement focus order and controller lifecycle**

Implement resolution order: exact provider/session ID, exact transcript path, then exact provider/CWD with a live PID.
Map `AgentTaskProvider` explicitly to `AgentSession.Provider`; never compare raw strings.

Add these `StatusItemController` properties:

```swift
let agentTaskStatus = AgentTaskStatusStore()
var agentTaskEventServer: AgentTaskEventSocketServer?
var notchSurfaces: NotchSurfaceCoordinator?
```

In `wireAgentTaskStatus`:

1. Start the socket only when `settings.agentTaskStatusEnabled` is true and tests are not running.
2. Decode `AgentTaskWireEnvelope`.
3. Normalize it without logging raw input.
4. Deliver it on the main actor to `agentTaskStatus.receive`.
5. Mark the provider healthy in `AgentTaskHookHealthCenter.shared` after its first accepted event.
6. Refresh the surface coordinator.

Implement `openAgentTask(_:)` by resolving against `agentSessions.localSessions`, calling the existing
`AgentSessionsStore.focus`, and falling back to activating Codex or Claude only when no exact session can be resolved.

- [ ] **Step 4: Run focus and lifecycle tests**

Add a controller seam that injects a decoded-envelope callback so tests can prove malformed envelopes do not update the
store and valid ones do.

Run:

```bash
swift test --filter AgentTaskFocusResolverTests
swift test --filter AgentTaskEventBridgeTests
```

Expected: all tests pass.

- [ ] **Step 5: Commit application task wiring**

```bash
git add Sources/CodexBar/AgentTaskFocusResolver.swift \
  Sources/CodexBar/StatusItemController+AgentTasks.swift \
  Sources/CodexBar/StatusItemController.swift \
  Sources/CodexBar/StatusItemController+Shutdown.swift \
  Tests/CodexBarTests/AgentTaskFocusResolverTests.swift
git commit -m "Wire agent task events into CodexBar"
```

## Task 8: Support physical and simulated islands on every display

**Files:**
- Create: `Sources/CodexBar/NotchSurfaceCoordinator.swift`
- Modify: `Sources/CodexBar/NotchBar.swift`
- Modify: `Sources/CodexBar/MenuBarVisibilityWatcher.swift`
- Modify: `Sources/CodexBar/StatusItemController+Actions.swift`
- Test: `Tests/CodexBarTests/NotchGeometryTests.swift`
- Test: `Tests/CodexBarTests/NotchSurfaceCoordinatorTests.swift`

- [ ] **Step 1: Extend geometry tests for notchless and multiple displays**

```swift
@Test
func `notchless layout creates a centered floating anchor below the menu bar`() throws {
    let layout = try #require(NotchGeometry.layout(
        screenFrame: CGRect(x: 1920, y: -200, width: 2560, height: 1440),
        leftArea: nil,
        rightArea: nil,
        menuBarHeight: 25))

    #expect(!layout.hasPhysicalNotch)
    #expect(layout.anchorRect.midX == 3200)
    #expect(layout.anchorRect.maxY == 1240 - 25 - 6)
}

@Test
func `surface reconciliation creates and removes exact display ids`() {
    let change = NotchSurfaceReconciler.diff(existing: [1, 2], desired: [2, 3])
    #expect(change.added == [3])
    #expect(change.removed == [1])
    #expect(change.retained == [2])
}

@Test
func `fullscreen suppresses hover but not task attention`() {
    #expect(!NotchSurfaceVisibilityPolicy.shouldExpand(trigger: .hover, isFullscreen: true))
    #expect(NotchSurfaceVisibilityPolicy.shouldExpand(trigger: .taskAttention, isFullscreen: true))
}
```

- [ ] **Step 2: Run geometry tests and verify the new cases fail**

Run:

```bash
swift test --filter NotchGeometryTests
swift test --filter NotchSurfaceCoordinatorTests
```

Expected: notchless layout and coordinator types are missing.

- [ ] **Step 3: Refactor one-screen discovery into explicit layouts and a coordinator**

Replace `NotchBarLayout.notchRect` with `anchorRect` and add `hasPhysicalNotch`. For a notchless screen, use a simulated
84-by-20 anchor centered horizontally with its top six points below the menu-bar bottom. Keep stage frames clamped to each
screen's full frame, including screens with negative origins.

Change `NotchBarController` initialization to accept a stable display ID, an explicit `NSScreen`, and its layout; remove
`NotchGeometry.notchedScreen()` from the controller.

```swift
@MainActor
final class NotchSurfaceCoordinator {
    private var controllers: [CGDirectDisplayID: NotchBarController] = [:]
    private let makeController: (NSScreen, NotchBarLayout) -> NotchBarController

    func reconcileScreens(_ screens: [NSScreen] = NSScreen.screens) {
        let desired = Dictionary(uniqueKeysWithValues: screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID,
                  let layout = NotchGeometry.layout(on: screen)
            else { return nil }
            return (id, (screen, layout))
        })
        let change = NotchSurfaceReconciler.diff(
            existing: Set(self.controllers.keys),
            desired: Set(desired.keys))
        for id in change.removed {
            self.controllers.removeValue(forKey: id)?.teardown()
        }
        for id in change.retained {
            guard let value = desired[id] else { continue }
            self.controllers[id]?.update(screen: value.0, layout: value.1)
        }
        for id in change.added {
            guard let value = desired[id] else { continue }
            self.controllers[id] = self.makeController(value.0, value.1)
        }
    }
    func refreshAll() { self.controllers.values.forEach { $0.refreshContent() } }
    func present(_ attention: AgentTaskAttention, pointer: CGPoint = NSEvent.mouseLocation) {
        let target = self.controllers.values.first { $0.screenFrame.contains(pointer) }
            ?? self.controllers.values.first { $0.isOnMainScreen }
            ?? self.controllers.values.first
        for controller in self.controllers.values {
            if controller === target {
                controller.present(attention)
            } else {
                controller.collapseForExternalAttention()
            }
        }
    }
    func teardown() {
        self.controllers.values.forEach { $0.teardown() }
        self.controllers.removeAll()
    }
}
```

Add `NotchSurfaceReconciler.Change` with sorted `added`, `removed`, and `retained` arrays computed from set subtraction and
intersection. Expose read-only `screenFrame` and `isOnMainScreen` from each controller, plus the explicit `update`,
`refreshContent`, `present`, and `collapseForExternalAttention` methods used above.

Add `NotchSurfaceVisibilityPolicy` with triggers `.hover`, `.click`, and `.taskAttention`. Return `true` for task attention
in full-screen spaces and `false` for hover/click there. Keep `.fullScreenAuxiliary` on the panel. Consider the island
display surface active only when `agentTaskStatusEnabled` is true and at least one provider hook is installed; otherwise
preserve the classic status items instead of hiding them behind two off lights.

Select the expansion target by pointer containment, then main screen, then the first screen. Keep every non-target
controller compact. Update display-change handling and hotkey/celebration origin access to use the coordinator.

- [ ] **Step 4: Run geometry and reconciliation tests**

Run:

```bash
swift test --filter NotchGeometryTests
swift test --filter NotchSurfaceCoordinatorTests
```

Expected: all physical-notch, notchless, negative-origin, and diff tests pass.

- [ ] **Step 5: Commit multi-display surfaces**

```bash
git add Sources/CodexBar/NotchSurfaceCoordinator.swift \
  Sources/CodexBar/NotchBar.swift \
  Sources/CodexBar/MenuBarVisibilityWatcher.swift \
  Sources/CodexBar/StatusItemController+Actions.swift \
  Tests/CodexBarTests/NotchGeometryTests.swift \
  Tests/CodexBarTests/NotchSurfaceCoordinatorTests.swift
git commit -m "Show task islands on every display"
```

## Task 9: Replace collapsed content with two provider lights

**Files:**
- Modify: `Sources/CodexBar/NotchBar.swift`
- Modify: `Sources/CodexBar/NotchIslandView.swift`
- Create: `Tests/CodexBarTests/NotchTaskPresentationTests.swift`

- [ ] **Step 1: Write failing pure presentation tests**

```swift
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct NotchTaskPresentationTests {
    @Test(arguments: [
        (AgentTaskStatus.idle, NotchLightMotion.staticDim),
        (.running, .breathe),
        (.needsApproval, .doublePulse),
        (.completed, .completionPulse),
        (.failed, .triplePulse),
        (.interrupted, .interruptedPulse),
    ])
    func `task status maps to one stable light motion`(_ status: AgentTaskStatus, _ motion: NotchLightMotion) {
        #expect(NotchLightPresentation.make(provider: .codex, status: status, isConfigured: true).motion == motion)
    }

    @Test
    func `unconfigured provider light is off`() {
        #expect(NotchLightPresentation.make(provider: .claude, status: .idle, isConfigured: false).motion == .off)
    }

    @Test
    func `collapsed content always contains codex then claude and no text`() {
        let presentation = NotchCollapsedPresentation.make(codex: .running, claude: .idle)
        #expect(presentation.lights.map(\.provider) == [.codex, .claude])
        #expect(presentation.visibleText.isEmpty)
    }
}
```

- [ ] **Step 2: Run presentation tests and verify they fail**

Run:

```bash
swift test --filter NotchTaskPresentationTests
```

Expected: presentation and motion types are missing.

- [ ] **Step 3: Implement pure light presentation and SwiftUI rendering**

```swift
enum NotchLightMotion: Equatable {
    case off
    case staticDim
    case breathe
    case doublePulse
    case completionPulse
    case triplePulse
    case interruptedPulse
}

struct NotchLightPresentation: Equatable, Identifiable {
    let provider: AgentTaskProvider
    let motion: NotchLightMotion
    var id: AgentTaskProvider { self.provider }
}
```

Add `taskAggregates` and per-provider hook health to `NotchBarContentSnapshot` and `NotchBarState`. Replace
`NotchBandView`'s provider icon, title,
percentage, and chevron with `NotchProviderLightsView`, containing exactly two 8-point rounded rectangles. Use fixed mint
for Codex and fixed orange for Claude. Implement the approved motion timings and disable repeating animation when
`NotchMotion.reduceMotion` is true. Keep provider/state descriptions as accessibility labels only.

Remove the quota-critical dormant sliver because collapsed state is now owned exclusively by task lights.

- [ ] **Step 4: Run presentation and existing notch tests**

Run:

```bash
swift test --filter NotchTaskPresentationTests
swift test --filter NotchGeometryTests
```

Expected: all tests pass and no collapsed presentation exposes visible text.

- [ ] **Step 5: Commit provider lights**

```bash
git add Sources/CodexBar/NotchBar.swift \
  Sources/CodexBar/NotchIslandView.swift \
  Tests/CodexBarTests/NotchTaskPresentationTests.swift
git commit -m "Render task status as provider lights"
```

## Task 10: Make expanded cards event-first with quota as a footer

**Files:**
- Modify: `Sources/CodexBar/NotchBar.swift`
- Modify: `Sources/CodexBar/NotchIslandView.swift`
- Modify: `Sources/CodexBar/NotchSurfaceCoordinator.swift`
- Modify: `Sources/CodexBar/StatusItemController.swift`
- Modify: `Tests/CodexBarTests/NotchTaskPresentationTests.swift`

- [ ] **Step 1: Add failing detail-plan and auto-dismiss tests**

```swift
@MainActor
@Test
func `expanded detail puts task before quota`() throws {
    let task = try #require(AgentTaskAttention(event: .fixture(
        kind: .turnCompleted,
        provider: .codex,
        sessionID: "s1",
        turnID: "t1",
        title: "Implement status")))
    let plan = NotchTaskDetailPlan(
        attention: task,
        activeSession: nil,
        quota: NotchQuotaSummary(usedPercent: 52, resetText: "Resets in 2h"))
    #expect(plan.sections.map(\.kind) == [.event, .openTask, .quota])
    #expect(plan.eventTitle == "Implement status")
}

@Test
func `only finite attention schedules automatic dismissal`() {
    #expect(NotchAttentionPolicy.dismissAfter(status: .completed) == 5)
    #expect(NotchAttentionPolicy.dismissAfter(status: .interrupted) == 5)
    #expect(NotchAttentionPolicy.dismissAfter(status: .needsApproval) == nil)
    #expect(NotchAttentionPolicy.dismissAfter(status: .failed) == nil)
}

@MainActor
@Test
func `manual expansion without attention shows current running task before quota`() {
    let running = AgentTaskSessionState(
        provider: .claude,
        sessionID: "s1",
        turnID: "t1",
        status: .running,
        updatedAt: .now,
        projectPath: "/repo/CodexBar",
        transcriptPath: nil,
        taskTitle: nil)
    let plan = NotchTaskDetailPlan(
        attention: nil,
        activeSession: running,
        quota: NotchQuotaSummary(usedPercent: 34, resetText: "Resets in 3h"))
    #expect(plan.sections.map(\.kind) == [.event, .openTask, .quota])
    #expect(plan.eventTitle == "CodexBar")
}
```

- [ ] **Step 2: Run task presentation tests and verify the new cases fail**

Run:

```bash
swift test --filter NotchTaskPresentationTests
```

Expected: `NotchTaskDetailPlan` and attention policy are missing.

- [ ] **Step 3: Implement event detail, quota footer, and attention timers**

Add `attention: AgentTaskAttention?`, `activeSession: AgentTaskSessionState?`, and
`quotaCard: UsageMenuCardView.Model?` to `NotchBarState`. Replace the
usage-first `NotchDetailPlan` with:

```swift
struct NotchTaskDetailPlan {
    enum SectionKind: Equatable {
        case event
        case openTask
        case quota
    }

    struct Section: Equatable {
        let kind: SectionKind
    }

    let providerName: String
    let statusText: String
    let eventTitle: String
    let eventSubtitle: String?
    let quota: NotchQuotaSummary?
    let sections: [Section]

    init(
        attention: AgentTaskAttention?,
        activeSession: AgentTaskSessionState?,
        quota: NotchQuotaSummary?)
    {
        let event = attention?.event
        let provider = event?.provider ?? activeSession?.provider ?? .codex
        self.providerName = provider == .codex ? "Codex" : "Claude"
        self.statusText = attention?.status.displayName
            ?? activeSession?.status.displayName
            ?? L("agent_task_none")
        let path = event?.projectPath ?? activeSession?.projectPath
        self.eventTitle = event?.taskTitle
            ?? activeSession?.taskTitle
            ?? path.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? L("agent_task_none")
        self.eventSubtitle = path
        self.quota = quota
        var sections = [Section(kind: .event)]
        if event != nil || activeSession != nil { sections.append(Section(kind: .openTask)) }
        if quota != nil { sections.append(Section(kind: .quota)) }
        self.sections = sections
    }
}

struct NotchQuotaSummary: Equatable {
    let usedPercent: Double
    let resetText: String?
}
```

Add this localized status mapping in `NotchBar.swift` so the initializer above has one source of display copy:

```swift
extension AgentTaskStatus {
    var displayName: String {
        switch self {
        case .idle: L("agent_task_none")
        case .running: L("agent_task_running")
        case .needsApproval: L("agent_task_needs_approval")
        case .completed: L("agent_task_completed")
        case .failed: L("agent_task_failed")
        case .interrupted: L("agent_task_interrupted")
        case .disconnected: L("agent_task_disconnected")
        }
    }
}
```

For automatic expansion, derive task title from attention title, then an exact matched `AgentSession.sessionName`, then
project name, then the working-directory basename. For manual expansion, use the highest-priority active session; when no
session exists, show the localized **No active task** event area. Respect `hidePersonalInfo` by replacing task/project
labels with the localized provider status.

Render event header, event title, one full-width **Open Task** button, and a quiet three-point quota meter footer. Remove
the old gauge hero and extra metric rows from this surface; quota remains one compact secondary summary.

In `NotchBarController.present(attention:)`, open the stage and pin the card. Schedule a five-second dismissal only for
completed and interrupted. Approval and failed remain pinned. Calling **Open Task** invokes the action and dismisses the
current attention, promoting the next queued item.

- [ ] **Step 4: Run presentation, queue, and focus tests**

Run:

```bash
swift test --filter NotchTaskPresentationTests
swift test --filter AgentTaskStatusStoreTests
swift test --filter AgentTaskFocusResolverTests
```

Expected: all tests pass; approval is never auto-dismissed.

- [ ] **Step 5: Commit event-first cards**

```bash
git add Sources/CodexBar/NotchBar.swift \
  Sources/CodexBar/NotchIslandView.swift \
  Sources/CodexBar/NotchSurfaceCoordinator.swift \
  Sources/CodexBar/StatusItemController.swift \
  Tests/CodexBarTests/NotchTaskPresentationTests.swift
git commit -m "Show task events before quota details"
```

## Task 11: Complete localization, privacy copy, and user documentation

**Files:**
- Modify: `Sources/CodexBar/Resources/ar.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/ca.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/de.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/es.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/fa.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/fr.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/gl.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/id.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/it.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/ja.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/ko.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/nl.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/pl.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/pt-BR.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/ru.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/sv.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/th.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/tr.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/uk.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/vi.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/zh-Hans.lproj/Localizable.strings`
- Modify: `Sources/CodexBar/Resources/zh-Hant.lproj/Localizable.strings`
- Modify: `docs/sessions.md`
- Test: `Tests/CodexBarTests/LocalizationLanguageCatalogTests.swift`

- [ ] **Step 1: Add the exact English and Simplified Chinese source copy**

```text
"agent_task_status_title" = "Task status";
"agent_task_status_subtitle" = "Show precise Codex and Claude task events in the top-center island.";
"agent_task_configure" = "Configure Task Status";
"agent_task_remove" = "Remove Task Status";
"agent_task_not_configured" = "Not configured";
"agent_task_waiting_trust" = "Waiting for hook trust";
"agent_task_healthy" = "Healthy";
"agent_task_needs_repair" = "Needs repair";
"agent_task_running" = "Running";
"agent_task_needs_approval" = "Needs approval";
"agent_task_completed" = "Task completed";
"agent_task_ended" = "Task ended";
"agent_task_failed" = "Task failed";
"agent_task_interrupted" = "Task interrupted";
"agent_task_disconnected" = "Disconnected";
"agent_task_open" = "Open Task";
"agent_task_none" = "No active task";
"agent_task_privacy" = "Task status keeps only local session identity, state, project path, and timestamps. It does not store prompts, commands, or model replies.";
```

Use approved native translations in `zh-Hans`; use the English source copy as the explicit fallback value in locales that
do not yet have a reviewed translation. Do not omit keys from any locale.

- [ ] **Step 2: Run localization checks and inspect the expected failures**

Run:

```bash
node Scripts/check-app-locales.mjs
swift test --filter LocalizationLanguageCatalogTests
```

Expected before completing every locale: failures list the missing Task Status keys.

- [ ] **Step 3: Complete every locale and document the feature boundary**

Add every key above to every listed locale. In `docs/sessions.md`, add a **Task Status Island** section covering mandatory
local hooks, provider-colored lights, approval/terminal auto-expansion, local-only event transport, no inline approval,
no prompt/command/reply retention, and no remote SSH support in this release.

- [ ] **Step 4: Re-run localization and documentation checks**

Run:

```bash
node Scripts/check-app-locales.mjs
node Scripts/check-documentation-links.mjs
swift test --filter LocalizationLanguageCatalogTests
```

Expected: all commands exit zero.

- [ ] **Step 5: Commit copy and documentation**

```bash
git add Sources/CodexBar/Resources docs/sessions.md \
  Tests/CodexBarTests/LocalizationLanguageCatalogTests.swift
git commit -m "Document agent task island behavior"
```

## Task 12: Verify the complete story and package the helper path

**Files:**
- Modify only if a failing verification requires it: `Scripts/package_app.sh`
- Test: `Scripts/test_package_product_paths.sh`
- Test: all files under `Tests/CodexBarTests` touched by Tasks 1-11

- [ ] **Step 1: Run formatting and static checks**

Run:

```bash
swiftformat Sources/CodexBarCore/AgentTasks \
  Sources/CodexBar/AgentTask*.swift \
  Sources/CodexBar/StatusItemController+AgentTasks.swift \
  Sources/CodexBar/Notch*.swift \
  Sources/CodexBarCLI/CLIAgentEventCommand.swift \
  Tests/CodexBarTests/AgentTask*.swift \
  Tests/CodexBarTests/Notch*.swift
swiftlint --strict
make check
```

Expected: all commands exit zero. The targeted formatter must not touch unrelated working-tree files.

- [ ] **Step 2: Run focused suites, then the full test suite**

Run:

```bash
swift test --filter AgentTask
swift test --filter Notch
make test
```

Expected: all focused and full suites pass without Keychain prompts.

- [ ] **Step 3: Package and verify the already-shipped helper location**

Run:

```bash
./Scripts/package_app.sh
test -x CodexBar.app/Contents/Helpers/CodexBarCLI
CodexBar.app/Contents/Helpers/CodexBarCLI agent-event --help
./Scripts/test_package_product_paths.sh
```

Expected: packaging succeeds, the helper exists at the path written into managed hooks, the internal command prints help,
and package path tests pass. Modify `package_app.sh` only if this verification exposes a real path/signing gap.

- [ ] **Step 4: Launch the fresh bundle and inject synthetic local events**

Run:

```bash
./Scripts/compile_and_run.sh
printf '%s' '{"session_id":"demo-codex","turn_id":"turn-1","cwd":"/tmp/demo","hook_event_name":"UserPromptSubmit"}' \
  | CodexBar.app/Contents/Helpers/CodexBarCLI agent-event --provider codex \
      --managed-by com.steipete.codexbar.task-status.v1
printf '%s' '{"session_id":"demo-claude","cwd":"/tmp/demo","hook_event_name":"PermissionRequest"}' \
  | CodexBar.app/Contents/Helpers/CodexBarCLI agent-event --provider claude \
      --managed-by com.steipete.codexbar.task-status.v1
```

Expected: Codex breathes without expansion; Claude double-pulses and expands an approval card within approximately one
second. Repeat with `Stop`, `StopFailure`, and `SessionEnd`; verify completion timing, persistent failure, cleanup, exact
card hierarchy, and no prompt/command body in logs.

On a multi-display machine, confirm every screen shows two compact lights and only the pointer's screen expands. On a
notchless display, confirm the floating capsule sits below the menu bar and transparent stage regions pass clicks through.

- [ ] **Step 5: Review the final diff and commit verification fixes**

Run:

```bash
git status --short
git diff --check
git diff --stat
```

Expected: every changed line traces to the approved feature; no real `~/.codex` or `~/.claude` files, generated app
bundles, temporary sockets, or synthetic payloads are staged.

If Task 12 required code or script changes, commit only those verified changes:

```bash
git add Scripts/package_app.sh Scripts/test_package_product_paths.sh
git commit -m "Verify agent task island packaging"
```

If no tracked files changed, do not create an empty commit.
