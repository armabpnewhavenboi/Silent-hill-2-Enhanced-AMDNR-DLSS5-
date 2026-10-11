<#
    SH2NR installer - AMD neural rendering (DLSS 5 style) for Silent Hill 2 (2001) Enhanced Edition
    SPDX-License-Identifier: GPL-3.0-or-later

    Run install.cmd in the folder above this one. Nothing here needs admin rights.

    What this does, in order:
      1. finds the game and checks the Enhanced Edition is installed
      2. backs up every file it is about to change
      3. copies the neural runtime (LmxxfNrRuntime.dll/.pak) from your AMDNR install
      4. puts dgVoodoo2's D3D8.dll in scripts\  (DirectX 8 -> Direct3D 11)
      5. installs ReShade with add-on support and the iMMERSE shaders
      6. copies sh2nr.addon32 + sh2nr_feeder.exe and writes the config
      7. prints a checklist of what is done and what is not
    It can be run again any time; it only redoes the parts that are missing.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    # Game folder (the one with sh2pc.exe). Found automatically if you leave it out.
    [string] $GamePath,
    # Folder or .zip holding LmxxfNrRuntime.dll + LmxxfNrRuntime.pak (your AMDNR install).
    [string] $RuntimeSource,
    # Skip the ReShade step (use when you already have ReShade with add-on support).
    [switch] $SkipReShade,
    # Do not enable MXAO (ambient occlusion). Leave it on unless depth is broken in your setup.
    [switch] $NoMXAO,
    # Overwrite an existing sh2nr.ini with the shipped defaults.
    [switch] $ResetConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root        = Split-Path -Parent $PSScriptRoot
$PayloadDir  = Join-Path $Root 'payload'
$LicenseDir  = Join-Path $Root 'Licenses'
$SourceDir   = Join-Path $Root 'source'
$Stamp       = Get-Date -Format 'yyyyMMdd-HHmmss'
$Work        = Join-Path $env:TEMP "sh2nr-install-$Stamp"
$Script:Done    = New-Object System.Collections.ArrayList
$Script:Pending = New-Object System.Collections.ArrayList
$Script:Added   = New-Object System.Collections.ArrayList
$Script:Backups = New-Object System.Collections.ArrayList

# ---------------------------------------------------------------- output helpers

function Say    ($m) { Write-Host $m }
function Step   ($m) { Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Ok     ($m) { Write-Host "    [ok]   $m" -ForegroundColor Green;  [void]$Script:Done.Add($m) }
function Warn   ($m) { Write-Host "    [note] $m" -ForegroundColor Yellow }
function Todo   ($m) { Write-Host "    [todo] $m" -ForegroundColor Magenta; [void]$Script:Pending.Add($m) }
function Die    ($m) { Write-Host ''; Write-Host "STOPPED: $m" -ForegroundColor Red; Write-Host ''; exit 1 }

function Ask ($prompt, $default) {
    if ($default) { $a = Read-Host "$prompt [$default]"; if ([string]::IsNullOrWhiteSpace($a)) { return $default } ; return $a }
    return Read-Host $prompt
}
function AskYesNo ($prompt, $defaultYes = $true) {
    $hint = if ($defaultYes) { 'Y/n' } else { 'y/N' }
    $a = Read-Host "$prompt ($hint)"
    if ([string]::IsNullOrWhiteSpace($a)) { return $defaultYes }
    return $a -match '^(y|yes)$'
}

# ---------------------------------------------------------------- file helpers

# .ini files are written as plain ASCII on purpose: a UTF-8 byte-order mark
# makes the first key unreadable to the add-on and to the game's own parser.
function WriteText ($path, $text) {
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.ASCIIEncoding))
}
function ReadText ($path) { [System.IO.File]::ReadAllText($path) }

function Backup ($path) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $bak = "$path.bak-sh2nr-$Stamp"
    Copy-Item -LiteralPath $path -Destination $bak -Force
    [void]$Script:Backups.Add(@{ original = $path; backup = $bak })
}

function Install ($sourceFile, $destFile) {
    $dir = Split-Path -Parent $destFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $sourceFile -Destination $destFile -Force
    [void]$Script:Added.Add($destFile)
}

