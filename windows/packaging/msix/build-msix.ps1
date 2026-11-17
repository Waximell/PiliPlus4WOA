<#
.SYNOPSIS
    Packs the PiliPlus Windows ARM64 build output into an .msix (and signs it when a
    certificate is supplied).

.DESCRIPTION
    The package architecture is ARM64 and comes from two things only:
      * ProcessorArchitecture="arm64" in windows/packaging/msix/AppxManifest.xml.in
      * the payload, which is built by `flutter build windows` on an ARM64 runner
    The packer executable itself (makeappx.exe) is a build tool; which flavour the
    SDK ships has no influence on what ends up inside the package. We prefer the
    native arm64 tooling when the installed SDK has it, and say which one we used.

.EXAMPLE
    pwsh -File windows/packaging/msix/build-msix.ps1 -Version "2.2.1+1234"
#>
param(
    # Version written by lib/scripts/build.ps1 to $GITHUB_ENV, e.g. "2.2.1+1234".
    [Parameter(Mandatory = $true)]
    [string]$Version,

    [string]$PayloadDir = "build\windows\arm64\runner\Release",
    [string]$OutDir = ".",

    [string]$IdentityName = "Waximell.PiliPlus.WOA",
    # Must be character-for-character identical to the signing certificate subject,
    # otherwise Windows refuses to install ("publisher does not match").
    [string]$Publisher = "CN=Waximell, C=CN",
    [string]$PublisherDisplayName = "Waximell",
    [string]$DisplayName = "PiliPlus",
    [string]$Description = "PiliPlus for Windows on ARM64",
    [string]$Executable = "piliplus.exe",

    # Signing material. Left empty -> the package is packed but stays unsigned.
    [string]$PfxBase64 = $env:MSIX_PFX_BASE64,
    [string]$PfxPassword = $env:MSIX_PFX_PASSWORD,

    # Opt out of the "signing is mandatory" rule; only for local packing tests.
    [switch]$AllowUnsigned
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$text) { Write-Host "==> $text" }

# --- locate a Windows SDK build tool, arm64 first ------------------------------
function Find-SdkTool {
    param([Parameter(Mandatory = $true)][string]$Name)

    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin"
    )

    foreach ($arch in @('arm64', 'x64')) {
        foreach ($root in $roots) {
            if (-not $root -or -not (Test-Path $root)) { continue }
            $hit = Get-ChildItem -Path $root -Filter $Name -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match "\\$([regex]::Escape($arch))\\$([regex]::Escape($Name))$" } |
                Sort-Object FullName -Descending |
                Select-Object -First 1
            if ($hit) { return $hit.FullName }
        }
    }

    throw "$Name was not found in the Windows SDK. The runner image normally ships Windows SDK 10.0.26100.0."
}

