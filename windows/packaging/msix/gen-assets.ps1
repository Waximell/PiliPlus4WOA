# Generates the MSIX tile logos from the application logo.
#
#   pwsh -File windows/packaging/msix/gen-assets.ps1
#
# The output PNGs (windows/packaging/msix/Assets) are committed on purpose so the
# CI job does not have to render images on the runner. Re-run this script only if
# the app logo changes.
param(
    [string]$SourceLogo = "assets/images/logo/logo.png"
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$outDir = Join-Path $PSScriptRoot "Assets"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# --- load the source logo and crop away the transparent border -----------------
$srcPath = (Resolve-Path $SourceLogo).Path
$src = [System.Drawing.Image]::FromFile($srcPath)
$bmp = New-Object System.Drawing.Bitmap $src

$rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
$data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stride = $data.Stride
$bytes = New-Object byte[] ($stride * $bmp.Height)
[System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
$bmp.UnlockBits($data)

$minX = $bmp.Width; $minY = $bmp.Height; $maxX = -1; $maxY = -1
for ($y = 0; $y -lt $bmp.Height; $y++) {
    $row = $y * $stride
    for ($x = 0; $x -lt $bmp.Width; $x++) {
        if ($bytes[$row + $x * 4 + 3] -gt 8) {
            if ($x -lt $minX) { $minX = $x }
            if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }
            if ($y -gt $maxY) { $maxY = $y }
        }
    }
}
if ($maxX -lt 0) { throw "Source logo '$srcPath' is fully transparent." }

$cropW = $maxX - $minX + 1
$cropH = $maxY - $minY + 1
$crop = New-Object System.Drawing.Rectangle $minX, $minY, $cropW, $cropH
Write-Host "Source logo ${cropW}x${cropH} (cropped from $($bmp.Width)x$($bmp.Height))"

# --- render the tiles ---------------------------------------------------------
# Pad = free margin on each side, as a fraction of the tile edge.
$tiles = @(
    @{ Name = 'Square44x44Logo.png';   W = 44;  H = 44;  Pad = 0.02 },
    @{ Name = 'Square150x150Logo.png'; W = 150; H = 150; Pad = 0.10 },
    @{ Name = 'Square310x310Logo.png'; W = 310; H = 310; Pad = 0.10 },
    @{ Name = 'Wide310x150Logo.png';   W = 310; H = 150; Pad = 0.10 },
    @{ Name = 'StoreLogo.png';         W = 50;  H = 50;  Pad = 0.04 }
)

foreach ($t in $tiles) {
    $canvas = New-Object System.Drawing.Bitmap $t.W, $t.H
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

    $boxW = [double]$t.W * (1 - 2 * $t.Pad)
    $boxH = [double]$t.H * (1 - 2 * $t.Pad)
    $scale = [Math]::Min($boxW / $cropW, $boxH / $cropH)
    $drawW = [int][Math]::Round($cropW * $scale)
    $drawH = [int][Math]::Round($cropH * $scale)
    $x = [int](($t.W - $drawW) / 2)
    $y = [int](($t.H - $drawH) / 2)

    $g.DrawImage($bmp, (New-Object System.Drawing.Rectangle $x, $y, $drawW, $drawH), $crop, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose()

    $outPath = Join-Path $outDir $t.Name
    $canvas.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $canvas.Dispose()
    Write-Host "  -> $($t.Name)  $($t.W)x$($t.H)"
}

$bmp.Dispose()
$src.Dispose()
Write-Host "MSIX assets written to $outDir"
