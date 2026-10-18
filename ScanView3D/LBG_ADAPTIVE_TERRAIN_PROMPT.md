# Prompt for the LBG Site Planner chat

Please update LBG Site Planner to support TinyScanner's Adaptive Terrain scans.
Inspect the existing LiDAR/PLY import, terrain generation, registration and
satellite-drape code first. Preserve all existing import and snapping behaviour.
Implement and test the following, and report what changed. Do not publish without
my separate approval.

Scanner repository: https://github.com/Miobat/Claude-3D
Scanner branch: `codex/adaptive-terrain`
Read `ScanView3D/TERRAIN_EXPORT_CONTRACT.md` on that branch first. Its schema is the
authoritative scanner-side contract. Scanner changes are being handled separately;
do not edit or publish TinyScanner from this chat.

## What is delivered

Native Share is a ZIP containing a scan folder with `model.ply`, `coordinates.json`,
`terrain.json` and a README. PLY is binary little-endian Float32 XYZ, optional
UInt8 RGB, with no faces. Coordinates are local metres, right-handed, Y-up, and
all documented export transforms are ALREADY baked into XYZ. No CRS or surveyed
vertical datum is provided. The lowest retained sample is local zero; GPS/compass
metadata is approximate, not survey control.

Fixed terrain continues to use `schemaVersion: 1` with `spacingMetres` equal to
0.05, 0.1 or 0.2. Existing scans and standalone PLY import must continue working.

Adaptive terrain uses the same schema name (`com.tinycorp.tinyscanner.terrain`)
and the following schema-2 fields:

```json
{
  "schemaVersion": 2,
  "sampling": "adaptiveObservedPointVoxels",
  "minimumSpacingMetres": 0.05,
  "maximumSpacingMetres": 0.2,
  "transitionSpacingMetres": 0.1,
  "adaptiveAlgorithmVersion": 1
}
```

There is NO `spacingMetres` in schema 2. Other v1 fields remain, including the
model filename, SHA-256, point count, units, axes, already-applied transform flag,
range, `groundClassification: "unclassified"`, `coverage: "retainedSamplesOnly"`,
`interpolated: false`, `unknownAreas: "notReconstructed"`, local vertical-datum
description, `registrationRequired: true`, and limitations.

These values describe sampling targets, NOT accuracy, maximum gaps or allowable
triangle lengths. Smooth surfaces retain coarse samples, shape changes keep fine
ones, and uncertain patches can also remain fine. The phone supplies real observed
positions without smoothing, interpolation or plane levelling. It does NOT export
ground labels, breaklines, observation footprints, empty-space masks, or proof that
an entire voxel was scanned.

## Required planner behaviour

1. Validate metadata version, schema, safe filenames, metre/axis declarations,
   finite values, point count and SHA-256 against the delivered PLY. Unsupported,
   inconsistent or corrupt metadata must produce a clear warning and leave a
   safe plain-PLY path available; never silently rescale or reorient the model.
2. Interpret fixed and adaptive density separately. Do not substitute 20 cm as a
   universal spacing for adaptive data, or thin the entire cloud to one coarse
   grid. Estimate local support robustly across sparse/dense transitions, avoiding
   rules where a dense patch forces holes everywhere in adjacent coarse terrain.
3. Build a bounded ground TIN/terrain only from ground selected or confirmed by
   the user. Avoid bridging unobserved strips, water/occlusions, disconnected
   surfaces, buildings or vegetation. Preserve slope breaks/ditch rims and support
   explicit clipping, exclusion zones and user breaklines. Local point spacing
   alone cannot establish coverage or prove a safe triangle; conservatively leave
   uncertain areas empty and explain why. Show generated/interpolated triangles
   separately from the measured point evidence.
4. Preserve gravity and real slopes. Retain metric placement, rotation, snapping
   and known-elevation alignment. Do not auto-flatten sloping ground, apply the
   coordinate transform twice, use phone GPS altitude as surveyed ground, or
   rescale points just to match the satellite image. Allow independent control
   checks after alignment and report discrepancies where supported.
5. Drape satellite imagery onto the accepted terrain surface only; imagery must
   not invent elevation or imply unscanned ground was measured. Keep unknown gaps
   visible and distinguish scan-derived terrain from other elevation sources.
6. Add import diagnostics: fixed/adaptive/unknown density, points, units, local
   elevation datum, non-ground/unknown-coverage warnings, and any rejected metadata.
   Keep processing responsive with workers/chunking as appropriate to the codebase.

## Tests and handoff

Use deterministic fixtures for schema 1 and 2, PLY without metadata, missing or
unknown metadata, hash/count mismatch, fixed and mixed 5/10/20 cm surfaces, a
smooth tilted plane, kerb, V-ditch, an unscanned strip, sparse-to-dense boundaries,
vegetation/non-ground samples, and negative coordinates. Verify preserved metric
distances/elevations and no doubled transform. Test registration/snapping and
satellite draping for regressions. A pretty surface alone is not proof of accuracy.

Tell me the branch, test results, remaining limitations and how to import a real
TinyScanner Auto scan for acceptance. Ask for an actual export if required rather
than assuming any undocumented scanner metadata exists.
