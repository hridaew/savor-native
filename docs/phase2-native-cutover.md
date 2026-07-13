# Phase 2 native cutover notes

Status as of 2026-07-12: **Phase 2 complete.** msplat 1.1.3 is the product
trainer (in-process by default, CLI recovery). Brush runtime is removed.
Frozen Brush PLYs remain read-only visual references only.

> **Superseded:** the v3 trainer defaults below caused the glow/floater
> regression and were replaced — see [v4-recipe-fix.md](v4-recipe-fix.md)
> for the shipping recipe (15k steps, SH2, stock densify/reset cadence).

## User-validated quality

Interactive review of `IMG_0899` msplat raw (v2 SH3) confirmed the
reconstruction looks excellent. Stricter densify defaults (v3) cut gaussian
count and peak RSS on `IMG_0887` without a second bake of all three captures.

## Trainer defaults (shipping)

| Setting | Value |
|---------|-------|
| Backend | In-process Swift (`Msplat` + `MsplatCore.xcframework`) |
| CLI recovery | `SAVOR_MSPLAT_BACKEND=cli` → pinned `Vendor/msplat/1.1.3/msplat` |
| Steps / SH | 12 000 / degree 3 / `--keep-crs` |
| densifyGradThresh | **0.0004** (msplat stock 0.0002) |
| refineEvery | **150** (stock 100) |
| stopScreenSizeAt | **3000** (stock 4000) |
| resetAlphaEvery | **25** (stock 30) |

## Framing + open-time cull

Cleaned scenes write `output/framing.json`. Viewer / `phase2-snapshot` prefer
compact-core fit, then cull haze-like peripheral points on open. Existing
captures need `phase2-reclean` for `framing.json`.

## Metrics

### v2 bake (SH3, stock densify) — cutover baseline

Artifacts: `phase2/artifacts/v2-sh3/`

| Capture | Wall | Raw gaussians | Cleaned | Peak RSS |
|---------|------|---------------|---------|----------|
| IMG_0887 | 162s | 137,453 | 128,027 | ~19.2 GB |
| XfQW5xJoP1 | 153s | 155,403 | 144,092 | ~18.9 GB |
| IMG_0899 | 253s | 716,738 | 714,561 | ~34.8 GB |

### v3 densify validation (stricter defaults, CLI)

Artifacts: `phase2/artifacts/v3-densify/IMG_0887/`

| Capture | Wall | Raw gaussians | Cleaned | Peak RSS |
|---------|------|---------------|---------|----------|
| IMG_0887 | 148s | **48,382** | 43,422 | **~15.9 GB** |

Vs v2 on the same capture: ~65% fewer gaussians, ~3 GB lower peak RSS, similar
wall time. Defaults kept.

## What shipped in Phase 2

- Trainer: pinned msplat 1.1.3 — in-process primary, CLI recovery
- Cleanup: Swift `SplatCleaner` + `framing.json`
- Viewer: compact framing + open-time peripheral cull
- Process safety: `TrainerProcessRecovery` for CLI; in-process has no orphan PID
- Removed: Brush runtime

## Snapshot guide

```bash
phase2-snapshot RAW.ply out.png --transforms dataset/transforms.json --frame N
phase2-snapshot RAW.ply out.png --camera-fit dataset/transforms.json
phase2-snapshot scene-hq.ply out.png   # cleaned: framing.json compact fit + cull
```

See also [`phase2-bakeoff.md`](phase2-bakeoff.md).
