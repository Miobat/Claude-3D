# Adaptive Terrain — implementation and acceptance

Branch `codex/adaptive-terrain`, based on published save/recovery fix `e3a1172`.
No integration-branch merge or changes to LBG Site Planner are included.

## User operation

Terrain → Scan settings → Terrain sampling → **Auto**. Fixed 5/10/20 cm options
remain available and existing saved settings stay fixed. Range remains radial
distance from the phone. Start around 3 m; move slowly over exposed ground.

- Blue: observed depth, not a continuously reconstructed ground surface.
- Ice-cyan dots: nearby repeated observations retained at 5 cm in a confirmed
  detail patch. Not photo quality, sensor accuracy or complete feature coverage.
- Amber hatching: uncertain/newly exposed patches; revisit slowly from another
  angle. Uncertain geometry is kept at fine sampling, not discarded or invented.
- The optional detail/revisit toggle leaves ordinary blue coverage available.
  Overlay Off still retains the range blur and the same capture filtering.

## Capture implementation

`StorageCore/AdaptiveTerrain.swift` is compiled directly into iOS (A/B10052) and
tested as the same implementation with Swift Package Manager. `DepthPointAccumulator`
routes only Adaptive Terrain to it; existing fixed modes keep their old path.

Incoming reliable, in-range positions are binned at 5 cm before classification in
20 cm 3D parents. Only observed XYZ is retained; colour alone is averaged. The
parent grid is 3D, so walls and stacked surfaces are not collapsed to an XY raster.
Repeated observations must be separated by 0.12 s; analysis runs at most every
0.25 s. Local covariance fits require two-dimensional support, and the 80th
percentile plane residual measures roughness without deleting input outliers.

Neighbour direction changes (dot product < 0.95), supported plane separations
(> max(3 cm, 4 × residual)) and structured roughness nominate detailed patches.
Two feature votes promote to sticky 5 cm sampling; three smooth votes plus
neighbour support on all four tangent-plane sides allow 20 cm retention.
Unobserved margins remain fine/uncertain instead of being treated as flat ground
or certified physical edges. Smoothness is independent of slope angle relative to gravity.
A one-parent neighbour margin uses 10 cm. No parameters are accuracy guarantees.

Fine candidate detail remains cached in active smooth parents. The active set is
bounded to 2,000 parents and surplus detail is released after two seconds unseen
or cache pressure. Confirmed detailed/uncertain geometry is not evicted. A newly
exposed deviation invalidates a smooth claim and collects fine observations again;
compacted patches request a revisit rather than pretending lost observations exist.

Memory accounting reserves eight 128-byte units per parent plus one per cached or
retained fine sample, within the existing shared Terrain/coverage budget. There
is no minimum overriding low memory and no unbounded dense full-site archive.
The existing capacity pause, serial worker, epoch invalidation, range/confidence
filter, asynchronous drain and save reserve are retained. A complex/noisy site may
remain dense and reach capacity sooner than a smooth one. No unlimited-area claim.

Snapshots contain the current retained positions and colours. Checkpoints retain
the adaptive settings and variable-density geometry, not a resumable AR map or
live detector history. As before, Recover opens the checkpoint for saving, never
appends new geometry to an old coordinate system. Native save is transactional;
failed saves preserve recovery. Adaptive saves use the same translation-only frame
as fixed Terrain; no additional downsampling, levelling or smoothing is applied.

Native PLY sharing includes a schema-2 terrain manifest. See
`TERRAIN_EXPORT_CONTRACT.md`; no uniform spacing is asserted for adaptive data.

## Automated release gates

- Synthetic flat/smooth tilted surfaces, kerbs, ditch rim/bottom, ramp toe/crest,
  narrow channels, noise, unreliable samples, duplicate frames, gaps, stable
  detail classification, range rejection, capacity and cache compaction.
- Retained positions must be a subset of real supplied points. Slopes and stepped
  levels must survive, without filling missing strips or moving XYZ to cell centres.
- Variable-density metadata, legacy fixed metadata and unknown version handling.
- Native checkpoint/save failure/retry, viewer reload, duplicate/move and SHA-bound
  export; existing 5 m range-rounding regression remains in the release gate.
- Native Metal tests for detail/revisit/ordinary coverage, unknown pixels and the
  range boundary. Light/dark, large-text and landscape adaptive UI previews.
- CPU benchmark logs compare output count with fixed 5 cm on the same synthetic
  surface. This guards regressions; it does not establish phone frame rate.

## Physical acceptance still required

1. iPhone 16 Pro: scan the same short flat patch, ramp, kerb and shallow ditch at
   fixed 5 cm and Auto. Compare exposed edges and independently checked elevations.
2. Move quickly once, revisit slowly; confirm uncertainty clears only with actual
   observations, range blur clips all patterns, and previously captured detail is
   stable. Check sparse-to-dense transition regions in the saved viewer.
3. Include grass, leaves, dark/wet ground and an unscanned strip. Do not expect bare
   earth extraction or automatic semantic ditch identification. No gap may be filled.
4. Stop/Continue, Keep for Later, force-close/recover and retry saving. Do not
   uninstall when testing with unfinished captures. Existing scans must still open.
5. Longer outdoor walk: log heat, memory, frame responsiveness, count/file size and
   drift against known control. Repeat on an older LiDAR phone before claiming
   performance parity. Fine sampling cannot correct AR pose drift or sensor noise.
6. LBG: inspect slopes and levels after control-point registration; check an
   independent height at the far end. Do not infer survey accuracy from density.
