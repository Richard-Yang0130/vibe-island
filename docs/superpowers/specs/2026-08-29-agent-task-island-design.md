# Agent Task Island Design

Date: 2026-08-29

Status: Approved for implementation planning

## Context

CodexBar already has an uncommitted Dynamic Island prototype built around a centered `NSPanel`, SwiftUI content,
hardware-notch geometry, hover expansion, and usage cards. The current agent-session scanner separately detects Codex
and Claude processes and recent transcript activity, but its state is intentionally approximate: a session is either
`active` or `idle` based on process and file timestamps.

The new feature turns the top-center surface into an authoritative task-status indicator for Codex and Claude. The
collapsed surface contains only two colored pixel lights. Precise lifecycle hooks drive task state. Approval, completion,
failure, and interruption events expand the island automatically. The expanded card presents the task event first and
quota information as a compact secondary section.

This design does not treat process activity or transcript timestamps as task truth. If a provider's hooks are not
installed, trusted, and healthy, that provider does not show inferred task state.

## Goals

- Show one aggregated status light for Codex and one for Claude.
- Use provider-owned lifecycle events for running, approval, completion, failure, interruption, and session cleanup.
- Expand automatically when a turn needs approval or ends.
- Keep the collapsed surface free of text, icons, percentages, and quota values.
- Keep event information primary and quota information secondary in the expanded card.
- Let a card click focus the originating Codex, Claude, or terminal task without approving or denying anything.
- Work on notched and notchless displays and across multiple connected displays.
- Install and remove hooks without damaging unrelated user configuration.
- Ensure monitoring failures never delay or break Codex or Claude.

## Non-goals

- Approving or denying a request inside CodexBar.
- Displaying or persisting prompt text, command text, tool arguments, or model replies.
- Replacing Codex or Claude as the task host.
- Inferring success or failure from process exit, file modification time, or transcript text.
- Monitoring remote SSH Agent Sessions in the first version.
- Sending macOS notifications in addition to the island.
- Adding support for providers other than Codex and Claude in the first version.

## Product decisions

- A "task" is one user-submitted turn, not the lifetime of an entire conversation.
- Hooks are mandatory. There is no approximate fallback mode.
- Multiple tasks are aggregated into one light per provider.
- Provider identity uses fixed color; state uses motion.
- Codex is always the left light and Claude is always the right light.
- Running does not expand the island.
- Approval, completion, failure, and interruption expand the island.
- Clicking an event card opens the original task; the card has no approval controls.
- Every connected display shows the collapsed lights. Only the display containing the pointer expands automatically.

## User experience

### Setup

The Task Status setting shows one independent health row for Codex and one for Claude. Each row can be:

- Not detected
- Not configured
- Installed
- Waiting for trust
- Healthy
- Needs repair

Enabling Task Status starts a preflight. CodexBar detects installed clients and explains that precise local hooks are
required. Configuration changes happen only after the user selects **Configure Task Status**. One provider may be healthy
while the other remains unavailable.

The setup flow does not claim success merely because a file was edited. A provider becomes healthy only after its managed
hook entries match the expected version, the bridge can reach the local event socket, and the provider has no known trust
or disablement problem. If Codex requires the user to review a hook, the row remains **Waiting for trust** and links the
user back to Codex's hook review surface.

### Collapsed surface

The collapsed surface contains two 8-point pixel lights with no visible labels:

- Left: Codex, cool mint/cyan.
- Right: Claude, warm orange.

The fixed order and fixed provider colors do not change with state.

| State | Light behavior |
| --- | --- |
| Not configured | Off |
| Idle | Static at approximately 15% opacity |
| Running | Soft 2.4-second breathing cycle |
| Needs approval | Repeating fast double pulse |
| Completed | Brief bright expansion pulse |
| Failed | Repeating three-beat urgent pulse |
| Interrupted | Two slower flashes |

With Reduce Motion enabled, animations become static brightness changes. Important states remain understandable because
they also expand a labeled event card.

### Expanded surface

