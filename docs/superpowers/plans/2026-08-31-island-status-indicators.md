# Island Status Indicators Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the physical-notch compact shell exactly match the hardware cutout and render live Claude-left/Codex-right status lights with split attention glows.

**Architecture:** Keep the existing `taskAggregates` and `attention` pipeline as the only production source of status. Extend the pure shell presentation with physical-notch geometry and deterministic fixture scenarios, then render compact indicators outside the clipped black surface; expanded fixture/session content and all quota/provider/account code remain unchanged.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, Swift Testing, SwiftPM.

---

## File map

- Modify `Sources/CodexBar/IslandShellPresentation.swift`: physical-notch compact geometry and fixture status scenarios.
- Modify `Sources/CodexBar/NotchIslandView.swift`: provider/side/color/state/motion mapping.
- Modify `Sources/CodexBar/IslandShellView.swift`: shadow-free black surface plus compact dot and split-edge rendering.
- Modify `Sources/CodexBar/NotchBar.swift`: pass physical-notch and live/fixture indicator state into the shell.
- Modify `Tests/CodexBarTests/IslandShellPresentationTests.swift`: geometry, fixture launch options, and reduced-motion profiles.
- Modify `Tests/CodexBarTests/NotchTaskPresentationTests.swift`: provider mapping and actionable-attention state mapping.

### Task 1: Lock geometry and indicator behavior with failing tests

**Files:**
- Modify: `Tests/CodexBarTests/IslandShellPresentationTests.swift`
- Modify: `Tests/CodexBarTests/NotchTaskPresentationTests.swift`

- [ ] **Step 1: Replace the old physical-notch compact expectations**

Use an explicit `hasPhysicalNotch: true` presentation and assert:

```swift
#expect(compact.bodyWidth == 156)
#expect(compact.totalWidth == 156)
#expect(compact.height == 28)
#expect(compact.shoulderRadius == 0)
#expect(compact.bottomRadius == 0)
```

Add a notchless presentation with `hasPhysicalNotch: false` and preserve the existing simulated compact width, height, and radii.

- [ ] **Step 2: Add provider and state mapping expectations**

Assert that `NotchCollapsedPresentation.make(...)` returns Claude first on `.left` with `#D97757`, Codex second on `.right` with `#F5F5F5`; unavailable providers are hidden, idle providers are dim, running providers breathe, and actionable `attention` for one provider produces a bright dot plus only that provider's edge glow.

- [ ] **Step 3: Add timing and fixture expectations**

Assert normal running opacity `0.35...1.0` over `2.4` seconds, attention pulse duration `1.2` seconds, Reduce Motion steady opacity `1.0` with no duration, and fixture scenarios `running`, `claude-attention`, `codex-attention`, and `both-attention` parse deterministically.

- [ ] **Step 4: Run RED tests**

Run:

```bash
swift test --filter 'IslandShellPresentationTests|NotchTaskPresentationTests'
```

Expected: FAIL because physical-notch geometry, side/color/state fields, status motion profiles, and fixture scenarios do not exist yet.

### Task 2: Implement the minimum production mapping and rendering

**Files:**
- Modify: `Sources/CodexBar/IslandShellPresentation.swift`
- Modify: `Sources/CodexBar/NotchIslandView.swift`
- Modify: `Sources/CodexBar/IslandShellView.swift`
- Modify: `Sources/CodexBar/NotchBar.swift`

- [ ] **Step 1: Implement physical-notch compact geometry**

Add `hasPhysicalNotch` to `IslandShellPresentation`. For `.compact` with a physical notch, return the anchor width/height and zero shoulder/bottom radii; leave `.expanded`, `.dormant`, and notchless compact behavior unchanged.

- [ ] **Step 2: Implement one pure status mapping**

Use these exact provider constants and states:

```swift
enum NotchIndicatorSide: Equatable { case left, right }
enum NotchIndicatorState: Equatable { case hidden, idle, running, attention }

// Claude: left, #D97757
// Codex: right, #F5F5F5
// configured idle -> idle; running -> running
// needsApproval/failed/interrupted/disconnected with matching attention -> attention
// unconfigured -> hidden; completed without actionable attention -> idle
```

Keep `NotchCollapsedPresentation.make` as the single mapping entry point, now taking `attention: AgentTaskAttention?`.

- [ ] **Step 3: Render compact dots and split edges outside the surface**

Keep the black shell clipped to `IslandShellShape`. Remove all shell `.shadow` modifiers. Overlay 5-point dots with a local 3-point halo (11-point maximum diameter) immediately outside each notch edge, animate running opacity `0.35 -> 1.0` with a repeating 2.4-second ease-in-out, and animate only an actionable provider's 1-point half-edge stroke with a local 4-point 1.2-second pulse. Under Reduce Motion, render both effects steadily bright.

- [ ] **Step 4: Wire live and fixture state**

Set `NotchBarState.hasPhysicalNotch` from `NotchBarLayout.hasPhysicalNotch`. In normal launches, derive indicators from existing `taskAggregates`, `hookHealth`, and `attention`. In fixture launches, override only the indicator presentation with the selected deterministic scenario; do not mutate the task store or provider/account data.

- [ ] **Step 5: Run GREEN tests**

Run:

```bash
swift test --filter 'IslandShellPresentationTests|NotchTaskPresentationTests|NotchGeometryTests'
```

Expected: PASS.

### Task 3: Verify the rendered app and commit

**Files:**
- Verify only; modify the files above only if a check exposes a requirement gap.

- [ ] **Step 1: Build and launch fresh fixture bundles**

Build/package the current worktree, then launch fixture variants for running, Claude attention, Codex attention, both attention, and Reduce Motion. Use Computer Use to inspect the actual app UI.

- [ ] **Step 2: Check the acceptance matrix**

Verify: no panel/lower shadow; physical compact black bounds equal the detected notch width and height; Claude orange is left; Codex warm white is right; running lights breathe; each attention scenario lights only the corresponding half-edge (both lights both); Reduce Motion stays steady; click expands and ESC/click collapses with the existing animation.

- [ ] **Step 3: Run full repository verification**

Run:

```bash
make check
make test
```

Expected: both exit 0 with no failures.

- [ ] **Step 4: Re-read the specification and inspect the diff**

Compare every requirement in `docs/superpowers/specs/2026-08-31-island-status-indicators-design.md` against the implementation and visual evidence. Confirm no quota/provider/account code or additional Agent support changed.

- [ ] **Step 5: Commit the scoped change**

Run:

```bash
git add docs/superpowers/plans/2026-08-31-island-status-indicators.md \
  Sources/CodexBar/IslandShellPresentation.swift \
  Sources/CodexBar/NotchIslandView.swift \
  Sources/CodexBar/IslandShellView.swift \
  Sources/CodexBar/NotchBar.swift \
  Tests/CodexBarTests/IslandShellPresentationTests.swift \
  Tests/CodexBarTests/NotchTaskPresentationTests.swift
git commit -m "Add island status indicators"
```

Expected: one scoped commit on `feature/vibe-island-shell`, then stop for user acceptance.
