# Savor Native

An Apple-native macOS pipeline for turning orbit videos into 3D Gaussian
splats.

AVFoundation extracts frames, RealityKit estimates camera poses and sparse
geometry, pinned **msplat 1.1.3** trains the splat (in-process Swift API by
default; CLI recovery available), and MetalSplatter renders the result.
Cleanup runs in pure Swift before viewing.

## Native app

Requirements:

- Apple silicon Mac with photogrammetry support
- Xcode 26 or newer
- macOS 26 or newer for per-image camera intrinsics
- Vendored msplat under `Vendor/msplat/` (`MsplatCore.xcframework` + Swift
  wrapper; CLI at `1.1.3/` for `SAVOR_MSPLAT_BACKEND=cli`)

Launch the app:

```sh
swift run -c release savor-native
```

Drop a video onto the window or use **New capture**. Workspaces and capture
history are stored under
`~/Library/Application Support/SavorNative/captures/`.

You can also open an existing splat directly:

```sh
swift run -c release savor-native /path/to/scene.ply
```

**Open sample** loads a bundled mini splat. Completed captures support
**Export PLY** and **Export USDZ** (when Object Capture produced a mesh).

### Optional SHARP instant preview

```sh
./scripts/setup-sharp.sh
```

When `sharp` is on PATH via `~/.savor-native/sharp/bin/sharp` (or
`SAVOR_SHARP_BIN`), the first extracted frame is predicted into an instant
preview while full training continues.

### Vision Pro narrative stub

```sh
swift run -c release savor-vision
```

See [`docs/phase3-findings.md`](docs/phase3-findings.md) — RealityKit
`GaussianSplatComponent` needs macOS / visionOS 27.

## Pose spike

Generate a Nerfstudio-compatible dataset:

```sh
swift run poses-cli /path/to/images /path/to/output \
  --sequential \
  --high-sensitivity
```

The output path must be new and disjoint from the input image directory. The
CLI stages the complete dataset beside it and commits the directory atomically.

The output directory contains:

- `images` — a symlink to the read-only source frames
- `transforms.json` — per-frame intrinsics and camera-to-world transforms
- `sparse_pc.ply` — RealityKit's colored sparse point cloud

Run the deterministic core tests with:

```sh
swift test
```

Phase docs: [`docs/phase2-bakeoff.md`](docs/phase2-bakeoff.md),
[`docs/phase2-native-cutover.md`](docs/phase2-native-cutover.md),
[`docs/phase3-findings.md`](docs/phase3-findings.md).