# Set key=value in an ini body, keeping the rest of the file byte-for-byte.
function SetIniKey ([string]$body, [string]$key, [string]$value) {
    $rx = "(?m)^\s*$([regex]::Escape($key))\s*=.*$"
    if ([regex]::IsMatch($body, $rx)) { return [regex]::Replace($body, $rx, "$key=$value") }
    return $body.TrimEnd() + "`r`n$key=$value`r`n"
}

# Replace only if the key is already there. Appending would land it in whatever
# [section] happens to be last in the file, which is worse than leaving it alone.
function SetIniKeyIfPresent ([string]$body, [string]$key, [string]$value) {
    $rx = "(?m)^\s*$([regex]::Escape($key))\s*=.*$"
    if ([regex]::IsMatch($body, $rx)) { return [regex]::Replace($body, $rx, "$key=$value") }
    return $body
}

# Searches a binary for a marker string. DLL version info is UTF-16, exported
# symbol names are ASCII, so both encodings are checked (and both UTF-16
# alignments, since the resource section is not guaranteed to land on an even
# file offset).
function FileHasString ([string]$path, [string[]]$needles) {
    try {
        $bytes  = [System.IO.File]::ReadAllBytes($path)
        $views  = @(
            [System.Text.Encoding]::GetEncoding(28591).GetString($bytes),
            [System.Text.Encoding]::Unicode.GetString($bytes),
            [System.Text.Encoding]::Unicode.GetString($bytes, 1, $bytes.Length - 1)
        )
        foreach ($v in $views) {
            foreach ($n in $needles) {
                if ($v.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
            }
        }
        return $false
    } catch { return $false }
}

# Windows parses the version resource properly, so ask it first.
function VersionInfoMentions ([string]$path, [string]$needle) {
    try {
        $vi = (Get-Item -LiteralPath $path).VersionInfo
        foreach ($field in @($vi.FileDescription, $vi.CompanyName, $vi.ProductName, $vi.InternalName)) {
            if ($field -and $field -match [regex]::Escape($needle)) { return $true }
        }
    } catch { }
    return $false
}

# The add-on build exports ReShadeRegisterAddon; the plain build does not. That
# export is the only reliable way to tell the two apart from the file alone
# (verified against ReShade 6.8.0: the snake_case name add-ons use in their own
# source does not appear in the DLL at all).
function IsAddonReShade ([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    return (FileHasString $path @('ReShadeRegisterAddon', 'ReShadeRegisterEvent'))
}

function IsDgVoodoo ([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $false }
    if (VersionInfoMentions $path 'dgVoodoo') { return $true }
    return (FileHasString $path @('dgVoodoo'))
}

function Download ($url, $outFile) {
    Say "       downloading $url"
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'sh2nr-installer')
        $wc.DownloadFile($url, $outFile)
        return (Test-Path -LiteralPath $outFile)
    } catch {
        Warn "download failed: $($_.Exception.Message)"
        return $false
    }
}

function FindFirstFile ($roots, $pattern, $depth = 3) {
    foreach ($r in $roots) {
        if (-not $r -or -not (Test-Path -LiteralPath $r)) { continue }
        try {
            $hit = Get-ChildItem -LiteralPath $r -Filter $pattern -Recurse -Depth $depth -File -ErrorAction SilentlyContinue |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($hit) { return $hit.FullName }
        } catch { }
    }
    return $null
}

# ================================================================ banner

Clear-Host
Say ''
Say '  SH2NR - AMD neural rendering for Silent Hill 2 (2001) Enhanced Edition'
Say '  ======================================================================'
Say '  Runs the DLSS 5 Neural Rendering network on a Radeon RX 9000 card,'
Say '  inside a 25-year-old 32-bit DirectX 8 game.'
Say ''
Say '  Nothing is overwritten without a .bak-sh2nr-<date> copy beside it.'
Say ''

if (-not (Test-Path -LiteralPath $PayloadDir)) {
    Die "payload folder not found next to this script. Extract the whole download, do not run install.ps1 on its own."
}
New-Item -ItemType Directory -Path $Work -Force | Out-Null

# ================================================================ 1. the game

Step 'Looking for Silent Hill 2'

function LooksLikeGame ($p) {
    if (-not $p) { return $false }
    return (Test-Path -LiteralPath (Join-Path $p 'sh2pc.exe'))
}

