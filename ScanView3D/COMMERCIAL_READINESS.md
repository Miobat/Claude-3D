# TinyScanner reliability audit and release gates

Audit date: 6 November 2026. Branch: `codex/commercial-readiness`, based on
published adaptive-terrain `d2e9793`. The remote Claude branch remains `7f64bf0`,
already included in this history. No integration merge or TestFlight publication
is part of this audit.

This hardening pass fixes reproducible storage, capture, export and viewer faults.
It is not a certification of survey accuracy or a claim that the app is ready for
paid customers. The remaining release gates below still apply.

## Fixed defects

| Area | Failure | Protection added |
| --- | --- | --- |
| Scan moves | Existing destination assets were deleted as presumed orphans | Refuse collisions; preserve both copies and the index |
| Duplication | Failed optional copies could silently lose photos, viewer files, measurements or splat bundles | Validate registered sources; stage complete companions; publish only after file copy and index commit; roll back failed copies |
| Project edits | A stale project snapshot could overwrite newer scan records | Project edits update project metadata, not the scan collection |
| Library metadata | Unsafe paths, duplicate IDs/filenames and overflowing counts were accepted | Validate before loading/publishing; preserve an invalid library read-only; bound index reads |
| Model saves | OBJ flushes could escape Swift error handling; failed material/JPEG writes could appear successful | Throwing buffered writes, synchronization, geometry validation and staged asset sets |
| Failed saves/imports | Repeated retries left unindexed candidate files behind | Clean only the new attempt's explicitly owned files; never delete recovery data |
| Recovery | Valid-looking checkpoint edits or incomplete writes could go unnoticed | Version-2 payload SHA-256/size binding, read-back verification, bounded reads and symlink checks; legacy reads retained |
| Capture memory | HQ/Splat kept accepting photos after the memory warning said they were paused | All photo modes obey the sticky memory-pause policy |
| Capture evidence | Later voxel positions could inherit an earlier photo-quality claim | Photo evidence remains attached to the actual photographed position |
| Capture lifecycle | Late mesh results could outlive the capture that requested them | Capture-epoch check rejects old results; failed photos can be retried without moving |
| Imports | Unchecked external material references, oversized PLY declarations and main-thread parsing | Local dependency checks, size/header/count/finite-bounds checks, texture pixel limits, worker-thread import and visible error reporting |
| Viewer | Unchecked/unaligned geometry reads and extreme grid sizes could crash | Bounded byte reads, finite supported bounds and at most 258 grid cylinders; measured data is unchanged |
| Viewer lifecycle | Old asynchronous results could prepare a replacement viewer's measurement session | Teardown guards and explicit viewer ownership |
| Manual measurements | A failed save could lose a height or corrupt the next two-point attempt | Retain exact draft/normal data; explicit Retry Save; clear stale failure text on success |
| Release/privacy | Missing required-reason declarations and implicit workflow token permissions | Bundled privacy manifest and read-only repository token permission; diagnostics sharing notice |

## Safety and compatibility contracts

- Existing scan formats, adaptive terrain schema, metric transforms, texture UV
  orientation, original-mesh retention, and Claude's near-depth/smoothing choices
  remain in place. New capture checkpoints add integrity fields; old checkpoints
  can still be read. Use this build or newer for the new integrity verification.
- The library stays in its existing app container and bundle ID. No migration,
  account, cloud upload, payment SDK, analytics or automatic deletion was added.
- Startup refuses an absent index when nonempty scan folders remain. An index
  backup is metadata recovery, not a whole-library backup or deletion undo.
- Library index reads are capped at 128 MiB. Checkpoint payloads are capped at
  512 MiB and checkpoint JSON at 1 MiB. Hitting a bound is an explicit failure,
  not truncation or loss of the last valid indexed data.