The expanded card always uses this content hierarchy:

1. Provider and authoritative task state.
2. Task title, project name, or working-directory name.
3. A full-width **Open Task** action.
4. A compact quota footer with used percentage, reset time, and a thin meter when quota data exists.

The task event is the primary content. The quota footer is visually quieter and never competes with the event headline.
No prompt, command, tool arguments, or response body appears in the card.

Manual hover or click also opens this event-first layout. If there is no current or recent event, the primary area says
there is no active task while the quota footer remains available.

### Automatic expansion

- Needs approval: expand immediately and remain open until an authoritative follow-up event clears the approval, the user
  dismisses it, or the session disconnects.
- Completed: expand immediately, remain visible for about five seconds, then collapse.
- Failed: expand immediately and remain open until the user opens the task or dismisses the card.
- Interrupted: expand immediately, remain visible for about five seconds, then collapse.
- Running: update only the light.

Higher-priority events can preempt lower-priority cards. A completion never hides an approval. Events that cannot be shown
immediately remain in a FIFO queue within their priority level.

When several tasks from the same provider produce the same terminal state close together, the card may summarize them as
"Codex has 3 completed tasks" and provide one row per task when expanded. A single task still uses the compact one-task
card.

## Architecture

```text
Codex / Claude lifecycle hooks
             |
             v
 codexbar-event-bridge
             |
     user-scoped Unix socket
             |
             v
   AgentTaskEventNormalizer
             |
             v
     AgentTaskStatusStore
        |             |
        |             +--> attention queue
        v
 provider aggregates
        |
        v
 NotchSurfaceCoordinator
        |
        +--> one compact surface per display
        +--> one expanded event card on the active display
```

### Agent task event model

The normalized event is separate from the existing `AgentSession` model.

```swift
struct AgentTaskEvent {
    let id: EventID
    let provider: AgentProvider
    let sessionID: String
    let turnID: String?
    let kind: AgentTaskEventKind
    let occurredAt: Date
    let projectPath: String?
    let taskTitle: String?
    let source: AgentTaskEventSource
}
```

`AgentTaskEventKind` includes:

- `sessionStarted`
- `turnStarted`
- `toolCompleted`
- `approvalRequested`
- `turnCompleted`
- `turnFailed`
- `turnInterrupted`
- `sessionEnded`
- `connectionLost`

The normalizer discards all provider payload fields that are not required by this model.

### Authoritative task state

`AgentTaskStatus` is not added to `AgentSession.State`. The existing scanner remains an approximate activity subsystem for
Agent Sessions and adaptive refresh. The new store owns authoritative hook-driven state:

```swift
enum AgentTaskStatus {
    case notConfigured
    case idle
    case running
    case needsApproval
    case completed
    case failed
    case interrupted
    case disconnected
}
```

The store keeps per-session state and derives a provider aggregate. Provider priority is:

1. Needs approval
2. Failed
3. Running
4. Interrupted
5. Completed
6. Idle
7. Not configured

An old or duplicate event cannot move a terminal turn back to running. Event identity is derived from provider, session,
turn, kind, and the provider event identifier when available.

### Provider adapters

The Codex adapter observes these hook events:

- `SessionStart`
- `UserPromptSubmit`
- `PermissionRequest`
- `PostToolUse`
- `Stop`
- `SessionEnd`

Where an authoritative Codex app-server channel is available, the adapter also consumes:

- `thread/status/changed`, including `waitingOnApproval` and `waitingOnUserInput`
- `turn/started`
- `turn/completed`, including `completed`, `interrupted`, and `failed`
- `serverRequest/resolved`

The Claude adapter observes:

- `SessionStart`
- `UserPromptSubmit`
- `PermissionRequest`
- `PostToolUse`
- `Stop`
- `StopFailure`
- `SessionEnd`

`UserPromptSubmit` or `turn/started` begins running. `PermissionRequest` begins approval. `PostToolUse`, another tool event,
`serverRequest/resolved`, or a terminal turn event clears approval. `Stop` is a completed turn unless a more specific
authoritative event reports failure or interruption.

