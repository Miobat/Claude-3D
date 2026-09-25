# ScanView 3D — substantial upgrade plan

Prepared 24 September 2026 from the [source assessment](ASSESSMENT.md), baseline `a31504b`.

**Priority order: terrain/surveying, detailed objects, rooms/buildings.** This document plans implementation; it does not claim those upgrades are implemented or validated.

## Product direction

Build a dependable field-capture app that turns a walked site into a useful, traceable terrain deliverable. Keep the object and room workflows within the same project library, with capture settings appropriate to each job.

The first terrain release should support a bounded site that can be walked closely, using offline capture and local processing. Exact site size, acceptable error, reference equipment, phone model, and preferred desktop software remain to be established. These affect performance and accuracy acceptance thresholds, not the need to fix current storage/export defects.

Do not promise a fixed millimetre accuracy, recovery of ground hidden by vegetation, unlimited site coverage, or globally accurate positions from a single phone GPS fix. Sampling density, local measurement error, registration error, and absolute map accuracy are different quantities. The UI and exports should explain whichever are actually known.

## Delivery sequence

| Milestone | User-visible outcome | Depends on | Relative scope |
| --- | --- | --- | --- |
| 0. Baseline and validation | Existing behavior can be checked before changes ship | Current Claude branch | Small–medium |
| 1. Reliable capture and files | Saves, moves, retries, measurements, and exports survive expected failures | 0 | Medium–large |
| 2. Outdoor capture and coordinates | Terrain capture with coverage guidance, recovery, and traceable coordinates | 1 | Large |
| 3. Terrain workbench | Ground editing, terrain surface, contours, profiles, slope, volumes, useful exports | 2 | Large; split into several releases |
| 4. Larger and repeated surveys | Multiple subscans, control points, comparison, scalable viewing | 2 + validated 3 | Large/research component |
| 5. Detailed objects | Guided photo coverage, improved processing and desktop handoff | 1; scheduled after terrain MVP | Medium–large |
| 6. Rooms/buildings | Structured room capture, floor plans, openings, dimensions | 1; scheduled after object improvements | Medium–large |

Scope labels compare effort, not delivery promises. Estimate calendar time after the reference corpus and first vertical terrain slice exist. The terrain workflow is a sequence of engineering releases, not one large UI patch.

Design, accessibility, automated checks, and performance budgets are part of every milestone. Renderer modernization runs as a bounded prototype when benchmarks justify it.

## 0 — Establish a reproducible baseline

1. Preserve the current working branch/commit as the reference. Use one descriptive `codex/...` branch per implementation task, starting from the agreed current integration branch. Merge sequentially; never start from the old `main` accidentally.
2. Add a shared simulator scheme/configuration and a test target. Build the physical-device path too, because the mock cannot exercise ARKit or photogrammetry. Keep iOS 17 compatibility unless a deliberate feature decision changes it.
3. Add unsigned PR validation separate from TestFlight publishing: simulator build/tests, device compilation where supported without signing, source-registration checks, and exported test reports. Keep signing material restricted to the publishing job.
4. Create a small deterministic fixture set: an asymmetric colored model for axis/UV checks; a rotated/scaled HQ model; a known plane/ramp and polygon; textured OBJ with unusual material names; point-cloud PLY; an older library; corrupt metadata; and packages with missing companion files.
5. Establish device baselines for open/save/export time, memory, point picking, texture baking, temperature, and battery use. Record device, OS, scan mode, point/face/photo count, lighting, and file size with every measurement.

**Done when:** both code paths compile in CI, fixtures are versioned, current known failures are captured, and the first device performance/accuracy report exists. Tests that expose known defects must be explicitly tracked; they must not create a falsely green release gate.

## 1 — Make recorded work safe and outputs consistent

Implement assessment F01–F07 first, then F08–F10 and the smaller usability defects.

### Durable storage

- Stage multi-file saves/moves in unique temporary packages; validate required members; commit metadata only after success; retain a recovery journal until cleanup is complete.
- Replace models through revisions rather than delete-before-copy. Associate measurements with a geometry revision and preserve them for comparison/revalidation.
- Keep a last-good library index; preserve failed/corrupt metadata; allow recovery from individual scan manifests. Make old-library migration restartable and reversible.
- Introduce Recently Deleted for scans/projects and a complete project backup/restore format with a manifest and integrity checks. A model export is a separate product action.
- Propagate errors to meaningful UI actions: Retry, Save Elsewhere where possible, Keep Capture, or Discard. Never display Saved until the record and required files are durable.
- Report total package size, including source photos, textures, caches, and derivatives. Give users explicit source-retention/cache-cleanup controls.