if (-not (LooksLikeGame $GamePath)) {
    $guesses = New-Object System.Collections.ArrayList
    # the most likely case: this archive was extracted into the game folder
    [void]$guesses.Add($Root)
    [void]$guesses.Add((Split-Path -Parent $Root))
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
        $r = $d.RootDirectory.FullName
        foreach ($sub in @('Silent Hill 2', 'Games\Silent Hill 2', 'GOG Games\Silent Hill 2',
                           'Program Files (x86)\Silent Hill 2', 'SH2', 'Games\SH2')) {
            [void]$guesses.Add((Join-Path $r $sub))
        }
    }
    foreach ($g in $guesses) { if (LooksLikeGame $g) { $GamePath = (Resolve-Path -LiteralPath $g).Path; break } }
}

while (-not (LooksLikeGame $GamePath)) {
    Warn 'could not find sh2pc.exe on its own.'
    $GamePath = Ask '    Paste the full path of your Silent Hill 2 folder'
    $GamePath = $GamePath.Trim().Trim('"')
    if (-not (LooksLikeGame $GamePath)) { Say "    no sh2pc.exe in '$GamePath'" }
}
$GamePath = (Resolve-Path -LiteralPath $GamePath).Path
Ok "game folder: $GamePath"

# write test - a Program Files install needs admin or a move
$probe = Join-Path $GamePath ".sh2nr-write-test"
try { WriteText $probe 'x'; Remove-Item -LiteralPath $probe -Force }
catch { Die "cannot write to '$GamePath'. Run install.cmd as administrator, or move the game out of Program Files." }

Step 'Checking the Enhanced Edition'
$d3d8ini = Join-Path $GamePath 'd3d8.ini'
if (-not (Test-Path -LiteralPath $d3d8ini)) {
    Say ''
    Say '    This needs the Silent Hill 2 Enhanced Edition on top of the retail game.'
    Say '    Get it from https://enhanced.townofsilenthill.com  (install it, run it once, then come back).'
    Die 'Enhanced Edition not found (no d3d8.ini in the game folder).'
}
Ok 'Enhanced Edition present'

Step 'Checking the graphics card'
try {
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | Select-Object -ExpandProperty Name)
    $amd  = @($gpus | Where-Object { $_ -match 'Radeon|AMD' })
    $rdna4 = @($gpus | Where-Object { $_ -match 'RX\s*9[0-9]{3}' })
    if ($rdna4.Count -gt 0)  { Ok "$($rdna4[0]) - the card this is built for" }
    elseif ($amd.Count -gt 0) {
        Warn "$($amd[0]) - not an RX 9000. The neural runtime targets RDNA 4; AMDNR has an RDNA 3"
        Warn 'backend but this build is only tested on a 9070 XT. It may be slow or may not start.'
    } else {
        Warn "no AMD card detected ($($gpus -join ', ')). This will not work on NVIDIA or Intel."
        if (-not (AskYesNo '    Carry on anyway?' $false)) { Die 'stopped at your request.' }
    }
} catch { Warn 'could not read the graphics card list; carrying on.' }

# ================================================================ 2. the neural runtime

Step 'Neural runtime (LmxxfNrRuntime.dll + .pak)'

$runtimeFiles = @('LmxxfNrRuntime.dll', 'LmxxfNrRuntime.pak')
$needRuntime  = $false
foreach ($f in $runtimeFiles) { if (-not (Test-Path -LiteralPath (Join-Path $GamePath $f))) { $needRuntime = $true } }

function ValidPak ($path) {
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $buf = New-Object byte[] 8
            [void]$fs.Read($buf, 0, 8)
            return ([System.Text.Encoding]::ASCII.GetString($buf) -eq 'LMXXFPK1')
        } finally { $fs.Dispose() }
    } catch { return $false }
}

if (-not $needRuntime) {
    if (ValidPak (Join-Path $GamePath 'LmxxfNrRuntime.pak')) { Ok 'already in the game folder' }
    else { Warn 'LmxxfNrRuntime.pak is there but does not look valid; replacing it'; $needRuntime = $true }
}

