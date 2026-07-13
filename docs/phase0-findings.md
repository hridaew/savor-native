# Phase 0 findings

Status: **complete — functional pass with a quality caveat**. RealityKit poses
fed the unchanged Brush trainer successfully on two captures, and calibrated
matched-view renders show correct orientation and recognizable subjects. The
Apple reconstructions retain less fine geometry and background detail than the
COLMAP baselines.

## Environment

- macOS 26.5 on Apple silicon
- Xcode 26.3, macOS 26.2 SDK
- Swift 6.2.4
- RealityKit `PhotogrammetrySession.isSupported == true`
- Brush v0.3.0, arm64, ad-hoc signed and not quarantined

## Empirical RealityKit payload schema

The installed SDK and a real request established these public payloads:

- `PhotogrammetrySession.Poses.posesBySample: [Int: Pose]`
- `PhotogrammetrySession.Poses.urlsBySample: [Int: URL]`
- `Pose.translation: SIMD3<Float>`
- `Pose.rotation: simd_quatf`
- `Pose.intrinsics: simd_float3x3?`
- `PointCloud.points: [PointCloud.Point]`
- `PointCloud.Point.position: SIMD3<Float>`
- `PointCloud.Point.color: SIMD4<UInt8>`

The pose sample IDs for `XfQW5xJoP1` were contiguous `0...149`.
`urlsBySample` is the authoritative sample-to-image mapping; relying on a
separate filename sort would be an avoidable silent-corruption risk.

One important availability correction to the original plan: `Poses` is
available on macOS 14, but `Pose.intrinsics` was introduced in macOS 26. The
package keeps a macOS 14 baseline while the dataset-export code explicitly
runtime-gates intrinsics-dependent work to macOS 26.

## First capture: `XfQW5xJoP1`

Input and COLMAP baseline:

- 150 portrait JPEG frames at 1080 × 1920
- COLMAP registration: 150/150
- COLMAP sparse points: 51,388
- Existing cleaned splat: 70,087 gaussians
- Existing raw 12k Brush export: 76,137 gaussians

Apple export using sequential ordering, high feature sensitivity, and object
masking disabled:

- Pose registration: 150/150
- Sparse points: 12,999 on the first measured run; 13,004 on the verification run
- Warm end-to-end pose + point-cloud requests: 34.6 and 32.8 seconds
- `transforms.json`: 111 KB
- `sparse_pc.ply`: 892 KB

The warm timing followed an exploratory request whose output logging was too
verbose to yield a trustworthy cold-run duration, so it must not be presented
as a cold benchmark.

The small pose/intrinsics shifts and five-point difference between repeated
runs show that RealityKit's result is not byte-for-byte deterministic. The
dataset used for the final matched Brush run is pinned by these SHA-256 hashes:

- `transforms.json`: `153af34f608fa7c25de0061866b18c22232eece2f939fb5578fdc85ba576b816`
- `sparse_pc.ply`: `3af4af8b2f7d293a5bc55598e63b6a3d09772914edf3df1ccf200de113d6a603`

Matched Brush result using the main app's exact recipe:

- Training time: 12 minutes 6 seconds
- Raw 12k export: 51,206 gaussians and 7.4 MB
- Cleaned HQ scene: 45,737 gaussians and 6.95 MB
- Cleaned fast scene: 2.56 MB

For comparison, the COLMAP-pose baseline has 76,137 raw and 70,087 cleaned
gaussians. The Apple result therefore retains about 67% of the baseline raw
count and 65% of the cleaned count despite starting from only about 25% as many
sparse points. Gaussian count is a plausibility check, not a quality verdict;
the matched-view result is recorded below.

## Second capture: `IMG_0899`

The provided 32.43-second, 3840 × 2160, 59.97 fps video was reduced to 150
sharpness-selected 1920 × 1080 frames using the main app's extraction recipe.
Both SfM paths consumed those exact images.

Apple export using sequential ordering, high feature sensitivity, and object
masking disabled:

- Pose registration: 150/150
- Sparse points: 30,995
- Pose + point-cloud request: 64.3 seconds
- Raw 12k Brush result: 246,347 gaussians and 37.45 MB
- Training time: 16 minutes 5 seconds
- Cleaned HQ scene: 238,118 gaussians and 36.19 MB

Matched COLMAP baseline:

- Pose registration: 150/150
- Sparse points: 95,494
- Feature extraction, matching, and global mapping: 3 minutes 2 seconds
- Raw 12k Brush result: 533,729 gaussians and 81.13 MB
- Training time: 17 minutes 36 seconds
- Cleaned HQ scene: 524,611 gaussians and 79.74 MB

The Apple reconstruction starts from 32% as many sparse points and retains 46%
of the raw and 45% of the cleaned baseline gaussian count.

## Matched-view comparison

The comparison renderer used the same source-frame camera for each pair:
RealityKit's OpenGL camera-to-world matrix for Apple and the corresponding
COLMAP world-to-camera pose converted to OpenGL camera-to-world. Each camera
translation was transformed by the same center and scale applied to its cleaned
splat, and each projection used that reconstruction's calibrated intrinsics.

Observed results:

- `XfQW5xJoP1`, frame 50: the Apple and COLMAP subject silhouettes and viewpoint
  align closely. Apple loses base and background detail and is visibly softer.
- `IMG_0899`, frames 50 and 100: both Apple views show the correct side of the
  subject at the same framing as COLMAP. The reflective figure is recognizable
  and coherent, with no mirroring, inversion, or gross pose drift.
- On `IMG_0899`, COLMAP preserves substantially more fine surface structure and
  surrounding people and walls. Apple's background is sparse or smeared and its
  reflective edges are less stable.

Evidence is stored under `phase0/compare/screenshots/`.

## Coordinate checks

RealityKit translation and rotation were composed as a camera-to-world
transform. The transform uses the OpenGL camera basis expected by Nerfstudio:
camera forward is the negative Z column.

Automated checks passed for:

- registration coverage of at least 90%
- at least 90% of camera forward axes pointing toward the point-cloud centroid
- a broad orbit-radius inlier check that rejects extreme non-ring paths

Passing the direction tests on all 150 poses in both captures was strong
evidence against a world-to-camera or Z-axis inversion. The matched trained
renders confirm the convention empirically.

## Phase 0 decision

Apple's SfM **can feed a splat trainer**, so Phase 0 passes its functional gate.
Both captures registered completely, trained without adapter changes to Brush,
and rendered from source-camera viewpoints with the expected orientation.

This is not a quality-parity result. Before removing COLMAP as a fallback, later
phases should evaluate Apple's lens-distortion payload, point-cloud
initialization density, and additional difficult materials and capture paths.
Those are quality risks, not evidence of a pose-format or
coordinate-convention failure.
