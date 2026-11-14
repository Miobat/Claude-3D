# Drift correction for long point-cloud scans

Branch `claude/iphone-scanning-app-WHgvb`, based on the published design release
`da8a866` (TestFlight 1.1.0, build 202611072147). Owner request, 2026-11-11: a
long Point Cloud scan of a straight concrete canal came out bent (about 2° over
~12 m) with walls recorded two to four times, 10–30 cm apart. Short scans are
accurate to about a centimetre and must stay exactly as they are.

## Why it happened

Point Cloud / Terrain place each LiDAR sample using the phone's pose at that
instant and never move it again. Phone tracking drifts, mostly in heading and
mostly while turning on the spot, so a later pass over the same place lands
somewhere else. ARKit also corrects its own map over time, but points already
stored never followed those corrections. (Fast mode uses ARKit's mesh anchors,
which do follow them.)

## What is recorded while scanning (Point Cloud, fixed-spacing Terrain)

- The walk is cut into **segments**: a new one every 1.5 m, every 30° of
  turning, after 12 s, when ARKit visibly snaps the position estimate, on the
  next tick after ARKit moves the active segment's anchor by more than
  5 mm / 0.05° (points recorded after such a move are already in the corrected
  frame and must not get that correction again; after 60 such restarts at most
  one every 2 s), and after any pause or interruption. At most 200 per capture
  (stretches get longer after 100 and 150).
- Each segment owns a plain `ARAnchor` at the phone's pose when it started.
  ARKit keeps anchors current as it refines its map.
- Every stored point remembers its segment (`Cell.segment`, two bytes; the
  cell already had the padding, so capture memory is unchanged).
- The walked path, position snaps and seconds of fast turning are kept.
- Hints while scanning: "Turn slowly — fast turns bend long scans" and "Step
  sideways while you turn — turning on the spot bends long scans".

Not recorded for Splat (its points must stay in the frame of its camera poses),
Auto terrain (own sample store), Fast and High Quality. Those save as before.

## What happens at save (`DriftPipeline.prepare`)

0. **Short scans are never touched.** Under 10 m of walking the capture is
   saved bit-identical, whatever ARKit did to its anchors (`tooShort`).
1. **The phone's own corrections**, relative to the first segment: a shift of
   the whole map is no change. For each other segment: anchor transform now vs
   when its points were recorded. Under 5 mm and 0.05° counts as exactly
   nothing; over 3 m or 15° is ignored as implausible. The segment's points
   move rigidly with their anchor.
2. **Lining up passes** (`DriftRefiner.refine`, point spacing ≤ 5 cm only).
   Segments are visited in capture order. Each is fitted (point-to-plane) onto
   everything captured at least three segments earlier, and its correction is
   carried forward to all later segments, because drift accumulates. A small
   least-squares problem then spreads the corrections along the walk:
   neighbouring segments keep their measured step (tight sideways, looser along
   the walk and in height, heading loosest and loosest of all while turning),
   gravity stays gravity, overlapping surfaces must coincide. The first
   segment never moves.
3. **Do no harm.** If no place was scanned twice: nothing. If the largest
   disagreement between passes is under 2.5 cm: nothing. If the result is not a
   clear improvement (overlap mismatch must fall to 60 % or less): nothing.
   "Nothing" means the saved points are bit-identical to the capture.

Whole segments move rigidly. No point is added, removed, averaged or
recoloured. The usual save steps (thinning to the Detail spacing, level/square
frame, terrain translation) run afterwards on the corrected points. Terrain
keeps one pass per sampling cell: where correction lays a later pass (three or
more segments on) onto an earlier one, the later pass's samples in that cell
are dropped. Samples of the same pass are never dropped.

Corrected points are never saved without the record that can undo them: if
the record cannot be stored, the capture is saved exactly as recorded instead
(`ScanAlignmentError.recordNotSaved` → second pass without drift).

Directions the shape does not constrain are never guessed: sliding along a
plain wall or canal, turning on a flat floor. Error along the length of a
featureless straight structure therefore stays (it is also invisible in the
cloud). Without any overlap nothing can be detected at all: use references.

Setting: Scan settings → Long scans → "Correct drift on long scans" (on by
default, Point Cloud and fixed Terrain). Off = saved as captured; the walk is
still recorded.

## Files

- `<base>_alignment.json` (`ScanAlignmentDocument`): per-segment poses as
  captured / after the phone's corrections / as saved, overlap links, the
  segment of every saved point in file order, the walked path, the summary.
  Bound to the model file by SHA-256; a record that does not match is refused.
- `<base>_references.json` (`ScanReferenceDocument`): known distances, straight
  lines, control points.
