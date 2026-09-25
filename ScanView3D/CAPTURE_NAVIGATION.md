# Live capture and navigation upgrade

Branch: `codex/live-capture-navigation`, based on the published design branch,
not the stale `main`. Pushes validate; a manual TestFlight run is still required.

## Behaviour

- Capture distance is radial distance from the phone **at observation time**.
  It is not optical-axis depth, distance from the start, or proximity to a route.
- Fast / Room Shell use capture-time depth evidence to filter ARKit vertices,
  face centres and edge midpoints. Full detected-plane extents no longer bypass
  the range. Post-processing retains captured positions at the boundary.
- Points / Splat accept confidence-filtered LiDAR samples inside the sphere;
  downsampling preserves a real accepted position, averaging colour only.
- Persistent, bounded world-space surface evidence drives the mint coverage.
  Previously observed surfaces can remain covered through confidence fluctuations
  if current depth agrees. Unknown depth is not new coverage. Tracking loss hides
  coverage. A new session clears it; it never leaks from a previous scan.
- Display uses a Metal camera post-process rather than frequently replacing
  translucent mesh entities. Committed depth reprojects into the current camera
  with a depth-occlusion check. A stronger mint fill and world-space grid are
  independent of scene lighting. Out-of-range depth is blurred/desaturated.
  These effects are never baked into saved camera photos or texture atlases.
- HQ uses per-photo LiDAR range masks, including re-reconstruction after recovery.
  Unknown depth / background pixels are excluded and the mask is eroded by one
  sensor pixel. A still without matching depth falls back to the matching normal
  photo, never a mask from another camera pose. Original photos are retained.
- Splat bundles include full-size binary `masks/*.png` and `mask_path` per image.
  External training software MUST honor the masks; arbitrary desktop importers
  cannot be guaranteed to enforce them. Masking constrains observations, not the
  accuracy of a reconstructed surface or every learned Gaussian's position.

## Viewer

- Left joystick: half the prior speed. Right joystick: twice the prior speed.
  Rates are time-based, independent of 60/120 Hz display refresh.
- Spring-centred vertical slider between the sticks, with a 44 pt touch area.
  Release stops; two-finger pan remains available in orbit mode.
- Each one-finger orbit picks the real surface at initial touch-down. Rebase
  preserves camera position/orientation, including off-centre, near and far hits.
  Dragging empty space does not invent a pivot in midair. Double-tap focus remains.
- Point-cloud picks use a full-resolution spatial hierarchy, nearest screen
  position, and depth only for same-pixel ties. No arbitrary point subsampling or
  24 pt foreground-first selection. Synthetic snapping is disabled on clouds so
  measurements remain on actual captured samples.
- Walk: select mode, tap scanned ground, then use the joysticks. Eye height is
  1.8 m; movement follows locally supported ground, with a 25 cm step limit and
  slope/obstacle/clearance checks. Missing ground stops movement. Vertical slider
  and pan cannot violate the height lock. Exit or camera presets return to orbit.
  Unknown-scale models cannot enter walk; estimated scale retains its warning.
- Gesture cancellation, backgrounding and view teardown stop navigation inputs
  and timers. No navigation timer should keep moving a dismissed viewer.

## Persistence / implementation

- Existing photo sidecar now accepts both legacy bare arrays and version-2
  envelopes. New captures mark `requiresRangeMasks` before their first photo.
  Missing/corrupt masks fail closed rather than silently making an unmasked model.
- Masks live in that same sidecar, so existing companion copy/move/delete/recovery
  logic remains applicable. Bounded run-length encoding limits repeated disk I/O.
- Shared range, mask, surface-index, point-pick and orbit/walk helpers are in
  StorageCore, compiled by the app and regression-tested independently.
- New Xcode entries: A/B10039–10043. Metal source is compiled for device and
  simulator; AR capture Swift remains device-only.

## Validation and phone acceptance checklist

CI runs StorageCore regression tests, independent OpenUSD export checks, unsigned
device + simulator builds, native SceneKit pick/ground/mask-recovery checks and
portrait/landscape screenshots. A simulator cannot validate real LiDAR tracking,
depth alignment, capture performance, battery/thermal behaviour or HQ results.

First physical test target: iPhone 16 Pro; capability checks, not phone-name checks,
select supported LiDAR / scene-depth / photogrammetry functions on other devices.

1. Set 1.0 m before scanning. Place a textured object about 0.7 m away, with a
   wall 1.5–2 m behind it. Background blurs; object remains clear. Repeat at frame
   edges (radial distance must not turn into optical-Z distance).
2. Capture slowly, move away, then return. Mint stays registered to the actual
   surfaces, with no old-anchor flashing. Wave a nearer object in front: coverage
   must not paint through it. Pause/resume, rotate portrait/landscape, hide/show
   coverage and test dim/reflective areas. Unknown depth must not imply capture.
3. Repeat Fast, HQ, Points and Splat. Inspect saved geometry / masks, recover an
   unfinished HQ scan, duplicate/move it and re-reconstruct. Never delete a failed
   original capture to test this. A trainer ignoring Splat masks is not compliant.
4. Measure a sharp edge in Points at close/far zoom; compare tapped point to marker.
   Mesh measurement/snapping should remain unchanged.
5. Orbit several off-centre near/far surface points. Initial touch must not jump
   the view. Try empty space; use double-tap, pinch and two-finger pan afterward.
6. Compare joystick speeds, test elevation slider, release/cancel gestures, open
   a menu, background/foreground the app. Camera must never keep moving on release.
7. Walk on a scanned flat floor, gentle slope and small step; approach an edge,
   wall and low ceiling. Height stays at 1.8 m above ground, and unsupported routes
   stop. This is a model viewer, not a physical navigation/safety system.
8. Scan for several minutes on iPhone 16 Pro and an older LiDAR device. Observe
   overlay alignment, frame rate, heat and memory. Coverage/range accuracy is
   limited by LiDAR resolution, surface reflectivity and AR tracking—not survey
   accuracy. Tune only from actual device evidence, not simulated screenshots.
