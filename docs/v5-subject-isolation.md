# v5 — subject isolation for Cleaned mode + looser pose gate

Status 2026-07-13: **shipped.** Full suite green. Two user-reported issues
from real captures (IMG_9033, IMG_0899) fixed.

## Issue 1 — good captures rejected at the pose gate

`IMG_9033.mov` failed with "PoseSanity.Error error 0" (insufficient
coverage). Root cause: the gate required 90% of frames to register, but
RealityKit's pose registration is **strongly non-deterministic** — the same
video registered **59% on one run and 97% on the next**. Real handheld
captures also legitimately drop blurry frames.

Fix (`Sources/PoseCore/PoseCore.swift`):
- Coverage floor lowered 0.9 → **0.5**. The facing-the-subject (90%) and
  ring-shape (90%) checks are the real garbage detectors; a low frame count
  with coherent poses is just a shorter usable orbit (89 registered frames
  trains fine).
- `PoseSanity.Error` now conforms to `LocalizedError`, so failures read as
  "Only 59% of frames could be located…" instead of "error 0".

Measured: IMG_9033 re-runs now pass (registered 146/150 on the validating
run; 89/150 runs also clear 0.5).

## Issue 2 — "Cleaned" mode didn't isolate the subject

`IMG_0899` cleaned kept **99.1%** of splats (2,575 floaters + 4,304 haze of
739k). Floater+haze was never a subject-isolation method — it strips wisps
but keeps the entire reconstructed environment (walls, floor, other people,
plus distant geometry the trainer placed at the wrong depth, which reads as
floaters near the subject). The Cleaned/Unfiltered toggle promised an
isolated subject and delivered the whole gallery.

### The geometric key

Measured on IMG_0899 cleaned (subject at origin, cameras orbit at r=0.462):
**43% of the alpha-mass sits beyond the camera orbit radius.** You cannot be
orbiting an object and have 43% of it outside your orbit path — that mass is
provably environment. Only the connected subject inside the orbit is wanted.

### Algorithm (replaces the old radial/density crop that amputated legs)

In `SplatCleaner`, after floater+haze, for non-environment captures with a
camera ring:

1. **Bound** — keep only within `orbitRadius * 0.95` of the subject center.
   Everything beyond is environment by construction.
2. **Connected component** — voxelize the in-bound candidates at
   `keepRadius * 0.06`; a voxel is occupied when its summed alpha clears 3%
   of the densest voxel. 26-connected flood from the occupied voxel nearest
   the center. Keep only the reached component — this drops detached
   background *inside* the sphere (the wrong-depth splats) while following
   connectivity through thin parts, so legs/arms/boots are **not** amputated.
3. **Column support** (not blanket plane exclusion) — a below-plane voxel is
   dropped only when nothing in its *vertical column* is above the plane. A
   table's outer sheet has nothing above it → trimmed; a figure's legs have
   the torso above them → kept. This trims tabletops without amputating legs
   **even when the support-plane RANSAC mis-fits a horizontal band through the
   middle of a tall figure** (the KAWS astronaut was cut at the waist by the
   earlier blanket-exclusion version — this rule fixed it).
4. **Fallback** — real subjects are 30–45% of the post-haze cloud; if
   isolation keeps under 2%, a bad seed is assumed and it reverts to
   floater+haze (never ships an empty scene).

On by default (`isolateSubject: true`); environment captures skip it. The
normalization recomputes on the kept cloud, so framing auto-tightens on the
subject. **Unfiltered mode is unchanged** — it still shows the raw training
PLY (full scene).

### Verified (real Swift cleaner on v4 raw splats)

| Capture | Raw | Kept (isolated) | Result |
|---------|-----|-----------------|--------|
| IMG_0899 (astronaut, floor) | 658k | 204k | Full figure, environment gone, no floor |
| IMG_0887 (sculpture on table) | 153k | 61k (79k isolated) | Sculpture intact, **tabletop removed by plane exclusion** |
| XfQW5xJoP1 (sculpture) | 203k | 93k | Sculpture intact, environment gone |

Subjects complete in every case — no amputation. Snapshots rendered and
eyeballed during development.

## Tests

- `testIsolatesDisconnectedBackground` — connected subject kept, disconnected
  background dropped.
- `testKeepsThinAttachedExtremities` — anti-amputation: a thin arm attached to
  the core survives (the exact property the old radial crop broke).
- `testDoesNotAmputateLowerBodyThroughSupportPlane` — a tall figure through a
  floor sheet keeps its lower body (column support) while the sheet is trimmed.
- `testSkipsHardIsolationForEnvironmentCaptures` — rooms still skip isolation.
- `PoseSanityTests` — coverage floor now 0.5.

## Follow-ups

- Existing completed captures were cleaned by the old (non-isolating) code —
  reprocess them ("Start over from saved video") to get isolation.
- The 0.95 orbit bound could clip a subject captured from an unusually tight
  orbit; the connected-component fallback prevents a catastrophic result but
  watch for it on close-up captures.