- `Scan.alignment` (`ScanAlignmentSummary`, optional): shown under Info.
- Both sidecars follow move / duplicate / delete and are added to the native
  share ZIP as `alignment.json` and `references.json`; README and
  `coordinates.json` state what was done.
- `MeshData.pointSegments` / `.alignment` (optional) travel with the pending
  capture and its recovery checkpoint. Old checkpoints still load; a
  checkpoint whose drift data is unusable is saved as captured.

## Info → Accuracy & alignment

- Drift report: walked distance, segments, what lining up did, the phone's own
  corrections, largest move applied, position snaps, fast turning.
- **Save as-captured copy**: a new scan with the points exactly as recorded
  (from the saved points and the record; no second copy is stored).
- **Check against known measurements** (any scan; never changes it), using
  points placed with the ordinary Measure tools:
  - Known distance: a Distance measurement plus the taped value.
  - Straight line: a Path with three or more points along an edge that is
    straight in reality; shows the largest bow.
  - Control points: any measured point plus east / north / height.
- **Create fitted copy** (point clouds): a new scan in which the segments are
  moved so the references hold. With control points the copy is in the
  surveyor's grid minus a whole-metre origin: X = east, Y = height,
  Z = −north. Two control points fix heading and position (the scan is never
  tilted); three or more also show the misfit. A scan without a walk recording
  can only be turned and shifted as a whole onto control points.

## Code

| File | Role |
|---|---|
| `StorageCore/DriftMath.swift` | Double-precision rigid poses, SO(3) exp/log, Jacobi eigen, Cholesky, yaw-only fit |
| `StorageCore/DriftRefiner.swift` | Segment samples, spatial hash, point-to-plane fit, graph solver, `refine` |
| `StorageCore/DriftCapture.swift` | `AlignmentCapture`, `CaptureSegmenter`, summary, sidecar, `DriftPipeline`, `PointCloudPLYReader` |
| `StorageCore/DriftReferences.swift` | Reference document, report, fit |
| `Services/LiDARScanner.swift` | Segments + anchors (`advanceSegment`), per-point segment, `alignmentCapture()` |
| `Views/Scanner/ScannerView.swift` | Setting; `savePointCloudFlow` runs the pipeline |
| `Services/StorageManager.swift` | Sidecars, `saveAsCapturedCopy`, `saveFittedCopy`, export |
| `Views/Viewer/AlignmentSheet.swift` | The Info sheet |

Xcode IDs A/B10054–10058. Tests: `DriftAlignmentTests.swift` (synthetic
captures with known truth) and `DesignPreview.checkDriftAlignment` (real
storage paths on the simulator).

## Evidence so far, and what it does not show

A Python prototype of the same algorithm was run on simulated captures with
realistic drift (first-point-per-cell storage, U-turns, heading wander):

| Simulated case | Error before | After |
|---|---|---|
| Canal 25 m, out and back | 39 cm rms | 4 cm (sideways/height < 1 cm) |
| Canal, four passes | 37 cm | 2.5 cm (sideways/height 0.5 cm) |
| Facade 30 m, out and back | 49 cm | 7 cm |
| No drift / small object orbit | 0.5–0.6 cm | unchanged (not touched) |
| Single pass | — | unchanged (nothing to match) |

The remainder is error along the structure's length. The Swift port reproduces
the prototype on the unit-test scenes. **None of this is a phone test.** It is
not yet known how much ARKit moves plain anchors in practice, how real drift
is distributed, or how long lining up takes on large clouds. The Info sheet
and the exported `alignment.json` exist to answer that from real scans.

## Phone acceptance (owner)

1. Short scan of a small object, as before: Info must say "saved as captured"
   or "passes already agreed"; a tape check must be as good as before.
2. A long straight structure (house facade, 20 m+), out and back, including a
   turn on the spot: compare with the same walk with the setting off (or the
   as-captured copy). Doubled walls should merge; note the saving time.
3. Tape a long distance across the scan and add it under Accuracy & alignment.
4. Share the scan ZIP: it contains `alignment.json` for analysis.
5. Terrain 5 cm with two passes: no doubled ground, slopes preserved.
6. Pause/resume, background interruption and Keep for Later mid-capture: the
   scan must still save (as captured if the record is unusable).

## Limits and open work

- No correction where nothing overlaps; no correction along unconstrained
  directions; no field-accuracy guarantee.
- Lining up is skipped above 5 cm point spacing (Terrain 10/20 cm): only the
  phone's own corrections apply there.
- At most 200 segments; a very long walk gets longer stretches.
- A recovered capture from before this version has no record: saved as before.
- Fitted copies are point clouds only. Meshes can be checked, not fitted.
- Not done: automatic loop detection beyond the drift capture radius (about
  0.35 m per step after carrying corrections forward), time-based blending
  inside a segment, references on Fast/HQ scans, on-site AR.
