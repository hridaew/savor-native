# v6 — silhouette-consensus cleanup (visual hull via Vision)

Status 2026-07-16: **shipped, then repaired same day.** The first cut was
validated on a single capture (IMG_0887) and regressed two others to zero
cleanup — see "The incident" below. The repaired version is verified across
every capture on disk via `scripts/verify-cleanup.sh`, which is now the
required pre-commit check for cleaner changes.

## The problem geometry could not solve

After v5, users still saw three kinds of leftovers in Cleaned mode:

1. **Pedestal/table edges** touching the subject's base.
2. **Floor/wall shadows** adjacent to the subject.
3. **"Spilled milk"** — semi-transparent sheets hovering just off the
   subject's surface (view-dependent fog the trainer places near geometry).

All three are *connected to* and *as dense as* the subject. Every geometric
signal the cleaner had — density, connectivity, orbit radius, support
plane — classifies them as subject. Tuning thresholds trades one artifact
for another (v5's plane-exclusion → amputated astronaut).

## The idea: use the images, not just the splats

The capture has information the splat cloud alone does not: **frames plus
per-frame camera poses**. Vision's foreground-instance segmentation
(`VNGenerateForegroundInstanceMaskRequest`, the "lift subject" model) gives
a subject silhouette per frame — and, measured on real frames, those masks
exclude exactly the offenders: pedestal, shadow, background.

A 3D point belongs to the subject only if it projects **inside the
silhouette from every camera that sees it** (the classical visual hull). A
pedestal edge or hovering wisp touches the subject in 3D but falls outside
its outline from side views — so multi-view consensus removes it without
any density heuristic.

## Pipeline

`SubjectMaskGenerator` (Vision, best-effort) → `SubjectSilhouettes`
(≤30 views, masks max-pooled to 320 px + 2 dilation passes) →
`SplatCleaner` hull pass (after floater+haze, before connectivity):

- A splat seen by ≥ `maskMinimumViews` (8) views survives only when its
  in-silhouette ratio ≥ `maskConsensusThreshold` (0.8).
- Guard: if the hull would keep < 2% of the post-haze cloud (bad masks),
  it is discarded entirely and geometric cleanup stands alone.
- Environment captures skip the pass (a room has no "subject").
- No dataset / no frames / segmentation failure → silhouettes are nil →
  v5 behavior, unchanged.

Connectivity isolation still runs after the hull: it removes wrong-depth
splats *inside* the hull volume, and remains the only isolation when masks
are unavailable.

## Why consensus instead of a single mask

- Projection is verified OpenGL-convention (`transform_matrix` is c2w with
  camera looking down −Z; 95% of opaque splats project in front, measured).
- Masks are dilated ~6 px (at capture resolution) so pose/mask misalignment
  never eats the subject's edge.
- Measured on IMG_0887: the keep-set moves by only **1.3 points of total**
  between consensus thresholds 0.5 and 0.9 — the classifier is effectively
  binary. Subject points sit at ~1.0 (the silhouette property), environment
  at ~0. Threshold 0.8 sits in the dead zone between the modes.

## Measured (IMG_0887, sculpture on gallery table)

| | v5 (geometry) | v6 (silhouettes + geometry) |
|---|---|---|
| Kept | 104,319 | 63,166 |
| Visible leftovers | tabletop sheet, needles, shadow blob | none |
| Subject integrity | intact | intact (all five fingers) |
| Clean time | ~2 s | ~17 s (incl. 30 Vision masks) |

Rendered from a capture camera, the v6 output is the sculpture alone —
no pedestal, no wall shadow, no fog. Prototyped in Python against the real
capture first (mask → projection-convention probe → consensus sweep), then
ported; the Swift port reproduces the prototype's numbers.

## Tests

- `testProjectsThroughPinholeCamera` — projection convention pinned.
- `testConsensusCountsOnlyViewsThatSeeThePoint` — frustum/behind culling.
- `testHullRemovesAttachedOffSilhouetteBlob` — the headline case: a blob
  *touching* the subject, same density, removed by consensus while >90% of
  the subject survives. Geometry cannot pass this test.
- `testHullFallsBackWhenMasksMissEverything` — bad masks never hollow out
  a capture.
- `testDilationExpandsMaskByOnePixel`.

## The incident, and what it changed

The first v6 gated the hull on the existing `isEnvironment` flag. That flag
is a knife-edge: it compares the camera-orbit radius against the median-mass
radius, and object captures that reconstruct ~half their mass as environment
(KAWS, IMG_9033) flip to "environment" on trainer variance — which then
skips haze, hull, *and* isolation. Cleaned mode shipped the raw scene.

Three repairs, each verified against all four captures on disk:

1. **Consistent silhouettes veto the environment guess.** If ≥2% of the
   cloud reprojects into the masks from ≥8 views (a coherent 3D body —
   random per-frame foregrounds in a room never agree in 3D), the capture
   is an object capture, whatever the mass ratio says.
2. **Underseen splats are environment.** The subject is in-frame from the
   whole ring by construction; anything inside fewer than 8 view frusta is
   not the subject. The first Swift port had silently deviated from the
   validated Python prototype here (the prototype required
   `seen >= 8 && ratio >= threshold` to keep) — restoring it is what
   carved the IMG_9033 room out (297k → 70k kept).
3. **Centered-instance masks.** Vision's `allInstances` can bundle a
   pedestal with the subject; the instance under the image center (the
   capture instruction is "keep the object centered") is preferred, with
   all-instances as the fallback. (On captures where Vision sees subject +
   pedestal as *one* instance, the pedestal is kept — a known limit.)

Verification (all four captures, `scripts/verify-cleanup.sh`):

| Capture | Raw | Kept | Verdict |
|---|---|---|---|
| hand re-run | 169,644 | 63,393 | isolated, all fingers |
| IMG_0887 (hand, gallery) | 153,375 | 63,166 | isolated, all fingers |
| IMG_9033 (bottle, home) | 296,681 | 70,515 | bottle + its roller pedestal (one Vision instance); room gone — was **zero cleanup** |
| IMG_0899 (KAWS, gallery) | 819,154 | 335,611 | isolated, intact — was **zero cleanup** |

## Follow-ups

- Existing captures need "Start Over from Saved Video" to pick up v6.
- `maskConsensusThreshold` interacts with very thin geometry (antennae,
  cables): masks may miss them in a minority of views. The 0.8 threshold +
  dilation covers the cases measured so far; if a real capture loses a thin
  part, lower the threshold before touching dilation.
