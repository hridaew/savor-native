# Phase 2 bake-off summary

Goal from the original execution plan: replace Brush with a Metal-native
trainer if quality holds.

## Decision

**msplat 1.1.3 wins.** It is the only product trainer.

| Candidate | Outcome |
|-----------|---------|
| Brush v0.3.0 | Proven Phase 0/1 baseline; frozen PLYs kept as visual refs; **runtime deleted** after cutover |
| msplat 1.1.3 | Default after bake-off; SH3, 12k steps, `--keep-crs` |
| splat-apple / OpenSplat | Not needed — msplat quality validated |

## Bake-off evidence

Three fixed datasets (`IMG_0887`, `XfQW5xJoP1`, `IMG_0899`) trained with msplat
and compared against frozen Brush artifacts (camera-fit / train-cam snapshots).
User interactive review of `IMG_0899` raw: reconstruction looks excellent.

Baseline metrics: `phase2/artifacts/v2-sh3/` (see
[`phase2-native-cutover.md`](phase2-native-cutover.md)).

## Closers (finish Phase 2)

1. **Densify / opacity** — stricter product defaults (grad thresh 0.0004,
   refine every 150, stop screen-size at 3000, reset alpha every 25). Validated
   on `IMG_0887` (`phase2/artifacts/v3-densify/`): raw gaussians 137k → 48k,
   peak RSS ~19.2 GB → ~15.9 GB.
2. **In-process** — vendored `MsplatCore.xcframework` + Swift wrapper from
   msplat v1.1.3; `MsplatInProcessBackend` is default; CLI via
   `SAVOR_MSPLAT_BACKEND=cli`.
3. **Viewer polish** — `framing.json` + open-time peripheral cull (earlier in
   Phase 2).

## Stack

`AVFoundation → PhotogrammetrySession → msplat (Metal) → SplatCleaner → MetalSplatter`

Phase 2 is complete. Phase 3 is the Apple-flex demo layer (RealityKit splat
API, SHARP preview, visionOS, polish).