### Capture and jobs

- Model capture as a state machine: Ready → Capturing ↔ Paused → Finalizing → Captured → Processing → Saved, with Failed/Recoverable states.
- Use session IDs/generation tokens for callbacks. Drain accepted photo/depth/texture work before finalizing; register poses only with successfully written images.
- Make a capture a durable entity even if no model or point cloud was produced. Reconstruction/export retries operate on this entity.
- Handle screen lock, tab changes, backgrounding, interruption, and thermal pressure. Stop or pause camera capture explicitly; checkpoint completed work. Resume via a verified session or a new registered subscan, not an assumed uninterrupted coordinate frame.
- Add cancellable processing with stage progress. Check free storage throughout a session and before large exports, including standard-photo mode.

### Consistent measurements and exports

- Use one coordinate-aware export service for every share route. Declare units, axes, source revision, and reference state; bake HQ corrections into normal model exports.
- Persist alignment method and residuals. Mark fallback scale/unknown scale clearly; require calibration before presenting an unverified imported model as metric.
- Validate imported geometry/material references and expose import failures. Ask for units when the file format does not establish them.
- Reject invalid/self-crossing measurement polygons. Keep plan area, surface area, horizontal distance, and slope distance explicit.
- Stream large exports on bounded background workers; support cancellation and unique output directories per share.
- Consolidate share-sheet presentation and test iPad; fix batch deletion, single-project duplication, live-overlay invalidation, and displayed version.

**Done when:** injected copy/write/index failures never destroy the prior valid scan; interrupted operations recover; rapid Stop/Reset/Start cannot mix sessions; failed reconstruction remains retryable; old data still opens; and a transformed fixture has matching dimensions/orientation in the viewer and all supported export routes.

## 2 — Build the outdoor capture foundation

### A terrain-specific workflow

Start with Terrain / Object / Room. For Terrain, offer a few presets such as Bare ground, Detailed surface, and General site. Put resolution, color, and advanced range controls behind a settings sheet. Explain estimated storage and the difference between point spacing and expected quality.

Before capture, check camera access, location access when requested, battery/thermal state, storage, and selected reference mode. Scanning in local coordinates must remain possible without a GPS fix.

During capture, show one primary instruction, coverage/track preview, tracking quality, and observed surface quality. Coverage should combine observed cells, viewing distance/angle, repeated observations, and depth confidence; it must not present unsupported numerical “accuracy percentages.” Show missing/weak areas before the user leaves the site.

Preserve timestamps, relevant sensor confidence summaries, path/subscan identity, capture settings, device/OS, and source coordinates. Store a durable unprocessed capture before optional cleanup. Raw depth/photo retention beyond that snapshot is a user-selectable storage tradeoff.

### Coordinate model

Use an explicit transform chain with its source revision:

`capture-local → project-local → georeferenced coordinates → export convention`

Every recenter, rotation, scale correction, and subscan registration must be invertible and stored. Display centering is separate from survey data. A display floor of zero must never silently become the site's elevation datum.

Support three clear reference states:

| State | Meaning | Allowed presentation |
| --- | --- | --- |
| Local | Relative coordinates in metres, explicit local origin/datum | Local distances, relative heights and volumes within validated limits |
| Approximate location | Timestamped phone location/heading with recorded uncertainty | Map placement labeled approximate; local and GPS quality shown separately |
| Controlled | Registered to supplied control with independent check points | Named CRS/vertical reference, transformation, residuals and validation report |

Use local floating-point coordinates for rendering and double precision for global coordinates/transform calculations. Choose a CRS explicitly for each project; do not infer one solely from language, time zone, or GPS. If the work is in Norway, evaluate the appropriate EUREF89/UTM zone and vertical reference with the actual project requirements before implementation.

**Done when:** a saved/reopened/exported scan retains its full coordinate chain; invalid/stale fixes are rejected; a local scan works without location permission; capture recovery is demonstrated; and coverage guidance is compared against known missed areas in a field test.

## 3 — Deliver a complete terrain workbench

Ship this in small vertical slices: first ground selection and a surface/profile, then contours and exports, then volumes and reporting.

### Ground and editing

