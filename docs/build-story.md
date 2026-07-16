# Build story — Savor Native

## Start: the prompt

Build an **Apple-native, fully on-device macOS pipeline** that turns a
handheld orbit video of an object into a 3D Gaussian splat, without leaving
Apple frameworks/Metal for the heavy lifting:

AVFoundation (frame extraction) → RealityKit `PhotogrammetrySession` (camera
poses + sparse point cloud) → pinned **msplat 1.1.3** (Metal splat training,
in-process Swift by default, CLI as a recovery path) → pure-Swift
floater/haze cleanup → MetalSplatter (viewer). SHARP instant-preview and
Object Capture mesh/USDZ export ride along as optional layers.

## Commit 1 — Initial import (2026-07-12)

Landed the whole pipeline in one shot, already past several rounds of
internal quality bake-offs (see `docs/phase0` through `phase3` findings):

- **Trainer recipe v4**: 15k steps, spherical-harmonics degree 2, stock
  densify/opacity-reset cadence tuned so the last reset lands ~3k steps
  before export — i.e. the model has time to reconverge and ships settled
  geometry, not "half-recovered glow."
- **Cleanup** restored constants from the original reference repo, skips the
  haze pass for environment (room) captures, and derives world-up from the
  capture's own camera orbit ring instead of assuming `(0,1,0)`.
- **Frame extraction** picks the sharpest frame per time window (Sobel
  score) rather than a uniform midpoint sample.
- **Viewer** starts from the actual capture pose at 50° FOV, on the theory
  that "the scene only exists from where the video was shot."

Key learning baked into `docs/v4-recipe-fix.md`: a v3 regression traced back
to **starving msplat's opacity-reset schedule** — resets are the floater
killer, and a bad refine/reset cadence meant floaters densified after the
last reset were never culled, which also blinded every downstream cleaner
threshold (they all assume converged opacities). A second, quieter bug: the
in-process Swift training path silently trained full-resolution from step 0
while every quality bake-off had used the CLI's coarse-to-fine default —
so production shipped with strictly more floaters than anything ever
validated. Fixed by making in-process match the CLI's defaults by construction.

## Commit 2 — Subject isolation + pose gate fix (2026-07-13)

Two real-capture bug reports drove this one:

**Bug A — good captures rejected.** `IMG_9033.mov` failed pose validation
with an opaque "error 0." Root cause: RealityKit's pose registration is
**strongly non-deterministic** — the same video registered 59% of frames on
one run and 97% on the next — so a 90%-coverage gate was a coin flip on
otherwise-fine footage. Fix: dropped the coverage floor to 0.5 (the
facing-the-subject and ring-shape checks are the real quality gates; low
frame count with coherent poses is just a shorter usable orbit), and made
`PoseSanity.Error` conform to `LocalizedError` so failures read as sentences.

**Bug B — "Cleaned" mode wasn't isolating anything.** `IMG_0899` kept 99.1%
of splats after "cleaning" — floater/haze removal was never a subject
isolator, it just stripped wisps while keeping the entire room. The
geometric insight that unlocked the fix: on a real orbit capture, **43% of
the reconstructed alpha-mass sat beyond the camera's own orbit radius** —
which is a contradiction (you can't orbit an object and have almost half of
it outside the orbit path), so that mass is provably environment, not
subject.

New algorithm in `SplatCleaner`:
1. **Bound** — discard anything beyond `0.95 × orbitRadius`.
2. **Connected component** — voxelize what's left, 26-connected flood fill
   from the densest voxel, keep only the reached component. This drops
   disconnected background *inside* the orbit sphere while following
   connectivity through thin parts (legs/arms/boots survive, unlike the
   old hard-radius crop).
3. **Plane exclusion** (first version) — exclude points at/below the
   detected support plane so the flood can't bridge across a tabletop into
   the far wall.
4. **Fallback** — if isolation keeps under 2% of the cloud, assume a bad
   seed and revert to floater+haze only (never ship an empty scene).

On by default; environment captures skip it.

## Commit 3 — Fixing the fix: column support (2026-07-13, later)

Shipping commit 2's plane exclusion immediately surfaced a new bug: it cut
a tall figure (the "KAWS astronaut" capture) off at the waist. Cause: the
support-plane RANSAC fit a horizontal band through the *middle* of a tall
subject, and blanket-excluding everything below that plane discarded the
legs along with the real tabletop.

Fix: replace blanket plane exclusion with **column support** — a
below-plane voxel is dropped only if *nothing in its vertical column* is
above the plane. A table's outer sheet has nothing above it anywhere, so it
gets trimmed; a figure's legs always have the torso above them in the same
column, so they survive even when the plane is mis-fit through the body.
Verified on the real astronaut capture (188k → 327k kept, legs restored)
while `IMG_0887`'s tabletop stayed correctly removed. Added a regression
test (`testDoesNotAmputateLowerBodyThroughSupportPlane`) so this specific
failure mode can't silently return.

## End state

- Full Swift test suite green across all three commits.
- `docs/v5-subject-isolation.md` is the living spec for the isolation
  algorithm, its verified real-capture results, and known follow-ups.
- Known open follow-up (not yet done): captures processed by the
  pre-isolation cleaner need to be reprocessed ("Start over from saved
  video") to benefit from subject isolation. The 0.95 orbit-bound fraction
  is also flagged as a possible future clipping risk on unusually tight
  orbits — mitigated today only by the 2%-fallback safety net, not fixed
  at the source.

## Key learnings worth carrying forward

- **Non-deterministic upstream signals need loose gates.** When a metric
  (pose coverage) varies run-to-run on identical input, gating tightly on it
  produces false negatives, not quality control. Gate on the checks that are
  actually stable (facing, ring-shape).
- **A geometric invariant beats a heuristic threshold.** "43% of alpha-mass
  is outside the camera's own orbit" is a provable contradiction, not a
  tuned constant — it made the isolation bug obviously fixable instead of
  another threshold to eyeball.
- **A fix for one failure mode can create another.** Blanket plane exclusion
  fixed the environment-leak bug but introduced amputation on tall subjects;
  the real fix needed a property (vertical column occupancy) that
  distinguishes "a table's edge" from "a leg" instead of a single global
  rule. Each fix shipped with a targeted regression test tied to the exact
  capture that broke.