if ($needRuntime) {
    $found = $null
    $searchRoots = New-Object System.Collections.ArrayList
    if ($RuntimeSource) { [void]$searchRoots.Add($RuntimeSource) }
    foreach ($p in @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Documents")) {
        [void]$searchRoots.Add($p)
    }
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if ($d.DriveType -ne 'Fixed' -or -not $d.IsReady) { continue }
        foreach ($n in @('AMDNR', 'AMD-NR', 'OptiScaler', 'Games')) {
            [void]$searchRoots.Add((Join-Path $d.RootDirectory.FullName $n))
        }
    }

    # a .zip passed with -RuntimeSource
    if ($RuntimeSource -and (Test-Path -LiteralPath $RuntimeSource) -and $RuntimeSource -match '\.zip$') {
        $ex = Join-Path $Work 'runtimezip'
        Expand-Archive -LiteralPath $RuntimeSource -DestinationPath $ex -Force
        $found = FindFirstFile @($ex) 'LmxxfNrRuntime.pak' 4
    }
    if (-not $found) { $found = FindFirstFile $searchRoots 'LmxxfNrRuntime.pak' 3 }

    while (-not $found) {
        Say ''
        Say '    The network weights cannot be shipped here: they are derived from NVIDIA''s'
        Say '    DLSS files and belong to NVIDIA. You need them from AMDNR, which is free:'
        Say ''
        Say '      https://github.com/3zwr1/AMD-NR---OptiScaler'
        Say ''
        Say '    Download its package (0.3.5.4 or newer), unzip it anywhere, and give me the'
        Say '    folder. The two files needed are LmxxfNrRuntime.dll and LmxxfNrRuntime.pak'
        Say '    (the .pak is about 500 MB).'
        Say ''
        $ans = Ask '    Folder or .zip holding them (or "skip")'
        $ans = $ans.Trim().Trim('"')
        if ($ans -eq 'skip') { break }
        if (Test-Path -LiteralPath $ans) {
            if ($ans -match '\.zip$') {
                $ex = Join-Path $Work ("rt-" + [guid]::NewGuid().ToString('N').Substring(0,6))
                Expand-Archive -LiteralPath $ans -DestinationPath $ex -Force
                $found = FindFirstFile @($ex) 'LmxxfNrRuntime.pak' 4
            } else {
                $found = FindFirstFile @($ans) 'LmxxfNrRuntime.pak' 4
            }
            if (-not $found) { Say '    no LmxxfNrRuntime.pak in there.' }
        } else { Say '    that path does not exist.' }
    }

    if ($found) {
        $srcDir = Split-Path -Parent $found
        $dll    = Join-Path $srcDir 'LmxxfNrRuntime.dll'
        if (-not (Test-Path -LiteralPath $dll)) {
            Todo "found the .pak but not LmxxfNrRuntime.dll beside it - copy both from your AMDNR folder by hand"
        } elseif (-not (ValidPak $found)) {
            Todo 'that .pak does not start with LMXXFPK1 - it is not the runtime pack'
        } else {
            Say '       copying about 500 MB, this takes a moment...'
            Install $dll   (Join-Path $GamePath 'LmxxfNrRuntime.dll')
            Install $found (Join-Path $GamePath 'LmxxfNrRuntime.pak')
            Ok "copied from $srcDir"
        }
        # FSR 4 comes from the same package
        foreach ($f in @('amd_fidelityfx_loader_dx12.dll', 'amd_fidelityfx_upscaler_dx12.dll')) {
            $dest = Join-Path $GamePath $f
            if (Test-Path -LiteralPath $dest) { continue }
            $hit = FindFirstFile @($srcDir, (Split-Path -Parent $srcDir)) $f 3
            if ($hit) { Install $hit $dest; Ok "FSR 4: $f" }
        }
    } else {
        Todo 'neural runtime missing - the game will run, but neural rendering will not start'
    }
}

foreach ($f in @('amd_fidelityfx_loader_dx12.dll', 'amd_fidelityfx_upscaler_dx12.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $GamePath $f))) {
        Warn "$f not found - FSR will be off (set Upscaler=native in sh2nr.ini)"
    }
}

# ================================================================ 3. dgVoodoo2

Step 'dgVoodoo2 (DirectX 8 -> Direct3D 11)'

$scripts   = Join-Path $GamePath 'scripts'
$dgvTarget = Join-Path $scripts 'D3D8.dll'
if (-not (Test-Path -LiteralPath $scripts)) { New-Item -ItemType Directory -Path $scripts -Force | Out-Null }

