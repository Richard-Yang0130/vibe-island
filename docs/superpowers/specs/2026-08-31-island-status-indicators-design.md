# Island Status Indicators Design

## Goal

Correct the compact notch shell so it occupies no more space than the physical MacBook notch, removes the unwanted lower shadow, and shows immediately readable Claude Code and Codex/GPT status.

## Scope

- Physical-notch compact presentation only covers the hardware notch rectangle.
- Expanded presentation keeps the existing Vibe Island session layout.
- Status support remains limited to Claude Code and Codex/GPT.
- Existing quota, provider, and account data remain untouched.

## Compact Geometry

- Compact width and height equal the detected physical notch anchor.
- Compact shoulder radius and bottom radius are zero.
- The black software surface must not extend left, right, or below the hardware notch.
- On displays without a hardware notch, retain the existing simulated anchor behavior.
- Remove all shell drop shadows and lower glow. Provider indicator glows are local to the indicators and do not cast a panel shadow.

## Normal Agent Status — Paired Lights

- Claude owns the left side and uses Claude orange `#D97757`.
- Codex/GPT owns the right side and uses warm white `#F5F5F5`.
- Because the hardware cutout has no pixels, each light sits immediately outside its corresponding notch edge on the transparent stage, without extending the black surface.
- Core diameter: 5 points.
- Local halo diameter: up to 11 points.
- Running: opacity breathes from 0.35 to 1.0 over 2.4 seconds with ease-in-out timing.
- Watched but idle: steady at 0.30 opacity.
- Not watched or unavailable: hidden.
- Reduce Motion: running lights remain steadily bright with no breathing animation.

## Attention State — Split Edge Glow

- When an Agent needs approval, asks a question, fails, or otherwise requires user action, its half of the notch edge gains a restrained outline glow.
- Claude attention lights the left half in orange; Codex/GPT attention lights the right half in warm white.
- If both need attention, both halves appear simultaneously.
- Edge stroke: 1 point with a local 4-point glow.
- Attention pulse: 1.2 seconds ease-in-out, intentionally faster than normal running status.
- The effect follows the notch boundary only and never becomes a downward drop shadow.
- Reduce Motion: the edge remains steadily bright.

## State Mapping

| Agent state | Compact treatment |
| --- | --- |
| unavailable / not watched | hidden |
| idle | dim steady dot |
| running | breathing dot |
| needs approval / asks / failed | bright dot plus matching half-edge pulse |

Existing `taskAggregates` and attention state are the source of truth. Fixture mode supplies deterministic Claude and Codex states for visual verification.

## Interaction

- Compact hover and click behavior remains unchanged.
- The indicator lights do not create separate hit targets.
- Expanding the island replaces the compact indicators with the existing session list.
- Collapsing restores the current live indicator states.

## Verification

- Unit tests cover compact geometry, provider-to-side/color mapping, state mapping, and reduced-motion profiles.
- Computer Use verifies compact width against the detected notch, absence of panel shadow, paired running lights, each attention half-glow, expansion, and collapse.
- Full project checks and test shards must pass before handoff.

## References

- Hermes notch indicator proposal: restrained light, 0.3-to-1.0 opacity breathing, and no waveform or text.
- NotchAgent: Agent state rendered inside the notch area without consuming normal screen space.
- OpenAI design guidance: keep OpenAI marks in approved monochrome presentation; the GPT status light therefore stays white rather than adopting an invented brand color.
