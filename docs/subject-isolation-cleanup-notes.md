# Subject isolation + cleanup — work beyond the plan

Status as of 2026-07-12: **pinned**. Shipping cleanup matches the original
GitHub savor floater + haze method. Hard subject crop is off by default.
Cleaned/Unfiltered viewer toggle remains.

## Original plan (subject isolation clean)

Goal from the plan:

1. Hard-crop object captures to a subject core after floater/haze, write
   `scene-hq.ply`, track `subjectIsolatedCount`.
2. Viewer toggle: **Cleaned** (`output/scene-hq.ply`) vs **Unfiltered**
   (`training/splat.ply`).
3. Re-clean IMG_0887; add tests for isolation vs environment mode.

Motivation: haze alone left opaque densification shells (IMG_0887 kept
~193k/198k). XfQW5xJoP1 / IMG_0899 often looked fine without a hard crop.

## What shipped from the plan

### Cleaner plumbing

- `SplatCleaningConfiguration`: `isolateSubject`, `subjectKeepMultiplier`,
  `orbitKeepFraction`, later density knobs (`densityPeakFraction`,
  `densityFloor`).
- `SplatCleaningResult` / `CaptureCleaningSummary` / `framing.json`:
  `subjectIsolatedCount` (optional on summary for older captures).
- After floater + haze, optional hard isolation for `!isEnvironment`;
  recompute normalization from the kept cloud.
- Environment captures skip hard isolation (cameras inside compact core).
- `phase2-reclean` / `phase2-evaluate` print or record isolation counts.

### Viewer

- ContentView segmented **Cleaned / Unfiltered** when raw PLY exists.
- Switching view bumps camera reset; Export PLY follows the active view.
- `CaptureRecord.activeSplatRelativePath(unfiltered:)` + AppModel URL
  resolution; light tests for path preference and summary encode.

### Validation tooling

- Re-cleaned App Support captures via `phase2-reclean` during the spike.
- Tests: opaque shell removed when isolation **on**; environment skips
  isolation; empty PLY fails fast; default config does **not** hard-isolate.

## Work beyond the plan

### 1. Empty training PLY hung postprocessing

**Symptom:** New capture stuck on “Cleaning and framing scene.”

**Cause:** msplat exported `element vertex 0`. MetalSplatter’s binary PLY
reader did not advance past zero-count element groups and never finished the
async stream, so `SplatCleaner.clean` never returned.

**Fixes (not in the plan):**

- Preflight vertex count from the PLY header in `SplatCleaner.clean`; throw
  `emptyInput` before `readAll()`.
- Skip zero-count element groups up front in
  `Vendor/MetalSplatter/PLYIO/Sources/PLYReader.swift` (ASCII + binary).
- Trainers (`MsplatInProcessBackend`, `MsplatBackend`) throw `emptyExport`
  when `gaussianCount == 0` so the pipeline fails clearly instead of hanging
  in postprocess.

### 2. Hard isolation was too aggressive (amputated subjects)

Density / radius hard crop (core × ~1.08, orbit × 0.75, sparse outer floor)
did remove shells on IMG_0887, but on IMG_0899 it dropped connected subject
parts (e.g. legs) that reconstruct thinner than the torso peak.

That matches why the original savor repo **deleted** subject-isolation /
connected-component crop in v3: it amputated subjects. Intended cleanup there
is:

1. **Global floaters** — lonely / faint+sparse / needle at own scale.
2. **Orbit-interior haze** — weak clumps between subject and cameras (skipped
   for environment captures).

Subject center/radius are **measurement only** — not a deletion mask.

### 3. Rollback to correct default cleanup

- Default `isolateSubject = false`.
- Optional hard isolation left in code for experiments
  (`SplatCleaningConfiguration(isolateSubject: true)`), not used by the app
  postprocessor.
- Re-cleaned latest App Support captures with floater+haze only, e.g.:
  - IMG_0899 (`75a2f2e3…`): ~56k → **~113k** kept, `isolated=0`
  - IMG_0887 (`25cfb8a6…`): back to ~**194k** kept, floater/haze only

### 4. Compact-radius haze refinements (pre/alongside isolation)

Still valuable and kept (separate from hard crop):

- Environment detection and haze annulus use **compact** opaque core radius so
  densification shells don’t inflate “subject radius” past the cameras and
  skip haze.
- Display-time peripheral cull (`SplatDisplayCulling`) remains viewer-side
  only; it does not rewrite the PLY.

## Current shipping behavior

| Stage | Behavior |
|-------|----------|
| Train | Fail if zero Gaussians exported |
| Clean | Floater + haze; recenter/normalize; write `framing.json` |
| Hard isolate | **Off** by default |
| Viewer | Cleaned PLY default; Unfiltered → raw training PLY |
| Export PLY | Active view (cleaned unless Unfiltered selected) |

## Open / parked

- Opaque densification shells (IMG_0887-class) can still survive floater+haze.
  A safer future approach than radial density crop: **connected-component
  grow** from the densest seed (keep attached thin parts; drop disconnected
  outer components only). Not implemented.
- Empty-splat training root cause (why msplat sometimes exports 0 vertices on
  a capture that previously succeeded) not fully diagnosed.
- Stuck `postprocessing` capture records from the hang may need cancel/retry
  or a one-shot metadata fix after relaunching a build that includes the
  empty-PLY fail-fast.

## Key files

| File | Notes |
|------|--------|
| `Sources/SplatEngine/SplatCleaner.swift` | Floater/haze + optional isolation |
| `Sources/SplatEngine/MsplatInProcessBackend.swift` / `MsplatBackend.swift` | `emptyExport` |
| `Vendor/MetalSplatter/PLYIO/Sources/PLYReader.swift` | Zero-vertex finish |
| `Sources/SavorNative/ContentView.swift` / `AppModel.swift` | Cleaned/Unfiltered |
| `Sources/Phase2Reclean/main.swift` | Re-clean CLI |
| `Tests/SplatEngineTests/SplatCleanerTests.swift` | Isolation opt-in + empty PLY |

## Lineage (cleanup philosophy)

```
savor GitHub v3: floater + orbit haze; subject = framing only
Savor-New plan:  + hard subject isolation for densify shells
spike:           density/radius crop → amputated extremities
pinned:          isolation off; floater + haze default again
                 (+ empty-PLY hang fixes + Unfiltered toggle)
```