if (IsDgVoodoo $dgvTarget) {
    Ok 'already in scripts\'
} else {
    $zip = $null
    foreach ($r in @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop")) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $hit = Get-ChildItem -LiteralPath $r -Filter 'dgVoodoo2*.zip' -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { $zip = $hit.FullName; break }
    }
    while (-not $zip) {
        Say ''
        Say '    dgVoodoo2 is what lets a DirectX 8 game reach a modern Radeon. Its author asks'
        Say '    that it be downloaded from his own site rather than repacked, so:'
        Say ''
        Say '      https://dege.freeweb.hu/dgVoodoo2/Downloads/'
        Say ''
        Say '    Download the latest dgVoodoo2_xx.zip into your Downloads folder.'
        Say ''
        if (AskYesNo '    Open that page now?' $true) { Start-Process 'https://dege.freeweb.hu/dgVoodoo2/Downloads/' | Out-Null }
        $ans = Ask '    Press Enter when the zip is in Downloads (or paste its path, or "skip")'
        $ans = $ans.Trim().Trim('"')
        if ($ans -eq 'skip') { break }
        if ($ans -and (Test-Path -LiteralPath $ans)) { $zip = $ans; break }
        $hit = Get-ChildItem -LiteralPath "$env:USERPROFILE\Downloads" -Filter 'dgVoodoo2*.zip' -File -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { $zip = $hit.FullName }
    }

    if ($zip) {
        $ex = Join-Path $Work 'dgv'
        Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
        # the 32-bit build lives in MS\x86
        $cand = Get-ChildItem -LiteralPath $ex -Filter 'D3D8.dll' -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '[\\/]x86[\\/]' } | Select-Object -First 1
        if (-not $cand) {
            $cand = Get-ChildItem -LiteralPath $ex -Filter 'D3D8.dll' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if ($cand) {
            Install $cand.FullName $dgvTarget
            Ok "installed from $(Split-Path -Leaf $zip) ($($cand.FullName -replace [regex]::Escape($ex),''))"
        } else { Todo 'no 32-bit D3D8.dll inside that zip - check it is the dgVoodoo2 package' }
    } else {
        Todo 'dgVoodoo2 missing - put its MS\x86\D3D8.dll into the game''s scripts\ folder'
    }
}

# dgVoodoo settings: Direct3D 11 out, watermark off, 4 GB addressable so 1440p render targets fit
$dgvConf = Join-Path $PayloadDir 'dgVoodoo.conf'
if (Test-Path -LiteralPath $dgvConf) {
    foreach ($dest in @((Join-Path $GamePath 'dgVoodoo.conf'), (Join-Path $scripts 'dgVoodoo.conf'))) {
        if (-not (Test-Path -LiteralPath $dest)) { Install $dgvConf $dest }
    }
    Ok 'dgVoodoo.conf written'
}

# ================================================================ 4. ReShade + shaders

Step 'ReShade with add-on support'

$dxgi = Join-Path $GamePath 'dxgi.dll'
$haveAddonReShade = IsAddonReShade $dxgi

