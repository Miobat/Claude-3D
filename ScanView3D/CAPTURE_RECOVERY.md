# Capture recovery and GPS correctness

Branch: `codex/capture-recovery`, based on the storage-integrity implementation
at `bb3baca`. This is a follow-up reliability slice, not the terrain workbench.

## Release hold

Pushes to `codex/**` branches containing this workflow change run validation only.
The signed TestFlight job is skipped unless the workflow is manually dispatched.
Do not manually dispatch publishing for this branch without the owner's approval.
Existing Claude/main publishing behavior is unchanged; merging there can publish.
The earlier storage-integrity build was already uploaded and is unaffected.

## Capture behavior

- Stop stops accepting new frames, pauses ARKit, and asynchronously drains accepted
  photos, depth integration and texture work before the UI builds the final mesh.
- Requested 12 MP frames finish even after Stop. An eight-second fallback bounds
  the wait if ARKit never calls back. Completed requests release their fallback
  camera buffer immediately. No ARFrame is retained in the queued JPEG writer.
- Photo files are staged before being renamed. Counts/poses become accepted only
  after JPEG finalization and an atomic pose-journal update both succeed. Journal
  entries include image dimensions and intrinsics for recovery and desktop export.
- Each new scan gets a new ARSession. Session identity and worker epochs reject
  late callbacks. Texture/depth resets cannot accept old work into a new capture.
- An interruption, tab departure or background transition finalizes/checkpoints
  the capture, with a bounded iOS background task. It does not silently resume
  tracking after returning. A manual, uninterrupted Stop can still be continued.
- Reset and recovery-file deletion require explicit confirmation.

## Durable recovery

The scanner creates a lightweight manifest at capture start, then requests a
geometry checkpoint every 30 seconds while actively scanning. Checkpoints also
run after Stop and on background/interruption. Encoding happens on a serial
background queue. A payload uses a new binary property-list filename; the small
JSON manifest switches to it only after writing succeeds. Failed updates preserve
the previous checkpoint. Metadata-only updates do not erase existing geometry.

`Documents/CaptureRecovery/<capture-id>/checkpoint.json` references a
`mesh-<uuid>.plist` payload and the source-photo folder under `Documents/Captures`.
Photos and their sibling `_poses.json` journal survive app restarts. No checkpoint
metadata is placed inside photogrammetry's images-only input folder.

The scanner's **Unfinished captures** screen lists timestamps and offers Recover
or confirmed Discard. Recover reopens the last checkpoint into the save flow;
Keep for Later retains it. Saving successfully cleans up the recovery copy only
after the library save and metadata update succeed. Recovery never appends new
geometry to a previous AR coordinate frame.

Limits to be clear about:

- A sudden process kill can lose work since the last completed geometry checkpoint.
  Before the first checkpoint, photo captures can have saved photos but no mesh.
- The 30-second interval is a scheduling target, not a real-time durability promise.
  Large checkpoints can take longer and need extra memory/disk space. iOS may end
  background execution before a new checkpoint finishes; the old one remains.
- Recovery of Fast scans preserves geometry and vertex colours, not the original
  temporary texture-keyframe cache, so a recovered Fast scan may lack a baked atlas.
- Recovered Splat export still requires a usable point-cloud checkpoint. Saved
  photos are preserved when one is missing, but that export does not yet have a
  photos-only library-record workflow. HQ can reconstruct from photos alone.
- Corrupt or unsupported checkpoints are preserved, not silently repaired/deleted.
  An abrupt interruption can leave unreferenced payloads/partial image files;
  automatic orphan cleanup remains future work.
- App termination after a library commit but before recovery cleanup can leave
  a duplicate recoverable capture. There is no cross-store exactly-once transaction.

## GPS policy

Location updates run only for the active capture when requested. Each request has
a new manager identity and start timestamp. Old-manager callbacks, negative or
nonfinite horizontal accuracy, invalid coordinates, fixes older than the request,
fixes more than 30 seconds old, and timestamps over two seconds in the future are
rejected. The newest valid observation is preferred over an older, smaller radius.

Invalid vertical accuracy or altitude removes altitude only; it does not throw
away otherwise valid horizontal coordinates. Timestamp, horizontal/vertical
uncertainty and reduced-accuracy authorization are retained. The selected fix is
frozen when capture finishes, so a long reconstruction does not substitute a later
location. Recovery retains the observation's original timestamp.

UI wording explicitly says approximate phone GPS, not survey control. Compass
alignment is described as requested, not independently verified. The phone fix
does not establish a model origin, CRS transform, vertical datum or survey accuracy.
Scanning and saving remain possible without location permission.

Apple documents negative horizontal accuracy as invalid coordinates and vertical
accuracy as the validity/uncertainty of altitude:
[CLLocation](https://developer.apple.com/documentation/corelocation/cllocation),
[horizontalAccuracy](https://developer.apple.com/documentation/corelocation/cllocation/horizontalaccuracy).
Freshness/future-time thresholds above are explicit app policy, not Apple accuracy guarantees.

## Validation

The Foundation suite contains 41 cases: the previous 15 storage tests and 26 new
cases for worker epochs, stale/invalid GPS, metadata round trips, restart recovery,
photo-only manifests, payload/index write failures, metadata-only updates,
missing/corrupt payloads and unsafe payload paths. Run:

```sh
swift test --package-path ScanView3D/StorageCore
```

CI also compiles the physical-device and simulator paths without signing.
These tests do not simulate ARKit hardware, actual device termination or live
SwiftUI navigation. Required device checks before release:

1. Rapid Stop/Reset/Start, including a pending 12 MP request: no mixed photos,
   negative counters, missing accepted poses or permanently stuck Finalizing.
2. Stop, Keep for Later, force-quit, reopen, recover, save and reopen the saved scan
   in each mode. Compare geometry counts/colours and HQ photos/poses.
3. Background, lock the screen, change tabs and induce a tracking interruption:
   no automatic resumption into the old coordinate frame; recovery remains available.
4. Confirm recovered Fast scans' colour fallback and the documented Splat
   limitation when no geometry checkpoint exists.
5. Deny location permission, use reduced accuracy, wait for a stale fix, and repeat
   captures in different places. No prior-capture fix should be reused; invalid
   altitude should be omitted. Check the saved observation timestamp.
6. Exercise low storage/write failures with disposable data. Prior checkpoints
   must remain readable and failed keep/save must retain the in-memory capture.
7. Measure checkpoint memory, time and battery/thermal impact on large captures.

No new TestFlight upload is authorized by validation alone.
