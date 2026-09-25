"""Independent OpenUSD + ZIP-reader check of the Swift export fixture."""
import struct
import sys
import zipfile
from pathlib import Path
from pxr import Usd, UsdGeom

path = Path(sys.argv[1]).resolve()
with zipfile.ZipFile(path) as archive:
    assert archive.testzip() is None, 'CRC failure'
    assert archive.namelist() == ['aligned.usda', 'source.usdz']
    with path.open('rb') as stream:
        for entry in archive.infolist():
            assert entry.compress_type == zipfile.ZIP_STORED
            stream.seek(entry.header_offset + 26)
            name_size, extra_size = struct.unpack('<HH', stream.read(4))
            assert (entry.header_offset + 30 + name_size + extra_size) % 64 == 0

stage = Usd.Stage.Open(str(path))
assert stage, 'OpenUSD could not open the exported archive'
assert not stage.GetCompositionErrors(), stage.GetCompositionErrors()
assert UsdGeom.GetStageUpAxis(stage) == 'Y'
assert UsdGeom.GetStageMetersPerUnit(stage) == 1.0
cache = UsdGeom.XformCache()
points = []
for prim in stage.Traverse():
    if prim.IsA(UsdGeom.Mesh):
        mesh = UsdGeom.Mesh(prim)
        matrix = cache.GetLocalToWorldTransform(prim)
        points.extend(tuple(round(v, 6) for v in matrix.Transform(p)) for p in mesh.GetPointsAttr().Get())
        assert tuple(mesh.GetDisplayColorAttr().Get()[0]) == (1.0, 0.0, 0.0)
assert sorted(points) == sorted([(6, 7.5, 13), (6, 9.5, 13), (2, 7.5, 13), (6, 7.5, 19)]), points
print('Independent OpenUSD 25.11: transformed vertices, units, axes, colour, nested asset and ZIP CRC/alignment passed.')
