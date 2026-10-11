<#
    SH2NR uninstaller
    SPDX-License-Identifier: GPL-3.0-or-later

    Puts the game back the way it was: restores every file the installer backed up
    and removes the files it added. Reads sh2nr-install.json from the game folder.
    Your own saves, the Enhanced Edition and the game itself are never touched.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string] $GamePath,
    # Also remove the 500 MB neural runtime (off by default - you may want to keep it).
    [switch] $RemoveRuntime,
    # Also remove ReShade (dxgi.dll, its ini files and the shader folder).
    [switch] $RemoveReShade
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Say  ($m) { Write-Host $m }
function Step ($m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "    [ok]   $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "    [note] $m" -ForegroundColor Yellow }
function Die  ($m) { Write-Host ''; Write-Host "STOPPED: $m" -ForegroundColor Red; exit 1 }

Say ''
Say '  SH2NR uninstaller'
Say '  ================='
Say ''

if (-not $GamePath) {
    foreach ($c in @((Split-Path -Parent $PSScriptRoot), (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) {
        if ($c -and (Test-Path -LiteralPath (Join-Path $c 'sh2nr-install.json'))) { $GamePath = $c; break }
    }
}
while (-not ($GamePath -and (Test-Path -LiteralPath (Join-Path $GamePath 'sh2pc.exe')))) {
    $GamePath = (Read-Host '  Paste the full path of your Silent Hill 2 folder').Trim().Trim('"')
    if (-not (Test-Path -LiteralPath (Join-Path $GamePath 'sh2pc.exe'))) { Say '  no sh2pc.exe there.' }
}
$GamePath = (Resolve-Path -LiteralPath $GamePath).Path
Say "  game folder: $GamePath"

$manifestPath = Join-Path $GamePath 'sh2nr-install.json'
$manifest = $null
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Ok "install record from $($manifest.installed)"
} else {
    Warn 'no sh2nr-install.json - falling back to the known file list and the newest .bak-sh2nr-* copies'
}

# ---------------------------------------------------------------- restore backups

Step 'Restoring the files SH2NR changed'
$restored = 0
if ($manifest -and $manifest.PSObject.Properties.Name -contains 'backups' -and $manifest.backups) {
    foreach ($b in $manifest.backups) {
        if (Test-Path -LiteralPath $b.backup) {
            Copy-Item -LiteralPath $b.backup -Destination $b.original -Force
            Remove-Item -LiteralPath $b.backup -Force
            Ok (Split-Path -Leaf $b.original)
            $restored++
        }
    }
} else {
    foreach ($name in @('d3d8.ini', 'settings.ini', 'ReShade.ini', 'ReShadePreset.ini', 'sh2nr.ini')) {
        $bak = Get-ChildItem -LiteralPath $GamePath -Filter "$name.bak-sh2nr-*" -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($bak) {
            Copy-Item -LiteralPath $bak.FullName -Destination (Join-Path $GamePath $name) -Force
            Ok "$name (from $($bak.Name))"
            $restored++
        }
    }
}
if ($restored -eq 0) {
    Warn 'nothing to restore; setting d3d8.ini back to the Enhanced Edition defaults instead'
    $d3d8ini = Join-Path $GamePath 'd3d8.ini'
    if (Test-Path -LiteralPath $d3d8ini) {
        $b = [System.IO.File]::ReadAllText($d3d8ini)
        $b = [regex]::Replace($b, '(?m)^\s*d3d8to9\s*=.*$', 'd3d8to9=1')
        $b = [regex]::Replace($b, '(?m)^\s*LoadD3d8FromScriptsFolder\s*=.*$', 'LoadD3d8FromScriptsFolder=0')
        [System.IO.File]::WriteAllText($d3d8ini, $b, (New-Object System.Text.ASCIIEncoding))
        Ok 'd3d8.ini: d3d8to9=1, LoadD3d8FromScriptsFolder=0'
    }
}

# ---------------------------------------------------------------- remove our files

Step 'Removing SH2NR'
$ours = @('sh2nr.addon32', 'sh2nr_feeder.exe', 'sh2nr-source.zip', 'sh2nr-install.json',
          'sh2nr_addon.log', 'sh2nr_feeder.log', 'dgVoodoo.conf', 'scripts\dgVoodoo.conf', 'scripts\D3D8.dll')
foreach ($f in $ours) {
    $p = Join-Path $GamePath $f
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Ok $f }
}
Get-ChildItem -LiteralPath $GamePath -Filter 'sh2nr*.log' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
Warn 'sh2nr.ini kept, in case you want your tuning back later'

if ($RemoveRuntime) {
    Step 'Removing the neural runtime'
    foreach ($f in @('LmxxfNrRuntime.dll', 'LmxxfNrRuntime.pak',
                     'amd_fidelityfx_loader_dx12.dll', 'amd_fidelityfx_upscaler_dx12.dll')) {
        $p = Join-Path $GamePath $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Ok $f }
    }
}

if ($RemoveReShade) {
    Step 'Removing ReShade'
    foreach ($f in @('dxgi.dll', 'ReShade.ini', 'ReShadePreset.ini', 'ReShade.log')) {
        $p = Join-Path $GamePath $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Ok $f }
    }
    $sh = Join-Path $GamePath 'reshade-shaders'
    if (Test-Path -LiteralPath $sh) { Remove-Item -LiteralPath $sh -Recurse -Force; Ok 'reshade-shaders\' }
}

Say ''
Say '  Done. Silent Hill 2 is back on the Enhanced Edition''s own renderer.'
if (-not $RemoveRuntime) { Say '  The neural runtime is still there (-RemoveRuntime to delete it).' }
if (-not $RemoveReShade) { Say '  ReShade is still there (-RemoveReShade to delete it).' }
Say ''
