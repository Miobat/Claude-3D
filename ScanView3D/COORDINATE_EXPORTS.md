# Coordinate and export consistency

Branch: `codex/coordinate-export-consistency`, stacked on capture recovery at
`92705c5`. TestFlight publishing is still held. This implements the next reliability
slice (assessment F04 and coordinate provenance), not the terrain workbench.

## What changed

- Viewer Share, individual project shares, project exports and CAD exports use
  one package pipeline. Every request gets its own UUID directory. A failed item
  fails the whole project export; partial projects are not reported as complete.
- Delivery is a ZIP containing one folder per scan, a model, its supported material
  companions, `coordinates.json` and a readable explanation. These are **model
  deliveries, not full backups**; source photos and measurements are not included.
- The manifest identifies the source filename/revision and SHA-256, units, axes,
  model-to-local matrix, provenance and limitations. It intentionally omits phone
  GPS coordinates. Matrices are column-major acting on column vectors.
- Ordinary HQ sharing now carries the viewer's model correction inside the USDZ:
  an outer USD transform references the original USDZ unchanged. Textures/materials
  are not decoded/re-encoded. The result is reopened with SceneKit and checked
  against actual source vertex bounds/counts with the correction applied. Export
  fails instead of sharing an unverified corrected file.
- CAD OBJ uses metres and right-handed Z-up `(x,-z,y)`; STL uses the same orientation
  in millimetres. Normals are rotated without translation. Converted non-OBJ CAD
  meshes remain geometry-only, explicitly stated in the manifest.
- Export preparation runs on a single background worker, with progress and Cancel.
  Cancellation is checked during streaming work and between stages; SceneKit loads
  and system ZIP coordination cannot yet be interrupted mid-call.
- Project sharing now uses the common iPad-anchored share-sheet presenter.
- New Fast/Point/Splat records retain their capture-to-local frame. New HQ records
  retain pose-fit vs bounds-estimate vs unknown scale, camera count and fit RMS.
  These are not field-accuracy certificates. Re-reconstruction updates provenance
  with the replacement revision; duplication carries it along.
- Unknown/legacy-unverified scale is visible, not silently called metric. New
  metric measurements, metric CAD exports and scaled snapshots are blocked for
  that state. The calibration UI is still future work. Previously stored values
  are retained. New bounds-estimate results are explicitly labelled estimated.

## Compatibility and limits

Existing library records decode without the optional provenance. Old LiDAR records
with recorded vertices and no correction retain their known local-metre convention;
older HQ/import records without provenance remain unverified. Lost historical
capture transforms cannot be recovered retroactively. A stored capture frame
restores coordinates of retained geometry, not detail removed by mesh processing.

Phone GPS does not georeference geometry. No project CRS, vertical datum, control
registration or local-to-map transform is claimed or inferred. The saved local
floor/low-surface zero is not a surveyed elevation.

The USDZ writer follows OpenUSD's stored ZIP/64-byte alignment rules and supports
nested USDZ. It rejects outputs near the 4 GB ZIP32 limit instead of overflowing.
Sources that fail composition/reimport validation are kept, with an export error.
Third-party app support for nested USDZ still needs real-device interoperability
checks; the CI fixture does not certify every Apple photogrammetry asset.

App-generated OBJ companions are checked. Arbitrary imported material names/maps
are rejected if the current importer cannot package them correctly. Broad import
repair/units calibration remains the next import-focused work, not silently
advertised here. Source-file checksums are checked before/after export; there is
not yet a library-wide asset lease for simultaneous edits in multiple windows.

USDZ, text and STL output are streamed, but SceneKit loading and CAD triangle
extraction still require model-sized memory. Export cache folders are retained so
an active share is never deleted by the next one; retention/cleanup UI is future work.

## Validation

The regression suite adds coordinate algebra, invalid transforms, provenance
compatibility, cancellation, archive alignment/source preservation, OBJ normals/
colours/UVs and SceneKit round-trip cases. An asymmetric tetrahedron with a source
transform receives a 90-degree rotation, scale 2 and translation; an independent
OpenUSD 25.11 reader checks exact world vertices, units, axes and display colour.

CI runs Swift tests, the independent reader, and unsigned device/simulator builds.
To emit the independent-reader fixture locally on a Mac, set `EXPORT_FIXTURE_DIR`
to a new empty directory before running `swift test --package-path ScanView3D/StorageCore`,
then run `python ScanView3D/Tests/verify_usdz.py <directory>/aligned.usdz` with
`usd-core==25.11` installed. The fixture's source text is `Tests/asymmetric.usda`;
its deterministic stored ZIP is embedded in the XCTest file.

Before release, test a real textured HQ scan with a non-identity correction via
all three native sharing routes, reopen in independent software, and compare
dimensions/orientation/textures to the viewer. Also test a coloured PLY, textured
OBJ, CAD OBJ/STL, cancelled/low-storage project export, iPad sharing, repeated
simultaneous share lifetimes, and reopen/duplicate/reconstruct provenance.

References: [OpenUSD USDZ specification](https://openusd.org/dev/spec_usdz.html),
[OpenUSD layer references](https://openusd.org/dev/tut_referencing_layers.html).
