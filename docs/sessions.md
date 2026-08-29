# Agent Sessions

CodexBar can list live Codex and Claude Code sessions on this Mac and other Macs or Linux hosts reachable over SSH.

Enable **Settings → Menu → Agent sessions**. Local sessions refresh every 30 seconds. Remote sessions refresh every 60 seconds and whenever the menu opens. Tailscale discovery includes online macOS and Linux peers; add extra SSH destinations as a comma-separated list, such as `user@host`.

Choose the row label format in the same settings section:

- **Project** keeps the working-directory name used by earlier releases.
- **Descriptive** uses the Codex thread title or named subagent task, with the project as a fallback.
- **Descriptive + project** shows both when they differ.

Thread titles can contain sensitive text. **Project** remains the default; choose a descriptive mode only if you are comfortable showing those titles in the menu. CodexBar reads title metadata without modifying Codex state and does not persist it to disk.

Claude Code sessions currently fall back to the project name because Claude does not expose equivalent session-title metadata.

The menu groups local sessions first, followed by each remote host. A filled dot is active; an empty dot is idle. Select a local row to activate its terminal, editor, or desktop app. The first focus attempt can request macOS Accessibility permission so CodexBar can raise the matching window. Remote rows run the same focus command over SSH.

The CLI exposes the same scanner:

```console
codexbar sessions
codexbar sessions --json
codexbar sessions focus <session-id>
```

Remote hosts need key-based, non-interactive SSH and either `codexbar` on `PATH` or CodexBar installed in `/Applications`.

## Task Status Island

Task Status is a separate, local-only view of precise Codex and Claude lifecycle events. Configure it from **Settings → Menu Bar → Task status**. CodexBar adds marked user-level hooks for detected local clients and removes only those marked entries when the feature is disabled. Unrelated settings and third-party hooks are preserved.

Every display receives a compact top-center island. The collapsed surface contains no text: the left mint/cyan light is Codex and the right orange light is Claude. Running tasks breathe slowly. Approval, completion, failure, and interruption events expand an event-first card on the display containing the pointer; quota appears only as a secondary footer.

The expanded card can open the matching local task. It does not approve or deny tool use. Approval remains in Codex or Claude, so provider security and confirmation UI remain authoritative.

Hook payloads travel only through a user-scoped local Unix socket. CodexBar normalizes them immediately and retains only local session identity, state, project/transcript path, and timestamps needed for display and focus. Prompt text, commands, tool arguments and output, model replies, and raw hook payloads are not retained or displayed.

Task Status does not monitor remote SSH sessions in this release. The Agent Sessions feature above remains responsible for remote discovery and focus.
