# ScanView 3D — Developer Handover

Native iOS LiDAR scanning app (SwiftUI + ARKit + SceneKit + RealityKit), in
`ScanView3D/`. Requires an iPhone/iPad Pro with LiDAR, iOS 17+.
(The `src/`, `index.html`, `vite.config.js` files at the repo root are an old
web prototype and are not part of the app.)

---

## 1. How building & publishing works (read first)

- **You cannot build locally here.** The owner's Mac can't run a current Xcode, and
  cloud agents don't have Xcode. Every build happens on **GitHub Actions**
  (`.github/workflows/testflight.yml`, macOS runner, Xcode 26+).
- **Pushing publishes.** A push that changes `ScanView3D/**` or
  `.github/workflows/**` on `main`, `master`, `claude/**` or `codex/**` builds,
  signs and uploads the app to **TestFlight** automatically (fastlane lane
  `beta_manual`). Build numbers are timestamps, so every build uploads.
- A newer push to the same branch cancels an in-progress build.
- Manual run: GitHub → Actions → "Build & Deploy to TestFlight" → Run workflow.
- **Signing secrets live in GitHub Secrets** — never needed in code, never commit them.
- **If a build fails**, the run's summary page shows the actual compiler/fastlane
  error lines as annotations ("Report build errors" step). Readable via API:
  `GET /repos/Miobat/Claude-3D/check-runs/{job_id}/annotations`.
- "A required agreement is missing or has expired" = the Apple account holder must
  accept an agreement in App Store Connect (Business) / developer.apple.com. Not code.
- TestFlight builds expire after 90 days — push any change to rebuild.
- `MARKETING_VERSION` is in `ScanView3D/ScanView3D.xcodeproj/project.pbxproj`.

### Adding / removing Swift files
The Xcode project is edited by hand. A new file needs **4 entries** in
`project.pbxproj`: a `PBXBuildFile` (`A100xx`), a `PBXFileReference` (`B100xx`),
a child entry in the right `PBXGroup` (Models / Services / Viewer / Scanner …),
and a line in the Sources build phase. Copy an existing file's lines (e.g.
`OrbitCameraController.swift`, `A10028`/`B10028`) and use the next free number
(currently `A10030`/`B10030`). Deleting a file = remove those 4 lines too.

### Checking your work without Xcode
- A tree-sitter Swift parser (`pip install tree-sitter tree-sitter-swift`) catches
  syntax / brace errors. Known false positive: `#if targetEnvironment(simulator)`
  around stored properties at the top of `ScannerView.swift`.
- Then have the change type-reviewed (another agent/person) — CI is the real compiler.
- The simulator build uses `MockLiDARScanner` in place of `LiDARScanner`; any API
  `ScannerView` calls must exist on both.

---

## 2. Code map

| Area | File | What it does |
|---|---|---|
| Models | `Models/Project.swift` | `Project`, `Scan` (+ optional metadata: `modelTransform`, `sceneFrame`, GPS, splat/photo folders), `ScanSettings` (persisted, tolerant decoding), `MeasurementUnit` formatting |
| | `Models/Measurement.swift` | `ScanMeasurement` (distance, height, wall↔wall, path, area, elevation), values, labels, CSV |
| Capture | `Services/LiDARScanner.swift` | ARKit session, anchors, range filter (walked path, `PathRangeIndex`), keyframes, HQ/Splat photos (+12 MP), white-balance lock, memory guard, `DepthPointAccumulator` (LiDAR point cloud), `PoseFile`, `MeshData` |
| | `Services/MockLiDARScanner.swift` | Simulator stand-in (same API) |
| | `Services/TextureMapper.swift` | Colour keyframes on disk (+ depth for occlusion), vertex colours, **photo-patch texture baking** |
| Processing | `Services/MeshProcessor.swift` | Clean-up (weld, Taubin smoothing, clustering), SceneKit node builders, `PhotogrammetryProcessor` (on-device, `.poses`), `SplatExporter` |
| | `Services/MeasurementEngine.swift` | `GeometryMath` (plane fit, RANSAC, intersections, Horn similarity), `ModelGeometryIndex` (spatial index, wall axes), `SceneFrame` (level/square-up) |
| Storage | `Services/StorageManager.swift` | Projects JSON, scan files, companions, export/share (zips textured OBJ), CAD exports (OBJ Z-up, STL mm), measurements files |
| | `Services/OBJExporter.swift` | OBJ/PLY writers (streamed) |
| | `Services/LocationProvider.swift` | One-shot GPS for north-aligned scans |
| Scanner UI | `Views/Scanner/ScannerView.swift` | Pre-scan options, scanning HUD, save flows per mode, HQ alignment glue |
| | `Views/Scanner/ARScannerView.swift` | ARView, live mesh overlay (throttled), coaching overlay |
| Viewer | `Views/Viewer/ModelViewerView.swift` | Viewer UI, measure panel, menus, height legend, share helpers |
| | `Views/Viewer/SceneKitView.swift` | SceneKit view + Coordinator: loading, grid, view modes (incl. height shader), snapping, geometry queries |
| | `Views/Viewer/OrbitCameraController.swift` | Touch navigation (orbit / pan / pinch / double-tap focus) |
| | `Views/Viewer/MeasurementOverlay.swift` | `MeasurementSession` (tool logic), SpriteKit overlay drawing, snap types |

