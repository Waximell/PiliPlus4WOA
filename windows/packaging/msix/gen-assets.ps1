# Generates the MSIX logo asset set from the app logo.
#
#   pwsh -File gen-assets.ps1 [-Source <logo.png>] [-OutDir <Assets dir>]
#
# Why so many files: Windows picks an asset by *target size* and *scale* before it
# falls back to the plain<name>.png. Two things matter here:
#
#   * targetsize-<n>_altform-unplated.png - "unplated" means the shell must NOT paint
#     a coloured backplate behind the logo. Without these, Windows falls back to the
#     44x44 image, paints its default system blue plate (#0078D7) behind it and scales
#     it - which looks like "blue square + blurry icon" in the taskbar / Start menu.
#   * targetsize-<n>.png - the plated variant, i.e. the logo that sits on top of the
#     plate for the surfaces that always draw one.
#
# The output is committed to the repo on purpose: CI then only has to copy files, and
# nobody has to trust a System.Drawing render on a runner.
param(
    [string]$Source = (Join-Path $PSScriptRoot '..\..\..\assets\images\logo\logo.png'),
    [string]$OutDir = (Join-Path $PSScriptRoot 'Assets')
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$src = [System.Drawing.Bitmap]::FromFile((Resolve-Path $Source))
try {
    # Trim the transparent border so the circle fills the canvas we draw on.
    $minX = $src.Width; $minY = $src.Height; $maxX = 0; $maxY = 0
    for ($y = 0; $y -lt $src.Height; $y++) {
        for ($x = 0; $x -lt $src.Width; $x++) {
            if ($src.GetPixel($x, $y).A -gt 8) {
                if ($x -lt $minX) { $minX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    $box = [System.Drawing.Rectangle]::new($minX, $minY, $maxX - $minX + 1, $maxY - $minY + 1)
    Write-Host "source $($src.Width)x$($src.Height), opaque box $box"
    $logo = $src.Clone($box, $src.PixelFormat)
} finally {
    $src.Dispose()
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Save-Logo {
    param([int]$Width, [int]$Height, [double]$Fill, [string]$Name)

    $bmp = [System.Drawing.Bitmap]::new($Width, $Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality

        $edge = [Math]::Min($Width, $Height) * $Fill
        $scale = $edge / [Math]::Max($logo.Width, $logo.Height)
        $w = [int][Math]::Round($logo.Width * $scale)
        $h = [int][Math]::Round($logo.Height * $scale)
        $x = [int][Math]::Round(($Width - $w) / 2)
        $y = [int][Math]::Round(($Height - $h) / 2)
        $g.DrawImage($logo, $x, $y, $w, $h)
    } finally {
        $g.Dispose()
    }
    $path = Join-Path $OutDir $Name
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host ("  {0,-58} {1}x{2}" -f $Name, $Width, $Height)
}

# Ratios: the plated logo sits on a coloured plate, so it needs breathing room.
# The unplated one replaces the plate, so it may fill the slot almost edge to edge.
$platedFill = 0.68
$unplatedFill = 0.88

# --- small-icon surfaces: taskbar, Start menu list, Alt-Tab, title bar -----------
$targetSizes = 16, 20, 24, 30, 32, 36, 40, 44, 48, 60, 64, 72, 80, 96, 256
foreach ($s in $targetSizes) {
    Save-Logo -Width $s -Height $s -Fill $platedFill -Name "Square44x44Logo.targetsize-$s.png"
    Save-Logo -Width $s -Height $s -Fill $unplatedFill -Name "Square44x44Logo.targetsize-${s}_altform-unplated.png"
}

# --- DPI scales for the tile-ish surfaces ----------------------------------------
foreach ($scale in 100, 125, 150, 200, 400) {
    $f = $scale / 100.0
    Save-Logo -Width ([int](44 * $f))  -Height ([int](44 * $f))  -Fill $platedFill -Name "Square44x44Logo.scale-$scale.png"
    Save-Logo -Width ([int](150 * $f)) -Height ([int](150 * $f)) -Fill 0.62      -Name "Square150x150Logo.scale-$scale.png"
    Save-Logo -Width ([int](310 * $f)) -Height ([int](310 * $f)) -Fill 0.62      -Name "Square310x310Logo.scale-$scale.png"
    Save-Logo -Width ([int](310 * $f)) -Height ([int](150 * $f)) -Fill 0.62      -Name "Wide310x150Logo.scale-$scale.png"
    Save-Logo -Width ([int](50 * $f))  -Height ([int](50 * $f))  -Fill 0.68      -Name "StoreLogo.scale-$scale.png"
}

# --- plain, scale-agnostic base images referenced by the manifest ----------------
Save-Logo -Width 44  -Height 44  -Fill $platedFill -Name 'Square44x44Logo.png'
Save-Logo -Width 150 -Height 150 -Fill 0.62        -Name 'Square150x150Logo.png'
Save-Logo -Width 310 -Height 310 -Fill 0.62        -Name 'Square310x310Logo.png'
Save-Logo -Width 310 -Height 150 -Fill 0.62        -Name 'Wide310x150Logo.png'
Save-Logo -Width 50  -Height 50  -Fill $platedFill -Name 'StoreLogo.png'

$logo.Dispose()
$count = @(Get-ChildItem $OutDir -Filter *.png).Count
Write-Host "done: $count files in $OutDir"
