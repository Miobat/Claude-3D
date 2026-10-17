# TinyScanner Terrain v1 — planner handoff

Implementation branch: `codex/terrain-capture`. This contract is the proposed and
implemented scanner-side v1; the planner should independently validate it. It does
not require updates to ordinary PLY readers and does not change existing exports.

Native Share delivers a ZIP with one scan folder containing:

- `model.ply`: binary little-endian XYZ Float32, optional RGB UInt8; NO faces.
- `coordinates.json`: existing coordinate/provenance contract, unchanged.
- `terrain.json`: the optional terrain contract below, tied to model bytes by SHA-256.
- `README.txt`: limitations and import instructions.

Extract the ZIP and import the PLY and optional JSON companions together. The
planner must continue to support the PLY alone. Unknown/newer/invalid metadata or a
hash mismatch must not silently change coordinates or certify ground coverage.

## terrain.json (schemaVersion 1)

```json
{
  "schema": "com.tinycorp.tinyscanner.terrain",
  "schemaVersion": 1,
  "modelFile": "model.ply",
  "modelSHA256": "<64 lowercase hexadecimal characters>",
  "coordinatesFile": "coordinates.json",
  "units": "metres",
  "upAxis": "Y",
  "handedness": "right",
  "coordinateFrame": "scanLocal",
  "transformsAlreadyApplied": true,
  "spacingMetres": 0.1,
  "pointCount": 123456,
  "captureRangeMetres": 3.0,
  "sampling": "oneObservedPointPerCaptureVoxel",
  "groundClassification": "unclassified",
  "coverage": "retainedSamplesOnly",
  "interpolated": false,
  "unknownAreas": "notReconstructed",
  "verticalDatum": "localLowestObservedSampleNotSurveyedGround",
  "registrationRequired": true,
  "limitations": ["Human-readable warnings; see the generated document."]
}
```

`spacingMetres` is 0.05, 0.10 or 0.20. It is the 3D voxel edge used DURING capture,
not guaranteed separation, resolution, a maximum gap, or an accuracy certificate.
The first reliable in-range observed point is retained in each voxel; only RGB is
averaged. A voxel can contain several different surfaces; use Detailed terrain or
the existing Points mode where small features matter. No synthetic points, ground
labels, reconstructed faces or observed-area polygons are supplied by v1.

Gravity/Y and the original capture yaw are preserved. The saved frame only
translates the scan: horizontal bounds centre becomes X/Z zero and the lowest
retained sample becomes Y zero. A slope is never flattened by plane fitting.
`coordinates.json.provenance.captureToLocal` describes this already-applied
translation. Do NOT apply it again. No CRS or surveyed elevation datum is supplied.
Compass-requested metadata does not replace control-point registration.

The planner can preserve metre scale, position/rotate with control pairs and align
height separately. Check additional reference points for error/drift. Use ground
selection, bounded triangulation, breaklines and unsupported-area masks rather than
filling every hole inside the bounding box/convex hull. All coordinates describe
observations, not guaranteed ground. Do not infer free space or bare earth under
cars, vegetation or buildings.

The scanner library stores optional `terrainCapture` metadata inside the existing
scan record; it is preserved by duplication/moving and recovery settings. Export
regenerates the SHA-bound sidecar from the delivered PLY. No per-scan terrain JSON
companion is required inside the library.

## First scanner release boundary

Terrain capture and coverage are memory-budgeted, pause explicitly at capacity,
and retain the existing periodic recovery checkpoints. Saving streams PLY bytes.
The total retained cloud remains in memory (up to a conservative two million
points, often less on a low-memory device). Automatic disk-streamed spatial
sections and adaptive edge sampling are NOT in v1. No unlimited area or survey
accuracy claim. Existing scan modes keep their current capture policy.
