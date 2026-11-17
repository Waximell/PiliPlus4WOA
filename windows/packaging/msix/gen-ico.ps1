# Builds windows/runner/resources/app_icon.ico from the generated MSIX logo assets.
#
#   pwsh -File gen-ico.ps1 [-Source <png>] [-OutFile <ico>]
#
# Why: the MSIX assets only drive the *packaged* identity (Start menu, taskbar, Apps
# list). The window title bar, Alt-Tab and the desktop shortcut read the icon that is
# compiled into piliplus.exe from windows/runner/resources/app_icon.ico - which is
# still Flutter's default blue logo in upstream. CI overwrites it before the Flutter
# build so both identities match.
param(
    [string]$Source = (Join-Path $PSScriptRoot 'Assets\Square44x44Logo.targetsize-256_altform-unplated.png'),
    [string]$OutFile = (Join-Path $PSScriptRoot '..\..\runner\resources\app_icon.ico')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$sizes = 16, 24, 32, 48, 64, 128, 256
$src = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Source))
try {
    $frames = @()
    foreach ($s in $sizes) {
        $bmp = [System.Drawing.Bitmap]::new($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.DrawImage($src, 0, 0, $s, $s)
        } finally { $g.Dispose() }
        $ms = [System.IO.MemoryStream]::new()
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $frames += , $ms.ToArray()
        $ms.Dispose()
        $bmp.Dispose()
    }
} finally {
    $src.Dispose()
}

# ICO container: 6-byte header, one 16-byte directory entry per frame, then the
# PNG payloads (Vista+ allows PNG-compressed frames, which is how 256x256 fits).
$out = [System.IO.MemoryStream]::new()
$w = [System.IO.BinaryWriter]::new($out)
$w.Write([uint16]0)                 # reserved
$w.Write([uint16]1)                 # type: icon
$w.Write([uint16]$frames.Count)

$offset = 6 + 16 * $frames.Count
for ($i = 0; $i -lt $frames.Count; $i++) {
    $s = $sizes[$i]
    $w.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))   # width (0 means 256)
    $w.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))   # height
    $w.Write([byte]0)               # palette size
    $w.Write([byte]0)               # reserved
    $w.Write([uint16]1)             # colour planes
    $w.Write([uint16]32)            # bits per pixel
    $w.Write([uint32]$frames[$i].Length)
    $w.Write([uint32]$offset)
    $offset += $frames[$i].Length
}
foreach ($f in $frames) { $w.Write($f) }
$w.Flush()

[System.IO.File]::WriteAllBytes((Join-Path (Split-Path $OutFile -Parent) (Split-Path $OutFile -Leaf)), $out.ToArray())
$w.Dispose(); $out.Dispose()
Write-Host "wrote $OutFile ($((Get-Item $OutFile).Length) bytes, $($frames.Count) frames: $($sizes -join '/'))"