# --- 2.2.1+1234 -> 2.2.1.1234 ------------------------------------------------
# MSIX wants exactly four numeric parts, each 0..65535, and the whole thing must
# only grow over time for upgrades to work (the commit count does that for us).
function ConvertTo-MsixVersion {
    param([Parameter(Mandatory = $true)][string]$Raw)

    $parts = $Raw.Trim() -split '\+'
    $numeric = @($parts[0] -split '\.' | ForEach-Object { [int]($_ -replace '\D', '') })
    while ($numeric.Count -lt 3) { $numeric += 0 }

    $revision = 0
    if ($parts.Count -gt 1) {
        $revision = [int]($parts[1] -replace '\D', '')
    }
    if ($revision -gt 65535) {
        Write-Warning "Revision $revision does not fit in an MSIX version, clamping to 65535."
        $revision = 65535
    }

    return "$($numeric[0]).$($numeric[1]).$($numeric[2]).$revision"
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$payload = (Resolve-Path $PayloadDir).Path
$manifestTemplate = Join-Path $PSScriptRoot 'AppxManifest.xml.in'
$assetsDir = Join-Path $PSScriptRoot 'Assets'
$outRoot = if (Test-Path $OutDir) { (Resolve-Path $OutDir).Path } else { (New-Item -ItemType Directory -Force $OutDir).FullName }

if (-not (Test-Path (Join-Path $payload $Executable))) {
    throw "'$Executable' not found in '$payload'. Did the Flutter build step run?"
}

$msixVersion = ConvertTo-MsixVersion $Version
$packageName = "PiliPlus_windows_${Version}_arm64.msix"
$packagePath = Join-Path $outRoot $packageName

# --- stage: payload + assets + manifest ---------------------------------------
$stage = Join-Path ([System.IO.Path]::GetTempPath()) ("piliplus-msix-" + [guid]::NewGuid().ToString('N'))
Write-Step "Staging package in $stage"
New-Item -ItemType Directory -Force -Path $stage | Out-Null

try {
    Copy-Item -Path (Join-Path $payload '*') -Destination $stage -Recurse -Force
    Copy-Item -Path $assetsDir -Destination $stage -Recurse -Force

    $manifest = Get-Content $manifestTemplate -Raw -Encoding UTF8
    $manifest = $manifest.
        Replace('{{IDENTITY_NAME}}', $IdentityName).
        Replace('{{PUBLISHER}}', $Publisher).
        Replace('{{PUBLISHER_DISPLAY_NAME}}', $PublisherDisplayName).
        Replace('{{DISPLAY_NAME}}', $DisplayName).
        Replace('{{DESCRIPTION}}', $Description).
        Replace('{{VERSION}}', $msixVersion).
        Replace('{{EXECUTABLE}}', $Executable)

    # Ignore XML comments: documentation inside the template must not trip this check.
    $check = [regex]::Replace($manifest, '<!--.*?-->', '', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($check -match '\{\{[A-Z_]+\}\}') {
        throw "Unreplaced placeholder left in the manifest: $($Matches[0])"
    }
    # makeappx requires UTF-8 (with or without BOM) for the manifest.
    [System.IO.File]::WriteAllText((Join-Path $stage 'AppxManifest.xml'), $manifest, (New-Object System.Text.UTF8Encoding $false))

    # --- resources.pri ------------------------------------------------------------
    # makeappx only compresses files; it does NOT index resource variants. The shell
    # resolves the logo by TargetSize / AlternateForm through MRT, and that index is
    # resources.pri. Without it the `..._altform-unplated.png` files are just oddly
    # named pictures: Windows cannot see them, falls back to the plated 44x44 image,
    # paints the accent-coloured plate itself and rescales - the classic "blue square
    # + blurry icon" in the taskbar and Start menu.
    $priConfig = Join-Path $stage 'priconfig.xml'
    $priPath = Join-Path $stage 'resources.pri'
    $priDump = Join-Path ([System.IO.Path]::GetTempPath()) ("piliplus-pri-" + [guid]::NewGuid().ToString('N') + ".xml")
    $manifestPath = Join-Path $stage 'AppxManifest.xml'

    $makepri = Find-SdkTool 'makepri.exe'
    Write-Step "Indexing resources ($([IO.Path]::GetFileName($makepri)))"
    Write-Host "    makepri: $makepri"

    & $makepri createconfig /cf $priConfig /dq zh-CN /o | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "makepri createconfig failed with exit code $LASTEXITCODE" }

    & $makepri new /pr $stage /cf $priConfig /of $priPath /in $manifestPath /o | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "makepri new failed with exit code $LASTEXITCODE" }
    if (-not (Test-Path $priPath)) { throw "makepri did not produce resources.pri" }

    # Self-check: a previous "looks right but nothing is indexed" package is exactly
    # the failure mode we are guarding against here, so verify the variants landed.
    & $makepri dump /if $priPath /of $priDump /o | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $priDump)) { throw "makepri dump failed with exit code $LASTEXITCODE" }

    $dump = Get-Content $priDump -Raw
    $qualifierLines = @($dump -split "`r?`n" | Where-Object { $_ -match 'AlternateForm Qualifiers|TargetSize Qualifiers' })
    foreach ($line in $qualifierLines) { Write-Host "    $($line.Trim())" }

    $unplatedEntries = ([regex]::Matches($dump, 'altform-unplated', 'IgnoreCase')).Count
    if (-not ($dump -match 'unplated' -and $dump -match 'lightunplated')) {
        throw "resources.pri does not list the unplated alternate forms - the shell would fall back to a plated icon."
    }
    if ($unplatedEntries -lt 1) {
        throw "resources.pri contains no altform-unplated entries."
    }
    foreach ($s in 16, 24, 32, 48, 256) {
        if (-not ($dump -match "targetsize-$s\b")) {
            throw "resources.pri has no targetsize-$s variant."
        }
    }
    Write-Host "    indexed $unplatedEntries unplated entries, target sizes 16/24/32/48/256 present"

    Remove-Item $priDump -Force -ErrorAction SilentlyContinue
    Remove-Item $priConfig -Force -ErrorAction SilentlyContinue

    Write-Step "Packing $packageName (version $msixVersion, ProcessorArchitecture arm64)"
    $makeappx = Find-SdkTool 'makeappx.exe'
    Write-Host "    makeappx: $makeappx"
    & $makeappx pack /d $stage /p $packagePath /o
    if ($LASTEXITCODE -ne 0) { throw "makeappx failed with exit code $LASTEXITCODE" }
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