---

## 3. Conventions that are easy to get wrong

1. **ARKit camera space is +X right, +Y UP, looking down −Z.** Image pixels have
   +y DOWN. When projecting with `camera.intrinsics`, negate Y (and use −Z as depth):
   `u = fx·x/d + cx`, `v = fy·(−y)/d + cy`, `d = −z`. See `FramePose.project`.
   Unprojecting depth pixels does the reverse (`DepthPointAccumulator.points`).
   Getting this wrong mirrors colours vertically.
2. **Texture coordinates:** baked UVs are stored in **OBJ convention (origin
   bottom-left)**. SceneKit's origin is **top-left**, so `createTexturedNode` flips V.
   Don't "fix" one side without the other.
3. **ARKit mesh classification is per FACE**, not per vertex
   (`ARMeshGeometry.classification`).
4. **Intrinsics must match the saved image size** (12 MP photos rescale them).
5. **World units are metres, Y up = gravity.** New scans are saved in a tidy frame
   (`SceneFrame`): floor at y = 0, walls on X/Z, centred — unless north-aligned
   (then −Z = north). Baking must happen **before** that transform (it needs the
   camera-space positions).
6. **High-Quality models** (`.usdz`) are not in metres by themselves. Their
   placement comes from `Scan.modelTransform` (Horn alignment of photogrammetry
   camera poses to ARKit poses, then `sceneFrame`). Old scans may only have
   `modelScale`. Always use `Scan.modelMatrix` when showing/measuring/exporting.
7. **The photogrammetry input folder must contain only images.** ARKit poses go in
   a sibling file `<folder>_poses.json` (`PoseFile`).
8. **`StorageManager.projects` drives SwiftUI — mutate it only on the main thread**
   (use `onMain` / `addScan` / `updateScan`).
9. **Don't hold ARKit frame buffers**: capture work is one-in-flight on background
   queues; never store `ARFrame`s.
10. New `Codable` fields on `Scan` must be **optional**; new `ScanSettings` fields
    need a line in its tolerant `init(from:)` — otherwise saved data stops loading.

## 4. Where a scan's files live
`Documents/Scans/<projectId>/`: `<id>.obj|ply|usdz` (model), `<id>.scn` (fast in-app
viewer copy), `<id>.mtl`, `<id>_texture.jpg`, `<id>_measurements.json`,
`<id>_bundle.zip` (splat), `<id>_photos/` + `<id>_photos_poses.json` (HQ photos).
`StorageManager.companionFiles(of:)` lists them; delete/move/duplicate use it —
add any new per-scan file there.

## 5. Known limitations / ideas not done yet
- Apple caps on-device photogrammetry at `.reduced` detail on iOS.
- Fast-mode geometry is ARKit's mesh (~cm). A custom TSDF depth-fusion engine
  would give 5–10 mm meshes (big job).
- Land-survey exports (contours, LAS, terrain grid) not implemented.
- Scans saved before the UV fix show scrambled textures in-app (data is stored wrong).
- Snapping thresholds, camera speeds and texture keyframe spacing are first
  guesses — tune from device testing.

## 6. Working rules for the owner's repo
- Develop on your own branch (`codex/...` or `claude/...`); one tool edits a file at
  a time to avoid conflicts; merge branch by branch.
- Keep commit messages descriptive (what + why).
- Don't commit secrets, `.env` files or signing material.
