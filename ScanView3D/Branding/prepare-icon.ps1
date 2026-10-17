# Deterministic packaging only. Artwork is generated separately with image_gen.
# Run on Windows after approving a new TinyScanner-master.png.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$source = [System.Drawing.Image]::FromFile((Join-Path $PSScriptRoot 'TinyScanner-master.png'))
try {
    foreach ($asset in @(
        @{ Size = 1024; Path = '../ScanView3D/Assets.xcassets/AppIcon.appiconset/AppIcon.png' },
        @{ Size = 512; Path = '../ScanView3D/Assets.xcassets/TinyScannerMark.imageset/TinyScannerMark.png' }
    )) {
        $bitmap = [System.Drawing.Bitmap]::new($asset.Size, $asset.Size, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::FromArgb(12, 16, 23))
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $graphics.DrawImage($source, [System.Drawing.Rectangle]::new(0, 0, $asset.Size, $asset.Size))
            $bitmap.Save((Join-Path $PSScriptRoot $asset.Path), [System.Drawing.Imaging.ImageFormat]::Png)
        } finally { $graphics.Dispose(); $bitmap.Dispose() }
    }
} finally { $source.Dispose() }