- Keep the observed cloud immutable. Store crop boundaries, deleted/outlier points, ground labels, and processing settings as reversible edits.
- Add rectangular/polygon crop, lasso selection, section box, noise removal preview, and undo/redo.
- Separate ground from vegetation, structures, and equipment, with manual correction. Compare candidate classification methods on real bare ground, slopes, gravel, and vegetation; select a method from evidence rather than assuming indoor classifications work outdoors.
- Support breaklines for abrupt edges such as kerbs, ditches, and retaining walls. Explicitly mark holes/unobserved ground.

### Terrain surface

- Build a constrained triangulated terrain surface and/or elevation grid from accepted ground points.
- Bound interpolation by crop, maximum gap/edge length, and confidence. Preserve no-data areas. A triangle across an unobserved ditch is not a measured surface.
- Keep mesh/point-cloud views available for overhangs and vertical structures: one elevation per map cell cannot describe all 3D geometry.
- Display source cloud, ground points, surface, contours, slope, and measurements as layers with a common coordinate reference.

### Measurements and analysis

- User-selected contour interval with units, elevation labels, major/minor lines, and exportable polylines.
- Cross-sections and longitudinal profiles along editable paths; station, chainage, distance and elevation labels.
- Slope in degrees and percent; point elevations; horizontal/surface areas; named annotations.
- Cut/fill and stockpile volume against an explicitly selected reference plane or comparison surface. Show boundary, valid coverage, no-data exclusions, method, and uncertainty/sensitivity information.
- Surface comparison only after registration and overlap validation. Keep positive/negative change conventions visible.

### Deliverables

| Format | Intended role | Required metadata/validation |
| --- | --- | --- |
| CSV / XYZ | Points, profiles, measurements | Column names, units, coordinate reference and axis order |
| PLY / OBJ / STL | Existing generic 3D workflows | Consistent transforms; STL explicitly in mm; texture package validation |
| LAS, then LAZ if needed | Survey point clouds | Supported LAS version/point format, scale/offset, classification, RGB and CRS where established |
| DXF | Contours, breaklines and sections | Units, elevation, named layers; verify in an independent CAD reader |
| GeoTIFF | Georeferenced elevation/slope raster | CRS, vertical reference, cell size, transform, and no-data mask |
| Project archive | Backup and continued editing | Capture/derived data, transforms, measurements, settings and integrity manifest |
| PDF report | Human-readable survey record | Site/date, method, map/scale, profiles, measurements, quality/limitations and source revision |

Use LAS/CSV/DXF as the first terrain interoperability slice. Add LAZ/GeoTIFF after validating native library size, licensing, and memory cost. Large conversion can use an optional desktop companion; basic capture and project ownership must not depend on uploading to a service.

