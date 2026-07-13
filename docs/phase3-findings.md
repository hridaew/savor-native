# Phase 3 findings — Apple-flex layer

Status as of 2026-07-12: Phase 3 demo surface is in place on **macOS 26**.
RealityKit `GaussianSplatComponent` remains gated on **macOS / visionOS 27**.

## RealityKit splat viewer

| Check | Result |
|-------|--------|
| Machine | macOS 26.5.2, Xcode 26.3, SDK 26.2 |
| `GaussianSplatComponent` in SDK | **No** (introduced with OS 27) |
| Shipping viewer | MetalSplatter (`SplatMetalView`) |
| Prep for OS 27 | `SplatGPUBuffers` packs position/scale/rotation/opacity/SH in the WWDC26 buffer layout; attach sketch is commented in `SplatGPUBuffers.swift` |

`SplatViewerBackend` prefers `.metalSplatter` today. When the macOS 27 SDK is available, wire `GaussianSplatResource.BufferResource` from those buffers and append `.realityKit` to `availableBackends`.

## SHARP instant preview

Optional, non-blocking:

1. `scripts/setup-sharp.sh` installs Apple's `ml-sharp` into `~/.savor-native/sharp/`
2. Prefer Python 3.13; falls back to `python3` on PATH (this machine has 3.14)
3. Pipeline kicks `SharpPreviewRunner` after the first extracted frame
4. UI shows an **Instant preview** badge + y-down MetalSplatter view while training continues
5. Missing binary → silent no-op (tested)

Env override: `SAVOR_SHARP_BIN=/path/to/sharp`

## visionOS viewer (stretch)

`savor-vision` is a **macOS companion stub**. The vendored msplat XCFramework is
`macos-arm64` only, so the root package cannot declare `.visionOS` without
breaking the trainer link. Closing-slide path:

- Capture + train on Mac (shared `SplatEngine`)
- View with MetalSplatter on visionOS (vendor already declares visionOS) **or**
  RealityKit Gaussian splat APIs on visionOS 27
- Bundle sample PLY under `Sources/SavorVision/Resources/Samples/`

## Polish

| Item | Status |
|------|--------|
| Export PLY | Completed-viewer **Export PLY** → `NSSavePanel` |
| Export USDZ | Best-effort `PhotogrammetrySession.Request.modelFile` → `output/mesh.usdz`; button when present |
| Sample capture | **Open sample** loads bundled `Resources/Samples/scene-hq.ply` |
| App icon | `Sources/SavorNative/Resources/AppIcon.icns` (use when wrapping a `.app`) |

## How to demo

```bash
# Optional SHARP
./scripts/setup-sharp.sh

swift run -c release savor-native
# Drop a video — preview appears if SHARP is installed; final scene replaces it.

swift run -c release savor-vision   # Vision Pro narrative stub
```