Some Codex CLI releases expose `Stop` without a distinct failure result. In that capability set, CodexBar reports **Task
ended**, not **Failed**. It never derives failure from prose, process exit, or a nonzero tool exit code. A provider adapter
declares its supported terminal states so the UI does not promise unavailable precision.

## Hook installation

### Files

- Codex: prefer a dedicated user-level `~/.codex/hooks.json`.
- Claude: merge into the user-level `~/.claude/settings.json`.

CodexBar uses user-level hooks so all local projects participate without editing repositories. Project-local hooks remain
untouched.

### Managed entries

Every inserted handler contains a stable CodexBar marker and a versioned command. The installer:

1. Reads and parses the current file.
2. Removes stale CodexBar-managed entries from the in-memory document.
3. Preserves all unrelated fields and third-party hook entries.
4. Adds the current managed entries.
5. Validates the full result.
6. Writes a sibling temporary file with restrictive permissions.
7. Atomically replaces the destination.

Repeated installation is idempotent. Repair runs the same merge. Uninstall removes only CodexBar-managed entries and
deletes an empty hooks container only when CodexBar created the last remaining entries.

If a file is invalid or cannot be represented without losing user content, installation stops and leaves the original
untouched.

### Hook behavior

The hook command invokes a bundled `codexbar-event-bridge` using an absolute path. The bridge reads one JSON object from
standard input, attaches the provider identity, forwards it over the socket, and exits successfully without printing a
decision.

The bridge never approves or denies a request. A missing app, missing socket, invalid payload, or timeout still produces a
fast successful exit so monitoring cannot block the agent. Hook handler timeouts remain short because the bridge never
waits for UI input.

## Local event transport

The application listens on a short per-user Unix-domain socket path such as `/tmp/codexbar-<uid>.sock`.

- Create with `umask 077` and verify restrictive ownership and permissions after bind.
- Remove only a socket owned by the current user and created for CodexBar.
- Limit each message to 64 KiB.
- Accept one event envelope per connection.
- Reject unknown providers, event names, malformed JSON, missing session IDs, and implausible timestamps.
- Never log raw payloads.
- Keep accepted task state in memory only.

The socket is a local transport, not an authorization mechanism for privileged actions. The receiver performs no agent
actions and the UI offers no approval control.

## Display architecture

`NotchSurfaceCoordinator` owns one surface controller per connected display and shares one `AgentTaskStatusStore`.

- A notched display uses its physical auxiliary top areas and preserves the current notch-fused shape.
- A notchless display uses a simulated centered anchor and places the compact black capsule about six points below the
  menu bar.
- Every display shows the same two collapsed provider lights.
- The display containing `NSEvent.mouseLocation` at event time is the automatic expansion target.
- If no screen contains the pointer, use the main screen.
- Screen add, removal, scaling, and arrangement changes rebuild only affected surfaces.
- Full-screen spaces may show automatic approval and terminal-event cards; ordinary hover expansion does not force itself
  over full-screen content.
- Transparent stage regions remain click-through. Only the visible island silhouette accepts pointer events.

The coordinator replaces the prototype's assumption that a physical notch is required. Existing hover, reduced-motion,
window-level, and click-through behavior should be preserved rather than rewritten.

## Opening the originating task

The event store maps provider session identity to the existing local Agent Sessions catalog and window-focus helper.

Resolution order:

1. Exact provider session ID.
2. Exact transcript path.
3. Exact live process plus working directory.
4. Provider application as a coarse fallback.

The card remains useful when exact focusing is unavailable: it opens the provider application or terminal but does not
claim that it selected the exact task.

## Privacy

CodexBar retains only:

- Provider
- Session ID
- Turn ID when available
- Normalized event kind
- Event time
- Project or working-directory path needed for display and focus
- Optional provider-supplied task title

It does not retain prompt text, command text, tool input, tool output, assistant output, approval details, or raw hook
payloads. State is not persisted across CodexBar restarts. Existing privacy settings that hide personal information also
hide project and task labels in the island.