- Imports support OBJ/PLY. OBJ material packaging currently supports one same-base
  MTL and one same-base `_texture.jpg`/`.png`; unsupported dependency layouts fail
  explicitly instead of silently discarding textures. Model files are capped at
  512 MiB, declared/decoded geometry at five million vertices/faces, textures at
  64 MiB compressed and 8192 pixels per axis. These are safety bounds, not a
  guarantee that every model below them fits every supported phone's memory.
- Models outside the viewer's supported local range of ±1,000 km are rejected
  without rescaling or deleting their source. Terrain sampling is not accuracy.
- Symlink/path checks protect the managed library operations; this is not a claim
  of an independently security-audited parser or protection against all external
  concurrent modification through Files. Never manually edit a live library.

## Verification

The shared Swift package tests actual production persistence, capture and export
helpers. New cases exercise injected flush/sync/copy/write failures, destination
collisions, corrupt or tampered checkpoints, unsafe paths, malformed geometry,
extreme bounds and PLY declarations. Native simulator fixtures additionally use
the actual StorageManager, OBJExporter, SceneKit and measurement session.

Run `swift test --package-path ScanView3D/StorageCore` on a supported Swift host.
GitHub Actions builds both device and simulator targets, checks USDZ through an
independent OpenUSD reader, runs the native regression fixtures, and captures the
light/dark/large-text/landscape layouts. Development pushes do not upload builds.
Final run results are recorded in the handover after validation completes.

## Before a paid customer release

1. **Complete backup and restore.** Build and test a versioned whole-library
   archive including original geometry, source photos/poses, measurements,
   reconstruction history, metadata and recovery. Existing model shares are NOT
   backups. Prove restore on a clean device and interrupted/low-space restore.
2. **Safe recovery UX.** A damaged index is protected but has no end-user repair
   wizard. Add reviewed recovery/orphan discovery without automatic deletion.
   Consider recoverable deletion/trash and reconstruction-history restoration.
3. **Physical-device acceptance.** Use disposable copies on iPhone 16 Pro and an
   older supported LiDAR device: all capture modes, repeated pause/stop/reset,
   background/lock/force-quit, denied camera/location, limited disk space, thermal
   pressure, larger scans, save/reopen and independent export readers. Confirm
   checkpoint duration and peak memory; extra integrity hashing adds I/O.
4. **Accuracy evidence.** Repeat rooms, objects, reflective/thin surfaces, slopes,
   kerbs and ditches against independent measurements. Document range, drift,
   lighting and material limits. Do not advertise centimetre/survey accuracy based
   only on synthetic tests or point spacing.
5. **Long-running tasks.** Duplication still has synchronous large file work and
   staging uses extra disk space. Move preparation to a serialized worker with
   progress/cancellation before large customer libraries. Imports and
   re-reconstruction also need explicit cancellation and interruption acceptance.
   Native parsers and CAD extraction can still allocate model-sized memory.
6. **Unsaved measurement UX.** Failed saves can be retried while the viewer is
   open, but drafts are not durable across termination and changing tools/leaving
   the viewer can discard them. Add reviewed discard protection or revision-bound
   draft recovery before claiming durable field notes.
7. **Release reproducibility and governance.** Pin/review CI action revisions and
   create a reviewed Fastlane dependency lockfile; the current Gemfile is not
   locked. Set branch protection/release review, signing access ownership and a
   rollback policy. Do not change the existing Apple listing or publish as part
   of validation.
8. **Owner decisions.** TinyCorp must supply/approve support contact, privacy policy,
   terms, paid licensing/purchase model, customer data-retention expectations and
   App Store disclosures. The binary manifest is not a privacy policy or legal
   review. Recheck declarations if cloud/AI/analytics or payments are later added.

## Privacy declaration basis

The current native app has no app-operated network upload or tracking SDK. Its
privacy manifest declares app-local preferences (`CA92.1`), metadata of local and
user-selected files (`C617.1`, `3B52.1`), low-space capture decisions (`E174.1`),
and elapsed-time interaction logic (`35F9.1`). User-initiated exports and support
logs can contain customer information; review them before sharing.

References: [Apple required-reason API declarations](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
and [Apple privacy-manifest structure](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest).