# --- sign ---------------------------------------------------------------------
# An unsigned package is useless: Windows rejects it on install. So a missing
# certificate is a hard failure by default, not a warning that ships a broken
# release. Pass -AllowUnsigned if you really only want to test the packing step.
$signed = $false
if ([string]::IsNullOrWhiteSpace($PfxBase64) -or [string]::IsNullOrWhiteSpace($PfxPassword)) {
    if (-not $AllowUnsigned) {
        throw @"
MSIX_PFX_BASE64 / MSIX_PFX_PASSWORD are not available, so the package cannot be signed.
Windows refuses to install an unsigned .msix, so this build would be useless.

Most likely cause: the calling workflow did not forward the secrets -
a reusable workflow started with ``uses:`` only receives them when the caller
declares ``secrets: inherit``.

Pass -AllowUnsigned if you deliberately want an unsigned package for testing.
"@
    }
    Write-Warning "Packing UNSIGNED because -AllowUnsigned was given."
}
else {
    $pfxPath = Join-Path ([System.IO.Path]::GetTempPath()) ("piliplus-signing-" + [guid]::NewGuid().ToString('N') + ".pfx")
    try {
        [System.IO.File]::WriteAllBytes($pfxPath, [Convert]::FromBase64String($PfxBase64))

        Write-Step "Signing $packageName"
        $signtool = Find-SdkTool 'signtool.exe'
        Write-Host "    signtool: $signtool"
        & $signtool sign /fd SHA256 /f $pfxPath /p $PfxPassword /tr http://timestamp.digicert.com /td SHA256 $packagePath
        if ($LASTEXITCODE -ne 0) { throw "signtool sign failed with exit code $LASTEXITCODE" }
        $signed = $true

        # Deliberately no `signtool verify /pa` here. /pa validates the whole chain
        # against the *runner's* trust store, and our certificate is self-signed, so
        # it can only ever fail on a fresh CI machine - a red herring, not a bad
        # package. The signature is verified for real by installing the package on a
        # machine that trusts the certificate.
        Write-Host "    signed with $((Get-FileHash $pfxPath -Algorithm SHA256).Hash.Substring(0,12))... (pfx)"
    }
    finally {
        Remove-Item $pfxPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "MSIX ready: $packageName ($([math]::Round((Get-Item $packagePath).Length / 1MB, 1)) MB, signed=$signed)"

if ($env:GITHUB_OUTPUT) {
    "msix_path=$packagePath" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "msix_name=$packageName" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "msix_version=$msixVersion" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "signed=$signed" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
