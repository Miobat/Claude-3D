# ScanView 3D — project assessment

Assessed 24 September 2026. Baseline: `a31504b16c772959445e789b4638bd49efc46d3e` on `claude/iphone-scanning-app-WHgvb`.

Product priorities supplied by the owner: **outdoor terrain and surveying first, detailed objects second, rooms/buildings third**. The implementation roadmap is in [UPGRADE_PLAN.md](UPGRADE_PLAN.md).

## Verdict

This is a substantial working foundation, with more functionality than the small codebase initially suggests. It is ready for a focused reliability and terrain upgrade, but I would not yet treat its outputs as a validated surveying workflow. The largest gaps concern data preservation, coordinate provenance, measurement validation, and handling large scans. Visual polish matters too, particularly outdoors.

The best approach is to retain the useful capture and geometry work, establish regression fixtures, and improve it in small releases. A wholesale rewrite would put the existing camera projection, texture orientation, and alignment fixes at risk.

“Perfect” needs an operational definition: recorded data survives failures; measurements have a known reference and tested error bounds; exports agree with the viewer; the main tasks remain usable on supported devices; and each release passes repeatable checks. This review cannot establish the absence of all bugs.

## What was checked

- Handover and setup documents; the native app's capture, texture, processing, storage, geometry, measurement, navigation, viewer, import/export, and build paths.
- 26 Swift source files, approximately 10,766 lines. All 26 have the expected build-file/source-phase references in the Xcode project. This was a static registration check, not an Xcode project validation.
- One application target; no tracked unit/UI test suite or separate validation workflow found. The simulator mock exists, but the project declares `SUPPORTED_PLATFORMS = iphoneos`.
- The exact baseline passed [GitHub Actions run 59](https://github.com/Miobat/Claude-3D/actions/runs/36055954531), completed on 24 September at 20:39 UTC. This establishes a successful build-and-upload workflow, not field accuracy or completion of Apple's subsequent processing.
- Current Apple documentation for SceneKit, photogrammetry limits, heading alignment, location validity, and privacy API declarations; QGIS/PDAL documentation for proposed terrain interoperability.

This was a source assessment on Windows. I did not run the native UI, perform a new Xcode build, measure frame rates, or scan a reference object. Findings below distinguish definite code paths from risks requiring device reproduction. No app code was changed and no build was triggered for this assessment.

## Useful foundations to preserve

| Area | Already implemented |
| --- | --- |
| Capture | Four modes: Fast mesh, High Quality photogrammetry, Point Cloud, Splat desktop export; range filtering along the walked path; pause/continue; tracking advice |
| Image quality | Movement-based keyframes, blur rejection, depth occlusion checks, exposure normalization, white-balance control, photo-patch texture baking |
| Geometry | Welding, component filtering, Taubin smoothing, voxel reduction, spatial queries, fitted planes, camera-pose similarity alignment |
| Measurements | Distance, vertical height, wall gap, path, area, relative elevation; snapping; persisted measurements and CSV |
| Viewer | Orbit/pan/zoom/focus, orthographic and top views, height shading, wireframe, scale-bar snapshots |
| Files | Projects, search, thumbnails, OBJ/PLY, textured OBJ packages, STL in millimetres, Z-up CAD export, retained HQ photos, repeat reconstruction |
| Operations | Working TestFlight pipeline, public build diagnostics, useful handover, backward-compatible optional scan metadata |

The height shader draws contour-like lines; it does not create exportable terrain contours. Splat mode produces training inputs; it does not train or display a Gaussian splat in the app.

## Bugs and failure paths to fix first

Priority: **P1** threatens saved data or trustworthy output; **P2** affects functionality, compatibility, or usability. “Confirmed in code” means the path is identifiable; the failure conditions have not been injected into the iOS app during this review.

### F01 — P1: Moving a scan can delete its only good copy

**Confirmed in code.** `moveScan` attempts a move, then a fallback copy, then removes the source even if the copy failed. It subsequently changes the project records without verifying the complete file set. Insufficient storage or another filesystem error can leave missing models, textures, or photos.

[StorageManager.swift:495](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/StorageManager.swift#L495)

Fix: stage and verify the full destination package, durably commit its metadata, then remove the source. On any failure retain the original and report a recoverable error. Test failure at every file operation, including metadata persistence.

### F02 — P1: Re-reconstruction removes the working model before its replacement is safe

**Confirmed in code.** `replacePhotogrammetryModel` deletes the existing file before copying the new one. A failed copy loses the original. Successful re-reconstruction also clears all saved measurements without a separate preservation step.

[StorageManager.swift:347](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/StorageManager.swift#L347), [ModelViewerView.swift:583](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Views/Viewer/ModelViewerView.swift#L583)

Fix: produce a new revision, validate it, and switch the active revision atomically. Keep the old model and its measurements; mark measurements requiring revalidation instead of silently deleting them.

### F03 — P1: Persistence failures can look like successful saves or an empty library

**Confirmed in code.** If `projects.json` cannot decode, `loadProjects` replaces the in-memory library with an empty array. A subsequent project creation/save can overwrite the original index. `saveProjects` logs write errors without informing callers; measurement reads/writes similarly collapse errors into empty data or apparent success. Scan files can exist while their registration has not been saved.

[StorageManager.swift:64](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/StorageManager.swift#L64), [StorageManager.swift:285](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/StorageManager.swift#L285)

Fix: distinguish an empty library from a failed load; preserve corrupt files; maintain a last-good index and per-scan manifests; propagate save failures to the UI; recover orphaned packages. Atomic JSON writes already help, but do not make a multi-file save transactional.

### F04 — P1: Ordinary HQ sharing loses the app's scale and alignment correction

**Confirmed in code.** The viewer applies `Scan.modelMatrix`. Standard share/project export copies the original USDZ unchanged, with no transform metadata. For a scan with a non-identity model transform, the exported model can have a different size, position, or orientation from what was measured in the app. Dedicated CAD exports apply the transform, so export routes behave inconsistently.

[SceneKitView.swift:227](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Views/Viewer/SceneKitView.swift#L227), [StorageManager.swift:594](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/StorageManager.swift#L594), [StorageManager.swift:730](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/StorageManager.swift#L730)

Fix: one export pipeline with explicit units/axes/reference, baking the correction into portable model exports. Test a known rotated/scaled model across viewer, ordinary share, CAD export, and reimport.

### F05 — P1: Capture cleanup can discard recoverable source data

**Confirmed in code.** Splat packaging resets the scanner and deletes the capture folder even when ZIP creation fails. A photo-only Splat capture can be shared without a persistent library record because the record depends on a point cloud. For HQ saves, photo-copy failure is ignored; the save finishes and reset can remove the only source photos.

[ScannerView.swift:771](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Views/Scanner/ScannerView.swift#L771), [StorageManager.swift:250](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/StorageManager.swift#L250), [LiDARScanner.swift:253](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/LiDARScanner.swift#L253)

Fix: persist the capture independently of its derived mesh; show failed processing as a retryable job; clean up only after a verified commit or explicit discard.

### F06 — P1: Stopping/resetting does not synchronize in-flight capture work

**Concurrency risk established in code; timing needs device/fault-injection testing.** Photos and poses are counted before JPEG finalization, whose success is ignored. Stop writes poses without draining photo writes. Depth/texture work can finish after reset; no session-generation token rejects old results. A delayed high-resolution callback checks only `isScanning`, which may already describe a new scan.

[LiDARScanner.swift:224](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/LiDARScanner.swift#L224), [LiDARScanner.swift:448](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/LiDARScanner.swift#L448), [LiDARScanner.swift:459](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/LiDARScanner.swift#L459), [LiDARScanner.swift:918](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/LiDARScanner.swift#L918), [TextureMapper.swift:90](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/TextureMapper.swift#L90)

Fix: give each session a unique generation, stop accepting input, await committed writes/integrations, then freeze the capture manifest. Reject late callbacks from earlier generations and count only durable photos.

### F07 — P1 for terrain: A new scan can inherit an old or invalid GPS fix

**Confirmed in code.** `requestFix` does not clear the previous location. Failure/denial leaves it in place; `finishSave` uses that value. Choosing the smallest `horizontalAccuracy` also accepts negative values and does not check age. Apple explicitly defines negative horizontal accuracy as an invalid location. Altitude validity and timestamp are not retained with the scan.

[LocationProvider.swift:16](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/LocationProvider.swift#L16), [ScannerView.swift:686](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Views/Scanner/ScannerView.swift#L686), [Apple location validity](https://developer.apple.com/documentation/corelocation/cllocation/horizontalaccuracy?changes=_1)

Fix: scope fixes to a session, validate age and horizontal/vertical accuracy, store timestamps and quality, and display unavailable/approximate states. Do not attach a previous scan's location to a new scan.

### F08 — P2: Imported models are incompletely characterized and packaged

**Confirmed limitations in code.** Import registers zero vertices/faces without examining geometry. `hasMesh` then hides CAD export for imported OBJ triangle meshes. Material discovery assumes the app's own `<base>.mtl` and `<base>_texture.*` names instead of following arbitrary OBJ material references. Import errors are logged but not shown to the user.

[StorageManager.swift:665](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/StorageManager.swift#L665), [ModelViewerView.swift:206](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Views/Viewer/ModelViewerView.swift#L206), [ProjectDetailView.swift:227](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Views/Projects/ProjectDetailView.swift#L227)

Fix: validate/inspect imports, ask for unknown units, compute bounds/counts/thumbnails, read referenced materials, and support an explicit package/folder import with appropriate access. Validate PLY variants with fixtures before advertising broad compatibility.

### F09 — P2: Batch deletion indexes a changing scan list

**Conditional bug confirmed in code.** `ProjectDetailView.onDelete` recomputes `sortedScans[index]` after every removal. With multiple offsets it can delete the wrong scan or access beyond the shortened array. Current single-row swipe deletion may not expose this.

[ProjectDetailView.swift:215](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Views/Projects/ProjectDetailView.swift#L215)

Fix: snapshot selected scan IDs before mutation. Move deletion to recoverable trash and test nonadjacent selections.

### F10 — P2: Live overlay geometry can stay stale

**Confirmed invalidation gap.** Overlay rebuilds use vertex count as their geometry version. ARKit can refine positions/topology without changing that count; the overlay then keeps the old geometry.

[ARScannerView.swift:92](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Views/Scanner/ARScannerView.swift#L92)

Fix: track anchor update revisions or dirty IDs while retaining the rebuild budget. Verify equal-count geometry updates in a fixture and on device.

## Terrain-specific gaps

1. **No recoverable world-to-map transform for ordinary mesh/point scans.** Saving recenters X/Z and subtracts a floor/low-point height, then stores only the transformed geometry. The transform is not retained for these modes. A GPS tag and compass heading cannot restore the lost offset. Preserve raw session coordinates and every subsequent transform before adding mapped exports. See [ScannerView.swift:750](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Views/Scanner/ScannerView.swift#L750) and [MeasurementEngine.swift:492](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Services/MeasurementEngine.swift#L492). Apple's [heading alignment](https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment-swift.enum/gravityandheading?language=objc) still has a device-relative origin.
2. **No ground model.** There is no ground/vegetation classification, terrain triangulation, breakline support, hole mask, or edited ground-point layer. Indoor ARKit surface classifications do not supply this workflow.
3. **No terrain analysis outputs.** Missing exportable contours, elevation grid, slope map, profiles, cut/fill volumes, and comparisons between surveys. Existing area/elevation tools are useful foundations, not substitutes.
4. **No control-point registration or accuracy report.** There is no coordinate reference system (CRS), vertical datum, independent check-point residual, heading quality, or drift report. Phone GPS accuracy and local dimensional accuracy must be reported separately.
5. **No durable raw survey or reversible processing history.** Saved Fast geometry has already been cleaned/smoothed and recentered. Display cleanup can remove useful detail; “High Quality” cleanup means stronger smoothing, not verified higher measurement accuracy.
6. **No large-site strategy.** Capture is one session with an in-memory point budget up to four million cells. Depth fusion averages positions but does not retain the full observations needed for later trajectory correction. Larger sites require bounded subscans, recovery, registration, and tested coverage limits.

The 5–20 mm Detail setting controls sampling/reduction. It is not an accuracy specification. Likewise, the handover's proposed 5–10 mm TSDF result is an unvalidated hypothesis, not a result this code establishes.

## Performance, lifecycle, and measurement risks

- Point-cloud picking projects hundreds of thousands of points on the main thread per query. Live measurement preview can run every 80 ms while the camera changes. This is a clear scaling hotspot; actual frame rates are unmeasured. [SceneKitView.swift:394](https://github.com/Miobat/Claude-3D/blob/a31504b/ScanView3D/ScanView3D/Views/Viewer/SceneKitView.swift#L394)
- STL, PLY, and parts of OBJ conversion assemble large buffers; several export/import actions call synchronous storage work directly from UI actions. Peak memory and UI stalls need device measurements, then streaming and cancellable background jobs.
- The scanner's disappear handler calls `stopPreview`, which explicitly does nothing during an active scan. Background/session interruption states are handled incompletely, with no durable recovery journal. Define tab-switch, screen-lock, phone-call, and relocalization behavior rather than relying on view lifetime.
- The AR overlay's repeating display link is invalidated only in `deinit`, with no explicit representable teardown. Audit retention and session shutdown using Instruments; also profile repeated viewer open/close cycles.
- HQ pose alignment has useful rejection checks, but its fallback uses a bounding-box size ratio and does not establish orientation. Alignment confidence/method is not persisted. A fallback or unscaled import should not look indistinguishable from a validated metric model.
- Area accepts arbitrary point sequences and calculates a signed projected polygon area without rejecting self-intersections. A crossing outline can produce a misleading area. Add polygon validity checks, explicit plan/surface area, and degeneracy handling.
- Project export omits measurements, provenance, and retained capture data and suppresses individual model-copy failures. It should be clearly separated from a complete backup with a restore check.

## Design assessment from the view code

The current interface exposes capture algorithms before asking what the user wants to do. For your priorities, **Terrain / Object / Room** is a clearer starting point; advanced users can still select the underlying capture method.

Specific weaknesses to address:

- Pre-scan controls form a dense, non-scrolling vertical stack; some status text is 9 pt and mode labels 11 pt. Check small phones, landscape, and larger accessibility text.
- The app forces dark appearance; gray labels and translucent controls need outdoor contrast testing. Add a sunlight-friendly appearance and semantic contrast tokens.
- Projects and All Scans overlap, while project detail sends users back to the scanner tab instead of starting a scan in that project. Put a contextual New Scan action in the project.
- Reset immediately discards a capture; scan/project deletion is permanent with no trash. Make destructive actions deliberate and recoverable.
- Processing offers limited progress information and no exposed cancellation/recovery workflow. A successful save should be a durable state, not merely a dismissed sheet.
- Some project share paths present `UIActivityViewController` without the popover anchoring used by the newer helper. Consolidate them and test iPad presentation.
- Duplicate is unnecessarily hidden when only one project exists; Settings displays version 1.0.0 while the Xcode project says 1.1.0; project sizes omit companion files; several icon controls lack explicit accessibility labels.

These are code-based design findings. Touch comfort, visual hierarchy, actual contrast, and camera interaction still need review on a real device.

## Architecture and release readiness

The largest files combine several responsibilities: capture, image persistence, geometry extraction, job orchestration, UI state, storage, and exports. Introduce boundaries as those areas are changed; preserve the working algorithms behind regression tests.

Add a testable geometry/data layer, serialized storage/capture operations, and main-actor UI state. Keep large assets outside the library index. Introduce versioned manifests before adding more optional fields without a migration strategy.

The single workflow combines compilation, signing, and upload. Add unsigned validation and tests on pull requests before changing publishing behavior. Retain an explicit, predictable TestFlight route; an Actions success currently does not validate measurement math or storage recovery.

No app privacy manifest is tracked, despite `UserDefaults` and disk-space API use. Audit the archive and add truthful declarations matching actual use; Apple documents [required-reason API categories](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype). This is a release-readiness gap, not a claim that today's successful upload failed.

Apple has [deprecated SceneKit](https://developer.apple.com/documentation/scenekit/). Place rendering behind a small interface and evaluate RealityKit/Metal for the large point-cloud workload. Do not make replacing the viewer a prerequisite for fixing storage or delivering terrain tools; first prove import, picking, measurements, and export parity.

Apple also documents that [iOS photogrammetry supports reduced detail](https://developer.apple.com/documentation/realitykit/photogrammetrysession/request/detail). Higher-detail object reconstruction should therefore have a tested desktop path, not a misleading in-app quality switch.

## Recommended first delivery

A reliability release covering F01–F07, truthful transform/accuracy metadata, and regression fixtures. Then deliver a complete small-site terrain workflow: capture → review coverage → edit ground → create a surface → measure/profile → export. The plan specifies dependencies and release gates so improvements can be reviewed and tested incrementally.
