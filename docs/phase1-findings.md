# Phase 1 findings

## Status

Phase 1 established the end-to-end native app path. Phase 2 replaced the
trainer with pinned msplat 1.1.3; see
[`phase2-native-cutover.md`](phase2-native-cutover.md).

The shipping runtime is Apple frameworks plus the vendored msplat CLI (and its
`default.metallib`). The app does not invoke a terminal, Node, Python, or
ffmpeg.

## Implemented path

1. AVFoundation samples approximately 150 oriented JPEG frames with a
   1920-pixel maximum long edge.
2. RealityKit `PhotogrammetrySession` estimates camera poses, intrinsics, and a
   sparse point cloud.
3. `PoseDatasetWriter` transactionally writes a Nerfstudio dataset.
4. `MsplatInProcessBackend` trains in-process (default 12,000 steps, SH degree 3,
   `--keep-crs`, stricter densify). CLI recovery via `SAVOR_MSPLAT_BACKEND=cli`.
5. `SplatCleaner` postprocesses the raw PLY (floaters/haze, centering, framing.json).
6. MetalSplatter reads the cleaned PLY and renders it in an `MTKView`.

`PipelineRunner` owns orchestration and cancellation. Camera math and progress
mapping remain in `SplatEngine`; app lifecycle and presentation remain in the
`SavorNative` target.

## App behavior

- The primary window supports video drag-and-drop and a native file picker.
- Only one capture can run at a time. A second request is cleanly blocked.
- An advisory capture-root lock prevents a second app process from recovering
  or modifying live work owned by the first process.
- Each source video is copied into
  `~/Library/Application Support/SavorNative/captures/<id>/`.
- Capture metadata is atomically persisted in `capture.json`.
- Relaunch terminates a matching orphaned trainer process (lease file), then
  converts any queued or in-flight record to `interrupted` rather than showing
  a capture that appears to run forever.
- Existing completed captures can migrate to a cleaned sibling without
  overwriting the raw trainer PLY.

## Viewer

- RealityKit captures are treated as `+Y` up.
- Orbit, pan, fit, reset, auto-rotate, and an up-axis toggle are available.
- When `dataset/transforms.json` is nearby and matches splat extent, the
  initial fit uses the capture camera ring; otherwise opaque/compact point
  framing is used.

## Verification notes

- Unit coverage includes cancellation cleanup, trainer process termination,
  cleaner transforms, and camera framing.
- The vendored MetalSplatter PLY reader accepts SH degrees 1, 2, or 3
  (`f_rest` counts 9 / 24 / 45).
