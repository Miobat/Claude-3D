# Storage integrity — first implementation slice

Branch: `codex/storage-integrity`, based on `claude/iphone-scanning-app-WHgvb`
at `a31504b16c772959445e789b4638bd49efc46d3e`.

This is the first reliability slice of `UPGRADE_PLAN.md`, not the entire upgrade.
The assessment remains a record of the baseline, not a description of these fixes.

## Changes

- Library mutations persist an atomic JSON index before publishing new UI state.
  Failures propagate to save flows or appear as a storage error.
- A corrupt/unreadable index, or a missing primary with a backup present, blocks
  writes instead of starting an empty library. Original files remain untouched.
- `projects.backup.json` retains the previous valid index. It is **not a complete
  scan backup** or a way to undo deliberately deleted files. Automatic restore is
  intentionally avoided: older metadata may reference files subsequently moved
  or deleted. Recovery currently requires inspecting files and the index.
- Moves preflight required companions, copy without overwriting destinations,
  commit the library, then remove sources. Copy/index failures remove only new
  copies and keep the originals. An app termination can leave harmless extra
  files; automatic orphan detection/recovery is a later step.
- Reconstruction copies to a new model filename and retains the old model,
  measurements and a `<new-id>_previous.json` metadata snapshot. The optional
  `retainedReconstructionFiles` field tracks them through moves/deletions.
  The viewer starts a fresh measurement list without erasing the old list.
  History restore UI is not yet implemented. Duplicates copy the active version,
  not the reconstruction history. Retention consumes additional disk space.
- HQ save fails if copying source photos or an existing pose file fails.
- Splat save propagates packaging errors, checks referenced photos exist and are
  nonempty, and saves its point cloud and ZIP in one library-index update.
  Missing point clouds now produce a recoverable error instead of discarding
  photos without creating a library record.
- Failed measurement writes keep the saved list/draft; corrupt measurement files
  are not silently overwritten. Reconstructed scans rebind measurement saving
  to the new filename.
- Multi-select scan deletion snapshots the selected scans before mutating the
  sorted list.

## Automated checks

`ScanView3D/StorageCore` contains the same Foundation persistence implementation
compiled into the app, with 15 XCTest cases covering legacy optional-field
decoding, corrupt/missing indexes, backup and primary write failures, retry,
external index changes, partial copies, missing sources, destination collisions,
and copying folders before committing.

On a machine with Swift installed:

```sh
swift test --package-path ScanView3D/StorageCore
```

`Validate iOS` runs these tests plus unsigned device and simulator builds on
macOS/Xcode 26. The TestFlight workflow requires this validation to pass before
signing/uploading. Pull requests run validation without signing credentials.

Local Windows checks validate Swift syntax (with the unchanged known parser
limitation for ScannerView's conditional property), workflow YAML and the new
Xcode source-file registration. These do not replace Swift compilation.

The package tests exercise persistence with a small Codable fixture, not the
entire iOS StorageManager or a physical LiDAR capture. The actual app schema's
only addition is optional and uses its existing synthesized Codable behavior.

## Device acceptance checklist — still required

Use disposable test scans, and copy important existing scans off the device first.

1. Open the upgraded build with an existing library. View old OBJ, PLY and HQ scans
   and existing measurements, including older scale-only HQ scans.
2. Create/rename a project, save each capture mode, restart, and reopen the results.
3. Move scans with textures, measurements, HQ photos/poses and splat ZIPs. Confirm
   every companion remains usable after restarting.
4. Delete multiple sorted scan rows; only the selected scans should disappear.
5. Reconstruct a measured HQ scan, add a new measurement and restart. The new
   measurement must belong to the new model; old recovery files remain on disk.
6. Check error visibility while sheets are open, and with large Dynamic Type.
7. In a controlled development container, simulate a failed save/copy and corrupt
   index. Confirm originals survive and no failed capture is reset. Do not corrupt
   a real library for this test.

## Not yet fixed by this slice

Capture queue draining/generation guards, crash-resumable capture sessions,
complete backup/restore UI, automatic orphan cleanup, transactional duplication
of every optional companion, import validation, geolocation freshness/accuracy,
ordinary HQ export transforms, and the remaining terrain/object/room roadmap.
Failed new-scan saves can leave unindexed candidate files (sources stay intact);
cleanup/recovery is intentionally deferred rather than deleting uncertain data.
No survey-accuracy claim is introduced by this release.
