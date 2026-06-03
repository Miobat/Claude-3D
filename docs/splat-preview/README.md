# Splat bundle preview & assessment

Analysis of a `*_splat.zip` exported from ScanView3D (Splat → Desktop).

## What was in the bundle
- **54 photos**, 1920×1440, sharp, well-lit
- **transforms.json** — full intrinsics (fl 1336px, cx 966, cy 721) + 54 ARKit poses (OpenGL convention)
- **points3D.ply** — 72,245 colored LiDAR points
- Scene: a room/workshop ≈ 6.1 × 2.9 × 4.6 m (8.2 m diagonal)

The poses and the point cloud are **consistent** (reprojecting the cloud through
camera 0 matches the real photo), so the bundle is valid and a desktop tool
(Postshot / Nerfstudio `ns-train splatfacto`) can ingest it directly — no COLMAP.

## Renders (made from the LiDAR point cloud, the splat's init)
- `01_pointcloud_orbit.png` — the captured geometry from 6 angles
- `02_photo_vs_pointcloud.png` — real photo (left) vs point cloud reprojected from the same camera (right)
- `03_sample_photos.png` — 6 of the source photos

## Key finding — capture style limits splat quality
The camera moved only **~20 cm total** (≈ stood in one spot and rotated ~50°).
Gaussian splatting needs **parallax** from cameras at many *different positions*
orbiting the subject. With near-pure rotation:
- ✅ Renders well from **near the capture spot** (a "3D photo" you can lean around)
- ❌ Not a walk-around model — far walls / behind objects were seen from one angle
  only, so they show holes/smearing when you move (visible in the orbit render)

The LiDAR init mitigates this (geometry is known without parallax), so it beats a
photos-only splat, but it stays viewpoint-limited.

## Issues spotted in the export
1. **Photos are stored rotated 90°** relative to the intrinsics. Splat trainers
   assume image/intrinsic consistency — fix the exporter to bake EXIF orientation
   or rotate pixels and swap fx/fy, cx/cy. (Likely also a cause of High-Quality
   alignment failures.)
2. **2 degenerate frames** at the origin (pre-tracking) should be dropped.

## To get a better splat next time
Walk *around* the subject (translate, don't just rotate), keep 60–80 % overlap,
get closer for detail, and keep moving steadily.