[QGIS documents LAS/LAZ support](https://docs.qgis.org/4.2/en/docs/user_manual/working_with_point_clouds/point_clouds.html). [PDAL's LAS writer documentation](https://pdal.io/en/2.9.1/stages/writers.las.html) identifies CRS, scale/offset, classification/point-format and compression choices that the export contract must handle. Verify against selected stable tool versions during implementation.

**Done when:** analytic ramps/planes produce expected contours/profiles; synthetic volumes match independent calculations; no-data remains no-data; exports reopen with matching units and coordinates in independent GIS/CAD tools; and at least one real site completes the entire workflow with a retained quality report.

## 4 — Scale to larger sites and repeated surveys

- Use bounded subscans, disk-backed chunks, spatial indexes, level-of-detail rendering, and spatial/GPU picking. Keep analysis data independent of render decimation.
- Register overlapping subscans with reviewable alignment, residuals and the ability to reject/undo a merge. Point-cloud accumulation needs provenance if later pose corrections are to move earlier observations consistently.
- Add control-point entry/import and target marking. Start with fixed metric scale/rigid registration where appropriate; allow scale correction only with evidence and show it explicitly.
- Require well-distributed, non-collinear control and additional independent check points. Report residuals, coverage, degeneracy, and any rejected control; do not treat a minimal exact fit as an accuracy certificate.
- Support dated site revisions and change maps with registration/uncertainty checks.
- Evaluate external GNSS/RTK or surveyed control only when required accuracy justifies it. Receiver access, timestamps, coordinate/vertical reference, antenna-to-camera offset, and independent validation are a separate integration project. RTK location alone does not correct all local LiDAR/SLAM errors.
- Set tested limits for site dimensions, session duration, point count, disk use, and memory. Reaching a limit should finalize a subscan gracefully.

**Done when:** multiple overlapping subscans survive interruption, align with independent checks, and produce repeatable exports; the oldest supported LiDAR device stays within measured memory/thermal budgets. Publish supported use cases based on these results.

## 5 — Upgrade detailed objects

- Add a subject/crop boundary, guided orbits at several heights, overlap and blur feedback, and a coverage review before processing.
- Evaluate Apple's Object Capture guidance against the existing custom capture path using the same objects. Keep a custom path where pose/depth export or supported-device coverage requires it.
- Preserve originals and per-photo calibration, show accepted/rejected photo counts, and retain processing revisions. Offer removable background/support geometry and a reliable scale-reference workflow.
- Improve texture seam/exposure handling with objective color/projection fixtures. Add texture resolution/atlas tradeoffs without implying finer geometry from sharper color.
- Offer quality-appropriate mesh reduction and hole repair as reversible operations; compare detail retention before/after.
- Provide a validated desktop reconstruction/Splat package and import the finished model as a new revision. Gaussian splats are a visual deliverable; derive geometric measurements from validated geometry.
- Consider GLB and portable USDZ export after the core formats pass transform/material round-trip tests.

Apple's [photogrammetry detail documentation](https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail) limits the iOS processing route to reduced detail. Higher-detail desktop processing should be explicit and independently verified.

**Done when:** a reference object with measured dimensions and fine visual detail reconstructs repeatably; bad coverage is detected before export; failure preserves photos; and desktop handoff is tested with a specified tool/version rather than assumed from a file name.

## 6 — Add a proper room/building workflow

- Evaluate [RoomPlan](https://developer.apple.com/augmented-reality/roomplan/) for structured walls, doors, windows, and dimensions. Retain mesh capture for irregular or unsupported spaces.
- Add editable floor plans, room labels, openings, ceiling heights, area reports, and practical DXF/PDF exports.
- Add [multi-room capture](https://developer.apple.com/documentation/roomplan/scanning-the-rooms-of-a-single-structure?language=objc) with reviewed joins rather than presenting independently centered scans as an aligned building.
- Support annotations and linked photos, consistent units, and a clear distinction between reconstructed surfaces and idealized walls.

**Done when:** a known room and connected-room example produce editable plans and exports with verified dimensions; unsupported conditions and uncertain geometry remain visible.

## Design changes throughout the releases

- Consolidate the main library into Projects with list/grid/search and, later, a map for scans with valid locations. Make New Scan available directly within the project.
- Separate Capture, Review/Edit, Measure/Analyze, and Export tasks. Use contextual tools instead of placing all algorithms on the camera screen.
- Create a daylight-friendly appearance, larger readable status text, accessible labels, semantic units/colors, and touch targets of at least 44 points. Verify Dynamic Type, VoiceOver, small-phone landscape, and iPad layouts.
- Keep the primary field controls prominent: Pause, Finish, tracking/coverage status. Put destructive reset/discard behind confirmation or recovery.
- Show real processing stages, cancellation and recovery. Use useful empty/error states with the next action.
- In exports, show a preview of destination format, units, axes/reference, texture inclusion, and estimated size. Include quality metadata when it affects interpretation.
- Make offline capability, storage retention, location inclusion, backup, and deletion understandable in Settings. Redact sensitive location/paths from shared diagnostics by default.

## Architecture supporting the plan

Refactor along work already being changed, with tests around existing behavior:

| Boundary | Responsibility |
| --- | --- |
| Capture coordinator | State machine, AR session lifecycle, permissions and session identity |
| Capture writer | Serialized durable observations/photos/poses and finalization barriers |
| Project repository | Versioned manifests, migrations, transactions, revisions, recovery and trash |
| Geometry/measurement core | Testable transforms, fitting, mesh/point operations and measurements without UI dependencies |
| Terrain processor | Ground classification, surfaces, contours, profiles and volume analysis |
| Processing jobs | Progress, cancellation, checkpoints, retry, resource budgets |
| Export/import service | One contract for format, units, axes, reference, material packaging and validation |
| Viewer adapter | Rendering, camera, layers and picking independent of persistent model representation |

Use `@MainActor` for UI-facing state and explicit serialized ownership for mutable capture/storage state. Preserve the existing coordinate and texture conventions in tested adapters.

Start with versioned on-disk packages and a recoverable index; do not make a database migration a prerequisite for reliability fixes. Evaluate a database if measured library size/query needs justify it. Store thumbnails separately from the core index as the library grows.

Treat `.scn` as a regenerable viewer cache, not the only record of geometry or appearance. Prototype RealityKit/Metal behind the adapter because [SceneKit is deprecated](https://developer.apple.com/documentation/scenekit/). Switch only after an explicit parity/performance check for imports, textured meshes, points, picking, measurement overlays and snapshots.

## Verification and release gates

| Test group | Required evidence |
| --- | --- |
| Data safety | Disk-full/permission/copy/index failures; crash at each transaction boundary; duplicate/move/delete/restore; old/corrupt metadata; repeated reconstruction |
| Capture | Fast Stop/Reset/Start; pending photo writes; interruptions; denied permissions; stale GPS; low disk; thermal pressure; failed processing retry |
| Coordinates | Axis-colored fixture, UV checker, non-identity HQ transform, local/project/CRS round trips, retained elevation datum |
| Geometry | Degenerate planes, non-collinear controls, outliers, crossing polygons, negative elevations, sloped area vs plan area, analytic terrain/volume cases |
| Interoperability | Independent readers for supported OBJ/PLY/USDZ/STL and terrain formats; compare counts, bounds, units, textures, classifications and CRS |
| Field accuracy | Repeated captures of independently measured distances, slopes and surfaces, including a closed walked loop and difficult lighting/ground; report local and absolute errors separately |
| Performance | Fixed workloads up to the supported point budget; cold/warm loading, picking latency, save/export peak memory, repeated open/close, long-session heat and battery |
| UX/accessibility | Sunlight, gloves where relevant, one-handed capture, large text, VoiceOver, iPhone/iPad rotation, recoverable errors |

Provisional engineering targets: interactive viewing at least 30 fps on the chosen reference workload; p95 picking response under 100 ms; no sustained main-thread I/O stalls; no loss of acknowledged saved data in the fault suite. Benchmark first and revise workload limits explicitly if the oldest supported hardware cannot meet them.

Field accuracy thresholds must come from the owner's use case and reference measurements. Use analytic fixtures to verify numerical correctness, then independent check points to establish real-world error. Do not substitute a dense-looking mesh or a small fitting residual for that evidence.

Each milestone gets a small TestFlight release, a changelog naming what changed, and a focused device checklist. A release is complete only when its automated checks and required field/device checks pass. Retain the preceding good build and a compatible data recovery path.

## First implementation branches

Progress as of 25 September 2026: storage-integrity and capture-recovery slices
are implemented; the coordinate-export-consistency slice is now implemented for
review/validation. See their `ScanView3D/*INTEGRITY.md`, `CAPTURE_RECOVERY.md` and
`COORDINATE_EXPORTS.md` notes for exact scope and remaining release gates. This does
not mark entire milestones complete: device/field checks, calibration/import
repair, backup/trash and the terrain workflow remain outstanding. Publishing is held.

Suggested order, each based on the latest integrated result:

1. `codex/validation-baseline` — test target/schemes, fixtures, validation workflow, current failure cases.
2. `codex/storage-integrity` — safe moves/replacements, durable metadata, explicit errors and recovery.
3. `codex/capture-finalization` — session isolation, write barriers, durable captures and retryable jobs.
4. `codex/coordinate-export-consistency` — HQ export correction, coordinate provenance, validated locations and scale status.
5. `codex/field-workflow` — outdoor-oriented capture/review UI, coverage guidance and lifecycle behavior.
6. `codex/terrain-surface-profiles` — reversible ground selection, terrain surface, first profile and CSV export.
7. Subsequent focused branches for contours/LAS/DXF, volumes, controlled registration, objects, and rooms.

## Explicitly deferred until evidence warrants them

- Custom TSDF/depth-fusion engine: benchmark the existing capture first; require a measured quality improvement before investing in a new reconstruction engine.
- Cloud processing/accounts/subscriptions: optional later capability with clear cost and data ownership; not a dependency of the field workflow.
- Unbounded global terrain reconstruction or automatic survey-grade accuracy claims: require demonstrated hardware/reference support and independent validation.
- Full renderer rewrite, simultaneous format explosion, or a bulk UI rewrite before storage integrity and fixture coverage exist.

The first meaningful product milestone is a reliable, traceable terrain scan that can be edited, measured, and reopened in another tool. Build outward from that complete workflow.
