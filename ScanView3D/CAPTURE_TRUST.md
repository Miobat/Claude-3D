# Capture trust / recovery — first upgrade batch

Based on Claude's `487d5c4` updates. TestFlight publication is a separate,
explicit action; pushes to `codex/capture-trust-recovery` only validate.

## Changes

- Keep small-face hole reduction, but require the entire triangle to fit at
  least one real observation's radial range. Long triangles still require
  corner, centre and edge evidence. No smoothing / averaged clustering that
  can move vertices outside the observed boundary during final save.
- Low-confidence depth can match existing coverage, not create new evidence.
- Blue means captured shape in Fast + colour mode. Mint additionally requires
  a successfully written, sharp JPEG observing the same surface. Photo-depth
  snapshots belong to that exact frame, never the next free integration slot.
  Evicted photos invalidate their coverage claims. Other modes use mint for shape.
- Live legend explains the colours; memory-delayed / failed recovery writes
  are visible. The checkpoint timestamp advances only after successful writing.
- Coverage carries sampled camera RGB. Lightweight Fast recovery and colour
  sampling misses retain this fallback instead of classification colours / grey.
- Point and coverage budgets share conservative memory headroom for saving;
  old minimum capacities cannot override the calculated budget. HUD statistics
  use a short publication lock, not the full depth-integration lock.
- Mesh / point / HQ saves include required metadata in their initial index
  transaction. Failed saves keep the recovery draft for retry.
- Packed checkpoint decoding rejects partial elements, inconsistent arrays,
  invalid indices and nonfinite geometry. Legacy encoding remains readable.
- Native GPU, recovery and navigation tests gate every validation/release branch.
  Their report is required before the screenshot tour begins.

## Validation

`swift test --package-path ScanView3D/StorageCore` covers range boundaries,
photo ownership / eviction, sampled RGB and combined capacity limits alongside
the existing persistence, coordinate export and navigation tests.

GitHub Actions compiles both device and simulator targets, runs an independent
OpenUSD export reader and launches native SceneKit / Metal / packed-checkpoint
fixtures. `native-design-previews` includes `navigation-checks.json`, active
capture screenshots and large-text / landscape samples.

## Phone acceptance before publication

1. At 0.5 m / 1 m / 3 m, scan an object with a wall behind it. Check blur and
   mesh boundaries after saving; slowly orbit the object and revisit old areas.
2. Fast + colour: move quickly, then hold steady. Blue should turn mint only
   once a sharp photo is saved. Check tracking loss / pause / resume do not
   fabricate coverage. Compare the final texture with the live indication.
3. Repeat range checks in Points / HQ / Splat. Unknown depth remains excluded;
   glass, dark and reflective surfaces may stay incomplete.
4. Capture a large scene, watch memory / capacity and checkpoints. Confirm UI
   responsiveness, automatic pause at capacity, final saving and reopening.
5. After a successful checkpoint, terminate and reopen. Confirm usable shape
   and vertex colour, and save the recovery without losing location/provenance.
6. Recheck point-cloud measurements, touch-selected orbit, both joystick rates,
   vertical control and 1.8 m ground-locked walk from the previous batch.

## Deliberate limits / later batches

The simulator cannot prove LiDAR stability, sustained phone frame rate or optical
texture quality. Fast recovery retains vertex colour, not the full temporary
photo atlas. A mint area means a retained sharp-photo observation, not a promise
of complete high-resolution texture baking. Memory accounting is an estimate,
backed by the existing runtime low-memory pause guard.

Next work: better texture selection / seam treatment / quality diagnostics, then
the broader capture and review interface polish. This batch does not implement
TSDF reconstruction or claim survey-grade precision.