if ($SkipReShade) {
    Warn 'skipped at your request'
} elseif ($haveAddonReShade) {
    Ok 'already installed (add-on build)'
} else {
    if (Test-Path -LiteralPath $dxgi) {
        Warn 'dxgi.dll is there but is not an add-on build - the add-on cannot load into it.'
        Warn 'Reinstall ReShade and pick the download "with full add-on support".'
    }
    Say ''
    Say '    ReShade must be the build "with full add-on support" (the normal one will not do).'
    Say '    Its installer is interactive, so this will open it for you. In the window:'
    Say ''
    Say "      1. Browse to  $GamePath\sh2pc.exe"
    Say '      2. Rendering API: DirectX 10/11/12'
    Say '      3. Effect packages: tick "iMMERSE by Marty McFly" (that is where Launchpad lives)'
    Say '      4. Finish, then close the installer'
    Say ''
    $setup = Join-Path $Work 'ReShade_Setup_Addon.exe'
    $got = $false
    foreach ($u in @('https://reshade.me/downloads/ReShade_Setup_6.8.0_Addon.exe',
                     'https://reshade.me/downloads/ReShade_Setup_6.7.0_Addon.exe')) {
        if (Download $u $setup) { $got = $true; break }
    }
    if (-not $got) {
        $local = FindFirstFile @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop") 'ReShade_Setup*Addon*.exe' 1
        if ($local) { Copy-Item -LiteralPath $local -Destination $setup -Force; $got = $true }
    }
    if ($got) {
        if (AskYesNo '    Open the ReShade installer now?' $true) {
            try { Start-Process -FilePath $setup -ArgumentList "`"$(Join-Path $GamePath 'sh2pc.exe')`"" -Wait }
            catch { Start-Process -FilePath $setup -Wait }
        }
        if (IsAddonReShade $dxgi) {
            Ok 'ReShade with add-on support installed'
            $haveAddonReShade = $true
        } else {
            Todo 'ReShade add-on build still not detected - run its installer again and pick DirectX 10/11/12'
        }
    } else {
        Say '    Could not download it. Get it yourself from https://reshade.me  (the add-on download),'
        Say '    run it against sh2pc.exe, then run this installer again.'
        Todo 'ReShade with add-on support not installed'
    }
}

Step 'iMMERSE Launchpad (motion vectors)'
$shaderDir  = Join-Path $GamePath 'reshade-shaders\Shaders'
$textureDir = Join-Path $GamePath 'reshade-shaders\Textures'
$launchpad  = Join-Path $shaderDir 'MartysMods_LAUNCHPAD.fx'

if (Test-Path -LiteralPath $launchpad) {
    Ok 'already installed'
} else {
    $zip = Join-Path $Work 'immerse.zip'
    if (Download 'https://github.com/martymcmodding/iMMERSE/archive/refs/heads/main.zip' $zip) {
        $ex = Join-Path $Work 'immerse'
        Expand-Archive -LiteralPath $zip -DestinationPath $ex -Force
        $srcShaders = Get-ChildItem -LiteralPath $ex -Directory | Select-Object -First 1
        if ($srcShaders) {
            foreach ($pair in @(@('Shaders', $shaderDir), @('Textures', $textureDir))) {
                $from = Join-Path $srcShaders.FullName $pair[0]
                if (-not (Test-Path -LiteralPath $from)) { continue }
                if (-not (Test-Path -LiteralPath $pair[1])) { New-Item -ItemType Directory -Path $pair[1] -Force | Out-Null }
                Get-ChildItem -LiteralPath $from -File -Recurse | ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $pair[1] $_.Name) -Force
                }
            }
        }
    }
    if (Test-Path -LiteralPath $launchpad) { Ok 'installed from martymcmodding/iMMERSE' }
    else { Todo 'Launchpad missing - tick "iMMERSE by Marty McFly" in ReShade''s installer, or copy its Shaders folder in' }
}

# ================================================================ 5. SH2NR itself

Step 'SH2NR'

Install (Join-Path $PayloadDir 'sh2nr.addon32')   (Join-Path $GamePath 'sh2nr.addon32')
Install (Join-Path $PayloadDir 'sh2nr_feeder.exe') (Join-Path $GamePath 'sh2nr_feeder.exe')
Ok 'add-on and feeder copied'

$iniDest = Join-Path $GamePath 'sh2nr.ini'
if ((Test-Path -LiteralPath $iniDest) -and -not $ResetConfig) {
    Ok 'sh2nr.ini kept (your own settings); run with -ResetConfig to replace it'
} else {
    if (Test-Path -LiteralPath $iniDest) { Backup $iniDest }
    Install (Join-Path $PayloadDir 'sh2nr.ini') $iniDest
    Ok 'sh2nr.ini written (tuned defaults)'
}

if (Test-Path -LiteralPath $LicenseDir) {
    $destLic = Join-Path $GamePath 'Licenses'
    if (-not (Test-Path -LiteralPath $destLic)) { New-Item -ItemType Directory -Path $destLic -Force | Out-Null }
    Get-ChildItem -LiteralPath $LicenseDir -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $destLic $_.Name) -Force
    }
    Ok 'licence notices copied'
}
if (Test-Path -LiteralPath (Join-Path $SourceDir 'sh2nr-source.zip')) {
    Install (Join-Path $SourceDir 'sh2nr-source.zip') (Join-Path $GamePath 'sh2nr-source.zip')
}

# ================================================================ 6. game configuration

Step 'Game configuration'

# d3d8.ini: hand DirectX 8 to dgVoodoo in scripts\ instead of the EE's own d3d8to9 path
Backup $d3d8ini
$body = ReadText $d3d8ini
$body = SetIniKey $body 'd3d8to9' '0'
$body = SetIniKey $body 'LoadD3d8FromScriptsFolder' '1'
WriteText $d3d8ini $body
Ok 'd3d8.ini: d3d8to9=0, LoadD3d8FromScriptsFolder=1'
Warn 'this turns off the EE extras marked "requires DirectX 9" (its SMAA, brightness selector)'

# the game's own film grain fights the network - it reads grain as skin and wall texture
$settings = Join-Path $GamePath 'settings.ini'
if (Test-Path -LiteralPath $settings) {
    $s = ReadText $settings
    if ([regex]::IsMatch($s, '(?m)^\s*NOISE\s*=')) {
        Backup $settings
        WriteText $settings (SetIniKey $s 'NOISE' '0')
        Ok 'settings.ini: NOISE=0 (film grain off)'
    }
}

# ReShade preset: Launchpad first (it must see the frame before anything changes it), then MXAO
$preset = Join-Path $GamePath 'ReShadePreset.ini'
$tech = 'MartysMods_Launchpad@MartysMods_LAUNCHPAD.fx'
if (-not $NoMXAO) { $tech += ',MartysMods_MXAO@MartysMods_MXAO.fx' }

if (Test-Path -LiteralPath $preset) {
    Backup $preset
    $p = ReadText $preset
    $p = SetIniKey $p 'Techniques' $tech
} else {
    $p = "Techniques=$tech`r`n"
}
foreach ($kv in @(@('MXAO_SSAO_AMOUNT','0.500000'), @('MXAO_SAMPLE_RADIUS','2.000000'),
                  @('MXAO_GLOBAL_SAMPLE_QUALITY_PRESET','2'), @('MXAO_FADE_DEPTH','0.400000'))) {
    $p = SetIniKeyIfPresent $p $kv[0] $kv[1]
}
if ($p -notmatch '(?m)^\[MartysMods_MXAO\.fx\]') {
    $p = $p.TrimEnd() + "`r`n`r`n[MartysMods_MXAO.fx]`r`nMXAO_SSAO_AMOUNT=0.500000`r`nMXAO_SAMPLE_RADIUS=2.000000`r`nMXAO_GLOBAL_SAMPLE_QUALITY_PRESET=2`r`nMXAO_FADE_DEPTH=0.400000`r`n"
}
WriteText $preset $p
Ok ('ReShade preset: Launchpad' + $(if ($NoMXAO) { '' } else { ' + MXAO' }) + ' enabled')

# ReShade.ini: point the effect search paths at the shaders we just installed
$rsIni = Join-Path $GamePath 'ReShade.ini'
if (Test-Path -LiteralPath $rsIni) {
    Backup $rsIni
    $r = ReadText $rsIni
    if ($r -notmatch 'reshade-shaders') {
        $r = SetIniKeyIfPresent $r 'EffectSearchPaths'  '.\reshade-shaders\Shaders\**'
        $r = SetIniKeyIfPresent $r 'TextureSearchPaths' '.\reshade-shaders\Textures\**'
        WriteText $rsIni $r
        Ok 'ReShade.ini: shader search paths set'
    }
}

# ================================================================ 7. manifest + summary

$manifest = @{
    version   = 1
    installed = $Stamp
    gamePath  = $GamePath
    added     = @($Script:Added)
    backups   = @($Script:Backups)
} | ConvertTo-Json -Depth 5
WriteText (Join-Path $GamePath 'sh2nr-install.json') $manifest

try { Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue } catch { }

Say ''
Say '  ======================================================================'
if ($Script:Pending.Count -eq 0) {
    Say '  Done. Everything is in place.' 
} else {
    Say '  Done, with things still to do:'
    foreach ($t in $Script:Pending) { Write-Host "    - $t" -ForegroundColor Magenta }
}
Say '  ======================================================================'
Say ''
Say '  Start the game, then:'
Say '    Home  - ReShade menu. MartysMods_Launchpad must be ON and at the TOP of the list.'
Say '    F9    - neural rendering on/off'
Say '    F10   - split screen: left original, right neural'
Say ''
Say '  First frame takes a few seconds while the network loads. Expect around 65 fps'
Say '  at 1440p on a 9070 XT. Settings live in sh2nr.ini and apply while the game runs.'
Say ''
Say '  Something wrong? sh2nr_addon.log and sh2nr_feeder.log in the game folder say why.'
Say "  To undo everything: uninstall.cmd"
Say ''