## Error handling

- A malformed config or failed atomic replacement leaves the original file unchanged.
- A bridge or socket failure cannot fail the provider hook.
- Invalid and oversized events are dropped with metadata-only diagnostics.
- Duplicate events are ignored.
- Per-session ordering prevents stale events from reversing terminal state.
- A forced process exit without a terminal event produces **Disconnected**, never **Completed** or **Failed**.
- A broken provider hook turns off only that provider's light and exposes **Needs repair** in settings.
- Card timers never dismiss an active approval.
- Removing a display moves an expanded card to the main display without dropping the queued event.

## Testing strategy

### Pure model tests

- State transitions for running, approval, completion, failure, interruption, disconnect, and session end.
- Duplicate and out-of-order event handling.
- Provider aggregation priority across multiple sessions.
- Attention queue priority, FIFO ordering, aggregation, and dismissal.
- Completion and interruption timer behavior.

### Hook installer tests

- Fresh Codex and Claude configuration.
- Existing unrelated hooks and settings.
- Repeated installation.
- Version repair.
- Selective uninstall.
- Invalid input and atomic-write failure.
- Restrictive permissions.

All installer tests use temporary home directories and fixtures. They never touch real Codex or Claude settings.

### Transport tests

- Current-user socket creation and teardown.
- Valid Codex and Claude payloads.
- Unknown providers and events.
- Missing identifiers.
- Oversized and malformed messages.
- Receiver unavailable and bridge timeout behavior.
- No raw payload content in logs.

### UI and geometry tests

- The collapsed model always contains exactly two unlabeled visible lights.
- Provider color and state-motion mapping.
- Event-first expanded content and secondary quota footer.
- Approval persistence and terminal-event auto-collapse.
- Physical notch geometry.
- Simulated notchless geometry.
- Multiple displays, negative origins, scaling, hot plug, and expansion target selection.
- Reduce Motion behavior.

AppKit wiring receives only focused tests. Most behavior stays behind pure state, layout, descriptor, and policy seams to
avoid brittle headless status-bar tests.

### Bundle-level verification

After focused tests and the full project checks pass, verify the freshly built app bundle with synthetic local hook
events:

- Both providers running.
- Claude approval.
- Codex completion.
- Claude failure.
- Multiple simultaneous terminal events.
- Exact-task focus and fallback focus.
- Notched and notchless display placement when available.
- Full-screen and multi-display behavior.

No live provider probe, Keychain read, or modification of real user hook files is part of automated verification.

## Acceptance criteria

- A configured provider begins breathing after an authoritative turn-start event.
- Approval and terminal events expand the island within approximately one second of receipt.
- The collapsed surface contains only the two provider lights.
- The expanded surface shows task event content before quota content.
- Completion collapses after about five seconds; approval and failure do not disappear prematurely.
- Clicking **Open Task** focuses the exact task when identity is available and uses a clear provider-level fallback
  otherwise.
- Existing third-party hooks remain semantically unchanged across install, repair, and uninstall.
- A stopped CodexBar or failed bridge does not delay or fail Codex or Claude.
- Unsupported provider terminal distinctions are not guessed.
- The feature works on notched and notchless displays and does not make transparent panel regions intercept clicks.

## Open-source references

- [CodeIsland](https://github.com/wxtsky/CodeIsland), MIT: hook-to-socket event delivery, event normalization, hook health,
  provider state aggregation, and multi-display behavior.
- [DynamicNotchKit](https://github.com/mrkai77/DynamicNotchKit), MIT: separate notch and floating styles, top-center
  geometry, and compact/expanded transitions.
- [vibe-notch](https://github.com/farouqaldori/vibe-notch): Claude multi-session lifecycle and terminal focusing.

References are architectural guidance. The implementation should remain small, reuse CodexBar's existing SwiftUI/AppKit
surfaces and Agent Sessions focusing seams, and avoid adding a third-party runtime dependency unless a later plan proves
one necessary.
