# Texture quality and capture feedback — second upgrade batch

Branch: `codex/texture-quality-polish`, based on `codex/capture-trust-recovery`
at `b823cfb`. Depends on the first batch; do not replace it with old `main`.
Development pushes validate only. The owner subsequently requested publication;
dispatch TestFlight manually only after the validation and visual checks pass.

## Implementation

- Estimate translational motion blur using the nearer quartile of sampled LiDAR
  depth, rather than assuming every subject is 1.5 m away. The same calculation
  improves Fast photo selection and HQ/Splat motion guidance.
- Measure sparse image luminance off the main thread. Severely clipped/dark
  frames cannot create sharp-photo coverage; less severe lighting problems
  reduce selection weight and produce a capture hint. This is not an autofocus
  or perceptual-sharpness detector. Sharp status is an estimate.
- JPEG quality 0.92, atomic writes, explicit storage-failure feedback. Advance
  retained-photo spacing only after a successful write and retention. Mint
  remains tied to retained sharp photo IDs and their exact depth snapshot.
- Require matching positive depth at all triangle corners, edge midpoints and
  the centre. Unknown depth and foreground/background disagreement fall back
  to sampled colour, not projection of an unrelated camera image.
- Patch smoothing is deterministic and double-buffered, never downgrades sharp
  to soft, and retains at least 85% of the original best view score. The second
  pass cannot compound a first-pass quality loss.
- Reduce exposure seams only from bounded, sparse samples of the same surface
  visible in neighbouring photo patches. Use median log-luminance ratios, reject
  unstable/clipped/dark matches and require at least six samples per pair.
  Each connected component is anchored; gain stays in 0.8–1.25. No spatial
  blending, hallucinated detail, or ISO-based re-exposure of tone-mapped JPEGs.
  Images decode one at a time. No overlap evidence means no correction.
- Reserve padded 4-bit/channel colour swatches for faces without a usable photo,
  including unreadable JPEGs. This is flat sampled colour, not invented texture.
  Atlas memory limits and uniform patch downscaling remain in force.
- Save optional area-weighted texture diagnostics atomically with the model.
  Duplication retains them, re-reconstruction clears them, old scans still load.
- Capture HUD: icon/colour legend and retained sharp/soft photo counts, readable
  warnings, accessibility stacking. Viewer information menu: Texture quality
  sheet with area breakdown, atlas size/scale and next-scan advice. Existing
  capture controls, gestures and joysticks are unchanged.

## Validation

`swift test --package-path ScanView3D/StorageCore` includes regression tests for
motion distance, lighting, score gates, patch budgets, palette quantisation,
seam solver bounds/direction/components, and diagnostic serialization.

CI compiles device and simulator targets. Native fixtures exercise real image
decoding/orientation, bilinear padding, depth visibility, sharp/soft selection,
corner occlusion, missing-photo colour fallback, baked atlas pixels, save/reload,
duplication and old metadata compatibility. The required native check count
increases from 38 to 56. Existing Metal/SceneKit, storage and OpenUSD tests remain.
Screenshots include the real quality sheet and capture UI at large text and in
landscape; fixtures are synthetic and never enter the device build.

## Phone acceptance on an authorized TestFlight test build

1. Scan a small object at 0.3–0.5 m; move quickly then slowly. Confirm sharp/soft
   counts, photo coverage, final detail and no background colour stamped over it.
2. Scan a chair in front of a patterned wall and revisit from different angles.
   Inspect thin edges, corners and depth discontinuities for colour leakage.
3. Walk from darker to brighter areas. Inspect seams and confirm no double-image
   ghosting. Dark/glossy/transparent surfaces can still have incomplete detail.
4. Compare Fast captures at the same range/detail settings before/after. Read the
   quality report; sharp area is not scene completeness or survey accuracy.
5. Capture a large scene and confirm photo rate, thermals, memory, saving time,
   atlas reduction and reopening on iPhone 16 Pro, then other supported LiDAR
   devices. Higher JPEG quality may increase temporary disk use.
6. Test low storage, background/foreground, pause/resume and checkpoint recovery.
   Recovery still preserves vertex colour, not temporary full-resolution photos.

The simulator cannot establish optical quality, physical LiDAR accuracy, thermal
behaviour or sustained phone performance. Strict visibility may reduce photo
coverage on noisy edges in exchange for avoiding false detail. This is not TSDF,
multi-band seam blending, full photometric calibration or survey-grade scanning.
