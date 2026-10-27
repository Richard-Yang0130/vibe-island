# Codex exited-task cleanup

Goal: automatically retire orphaned Codex running/approval entries without timing out live tasks.

Design: keep existing terminal-event completion and dwell behavior. Add a bounded, read-only runtime scan
of Codex processes and their writable rollout descriptors. A failed/incomplete scan retains all tasks.
An open writer protects a task regardless of age or output silence. An unchanged, readable, matching rollout
with no writer in repeated complete scans over at least 15 seconds can be retired silently as interrupted.
New hooks, new turns, file changes, and unavailable scans restart confirmation. Keep terminal tombstones to
reject delayed hooks and stale recovery starts. Do not edit Codex history, source artifacts, or user hooks.

Implementation:

- [x] Add regression tests for orphan cleanup, active writer/approval retention, scan failures, new activity,
  changed files, stale asynchronous snapshots, delayed hooks, and new turns.
- [x] Add `CodexTaskRuntimeReader.swift` in `Sources/CodexBarCore/AgentTasks` using bounded
  `SubprocessRunner` calls to `/bin/ps` and `/usr/sbin/lsof`. Verify process inventory before and after scanning.
- [x] Wire one runtime scan into the five-second recovery loop. Retire only the unchanged matching turn,
  clear its attention, and acknowledge its interrupted state without a false success notification.
- [x] Run focused Swift tests with Keychain suppression, `make test`, and `make check`.
- [x] Review the diff, package with ad-hoc signing, restart the existing `Vibeisland.app`, verify the running
  executable and confirm the reported five stale entries disappear while live work remains visible.

Review: reject delayed approval hooks without a turn ID after a terminal state, just as delayed tool hooks
are rejected; a new turn-start event reopens normal approval handling. Both the reducer and cleanup path
have regression cases that failed before this guard was expanded.

Runtime evidence: an isolated real Codex CLI with temporary CODEX_HOME and a local fake Responses server
kept its writable rollout descriptor during 16 seconds without output or file-size change. SIGTERM then
removed the descriptor without writing task_complete or turn_aborted. No real model/account was used;
the fixture process, server, and temporary directory were removed.

Validation: 51 focused tests in six suites passed. `make test` completed 795 selections in 67 groups;
all 67 groups passed on the first attempt, with zero retries or timeouts. `make check` passed, including
SwiftFormat and strict SwiftLint (zero violations across 1721 files). Independent read-only review and
the follow-up review of the delayed-approval guard found no remaining actionable issue.

Local application validation on 2026-10-27: packaging, widget extension build, and deep/strict signature
verification succeeded. The application was updated in place and the running executable matched the new
bundle. Native UI after restart showed the current running task and no longer showed the five stale
workspace entries. The current task remained visible after a further 20-second observation, beyond the
15-second orphan confirmation period.
