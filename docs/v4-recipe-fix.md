# v4 recipe fix — glow, floaters, and non-filtering cleanup

Status 2026-07-12: **shipped.** Trainer defaults, cleaner constants, frame
extraction, and viewer perspective all updated; full test suite green.

## User-reported symptoms (v3 shipping config)

- Lots of floaters; cleanup "not filtering at all"
- Glowing splats around subjects, hard to isolate
- Perspective often off in the viewer
- Subjects slightly less detailed than the old (Brush/COLMAP) app

## Root causes

### 1. v3 trainer settings starved the opacity-reset schedule

msplat periodically resets all opacities to near-zero (the floater killer);
scenes need ~3k steps to reconverge after each reset. Empirically (train.log)
msplat runs refinement for the first ~60% of iterations and coasts after:

- **v2 / stock** (refine 100, reset-every 30): resets at ~3100 and ~6100 of
  12k — the config the user validated as "excellent".
- **v3 shipped** (refine 150, reset-every 25 → every 3750 steps): only ONE
  reset in the whole run inside the refinement window. Floaters densified
  after it were never reset-culled; fog and surfaces exported with
  intermediate alphas, which also blinds SplatCleaner — every cleaner
  threshold (faintAlpha, hazeAlpha, clump alpha-support) assumes converged
  opacities. Likely also the "msplat exported 0 vertices" mystery.
- v3 also quadrupled densifyGradThresh vs stock (0.0004 vs 0.0002): IMG_0887
  raw went 137k → 48k gaussians (−65%) — the detail loss. v3 was validated
  on wall time and peak RSS only (see phase2-native-cutover.md), never on
  quality across the three references.

### 2. The memory trade was backwards

v3 bought RSS headroom by gutting density (the thing users see) while
keeping SH degree 3 (which they don't — the original app shipped SH2 for
the same reason). Measured caveat: msplat's peak footprint is dominated by
transient rasterization buffers, so SH2 mostly buys ~35% smaller PLY files
and slightly faster steps rather than a large RAM cut (IMG_0899 v4 peaked
at ~36.9 GB vs v2's ~34.8 GB — memory returns to v2-class, not below). If
memory ever becomes the constraint, the right levers are a splat cap or
training resolution — not the reset schedule or density.

### 3. Cleaner drift from the original savor repo

- hazeClumpAlphaSupport 80 (original 100 — fog clumps measure ~70–90, so 80
  missed half the band); hazeAlpha 0.10 (original 0.08).
- The haze pass ran even for environment captures (original skips: inside a
  room it eats furniture).
- isEnvironment compared cameras to a percentile radius, which small opaque
  densification shells can still inflate (the old IMG_0887 failure).
- worldUp was assumed (0,1,0); PhotogrammetrySession's world comes from
  EXIF-less JPEGs with no gravity, so the plane-aware passes could aim wrong.

### 3b. In-process training silently diverged from every quality bake

All quality bake-offs ran the msplat CLI, which trains coarse-to-fine by
default (`TrainingConfig().numDownscales == 2`; confirmed empirically — a
300-step run takes 7.5s by default vs 13.2s with `--num-downscales 0`). The
in-process backend — the app's default — overrode this to full-res from
step 0. Coarse-to-fine suppresses early floaters, so the app trained with
MORE floaters than any validated run. The override is removed; in-process
now uses the library defaults, matching the CLI by construction.

### 4. Frame extraction lost sharpness selection

Production FrameExtractor sampled uniform midpoints. The original app scores
every frame (Sobel mean) and keeps the sharpest per window — and Phase 0/2
baselines were built from those sharpness-selected frames, so production was
worse than anything validated.

### 5. Viewer perspective

Fixed 65° FOV at pitch 0, ignoring the capture orbit. The original starts at
the capture camera's radius AND height with 50° FOV ("the scene only exists
from where the video was shot").

## What changed

| Area | Change |
|------|--------|
| TrainingOptions | 15k steps, SH2, refine 100, reset-every 30, grad 0.0002, stop-screen-size 4000 |
| SplatCleaner | hazeAlpha 0.08, clumpSupport 100, environment skips haze, worldUp derived from the camera-ring orbit axis (recorded in framing.json), isEnvironment = cameras inside the alpha-mass-weighted median radius (shells can't tip it) |
| FrameExtractor | One AVAssetReader pass scores every frame's luma gradient; sharpest frame per window wins (uniform midpoints on any decode failure) |
| Viewer | FOV 50°, initial camera from framing.json cameraPosition via OrbitCameraState.look(from:at:) |

## 15k schedule (measured, IMG_0887)

Checkpoints: 82,339 @3k → 141,409 @6k → 152,547 @9k → 152,547 @12k →
152,547 @15k. Resets logged at 3100 and 6100 only. So refinement freezes
around 9k and the final 6k steps are pure convergence — the ideal shape
(mirrors the old Brush recipe: growth stop at 9k, then polish).

## v4 re-bake, all three references (artifacts: `phase2/artifacts/v4-recipe/`)

| Capture | Raw gaussians (v4) | vs v2 stock | vs v3 shipped | Cleaned (floaters+haze removed) |
|---------|--------------------|-------------|---------------|--------------------------------|
| IMG_0887 | 152,547 | 137,453 | 48,382 | 139,920 (4,200 + 8,427) |
| XfQW5xJoP1 | 203,241 | 155,403 | — | 187,706 (10,884 + 4,651) |
| IMG_0899 | 658,364 | 716,738 | — | 648,684 (2,792 + 6,888) |

Every capture: resets logged at 3100/6100, refinement frozen by ~9k, final
6k steps pure convergence. Matched-frame renders confirm v4 ≈ v2 quality
class (v2 was the user-validated "excellent" config) with v3's glow-blob
soup gone. XfQW5xJoP1 renders inverted in phase2-snapshot for BOTH v2 and
v4 — a snapshot-tool pose-convention quirk on that dataset, not a scene
regression (the app viewer orients via framing.json, not this tool).

## v4 vs v3 on IMG_0887 (same dataset)

- Raw: 152,547 gaussians vs 48,382 (matched-frame renders:
  `phase2/artifacts/v4-recipe/IMG_0887/snapshots/`). v3 shows the reported
  glow-blob soup; v4 shows a continuous environment and fuller subject.
- Cleaned: 139,920 kept (4,200 floaters + 8,427 haze removed — passes firing
  again). Derived worldUp for this capture: (−0.008, 0.9999, −0.009), i.e.
  y-up tilted ~0.9° — the ring estimate works and guards captures where the
  tilt is larger.

## Follow-ups

- Detail headroom: sample init points from the Object Capture mesh to offset
  Apple's 3–4× sparser point cloud vs COLMAP.
- If opaque shells still survive on some capture: connected-component grow
  from the densest seed (parked in subject-isolation-cleanup-notes.md).
