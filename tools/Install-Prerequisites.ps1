<#
.SYNOPSIS
  Installs the programs ArcadeMaster needs on a cabinet, so every cabinet builds its own RetroFE from main (James,
  2026-11-26: no ready-made RetroFE packages from the NAS). Whatever is already there is left alone.
    Git                    winget Git.Git (the launcher installs it itself before cloning; checked again here)
    GitHub CLI             winget GitHub.cli (pull requests from the cabinet's own session)
    PowerShell 7           winget Microsoft.PowerShell (the RetroFE build and several tools run best under pwsh 7)
    Python 3.12 + Pillow   winget Python.Python.3.12 (machine-wide), then pip install pillow (cards, art, previews)
    VS 2022 Build Tools    winget Microsoft.VisualStudio.2022.BuildTools with the C++ workload (compiles RetroFE).
                           Windows asks once ("allow it to make changes?") - answer Yes on the cabinet.
    GStreamer 1.24.13      the MSVC runtime + devel MSIs from gstreamer.freedesktop.org, UNPACKED (msiexec /a, nothing
                           installed into Windows) into <ToolsRoot>\gstreamer; the downloads are deleted afterwards.
    ffmpeg                 winget Gyan.FFmpeg (the menu preview clips, New-PreviewMedia.py)
  -Runtime (a release install, Install.ps1): only Python + Pillow and ffmpeg - RetroFE comes prebuilt in the release.
  -Check only reports. AM_SYSTEM_DRYRUN=1 reports what it would install, like the other system tools (docs/08).
  Every line it prints starts with ok / installed / missing / would install / FAILED, so the launcher's log reads well.
.EXAMPLE
  tools\Install-Prerequisites.ps1 -Check
  tools\Install-Prerequisites.ps1 -ToolsRoot D:\ArcadeMaster\_tools
#>
param(
  [string]$ToolsRoot = 'D:\ArcadeMaster\_tools',
  [switch]$Check,
  [switch]$Runtime        # a release install: only what the tools need to RUN (Python + Pillow, ffmpeg) - no compiler, no git
)
$ErrorActionPreference = 'Continue'
$dry = $Check -or $env:AM_SYSTEM_DRYRUN -eq '1'
$gstVer = '1.24.13'
$gstUrl = "https://gstreamer.freedesktop.org/data/pkg/windows/$gstVer/msvc"
$failed = 0

function Update-Path { $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User') }
function Find-Exe([string]$name, [string[]]$paths) {
  foreach ($p in $paths) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
  $c = Get-Command $name -ErrorAction SilentlyContinue | Where-Object { $_.Source -notlike '*\WindowsApps\python*' } | Select-Object -First 1   # the Store's python stub is not Python
  if ($c) { return $c.Source }
  return $null
}
$wingetLinks = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'
$winget = Find-Exe 'winget' @((Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'))

function Invoke-Winget([string]$id, [string]$what, [string[]]$extra) {
  if ($dry) { Write-Host "would install  $what (winget $id)"; return $true }
  if (-not $winget) { Write-Host "FAILED     $what - winget is missing (install 'App Installer' from the Microsoft Store)"; $script:failed++; return $false }
  Write-Host "installing $what (winget $id) ..."
  $a = @('install', '--id', $id, '-e', '--silent', '--accept-package-agreements', '--accept-source-agreements') + $extra
  $o = & $winget @a 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE
  Update-Path
  # 0 = installed; -1978335189 (0x8A15002B) = already installed / no newer version
  if ($code -eq 0 -or $code -eq -1978335189) { Write-Host "installed  $what"; return $true }
  # the last real lines, without winget's spinner and progress bar (block characters, "12.3 MB / 98.0 MB")
  $last = @($o | Where-Object { $_ -match '[A-Za-z]{3}' -and $_ -notmatch '\d+(\.\d+)?\s*[KMG]B\s*/' }) | Select-Object -Last 2
  $hint = if ($code -eq 1602 -or ($o -join ' ') -match '1602') { ' - Windows asked for permission and it was not given: run setup again and answer Yes' } else { '' }
  Write-Host "FAILED     $what (winget exit $code)$hint $(($last -join ' | '))"
  $script:failed++; return $false
}

if (-not $Runtime) {
# --- Git
$git = Find-Exe 'git' @('C:\Program Files\Git\cmd\git.exe', (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe'))
if ($git) { Write-Host "ok         Git ($git)" } else { [void](Invoke-Winget 'Git.Git' 'Git' @()) }

# --- GitHub CLI
$gh = Find-Exe 'gh' @('C:\Program Files\GitHub CLI\gh.exe')
if ($gh) { Write-Host "ok         GitHub CLI ($gh)" } else { [void](Invoke-Winget 'GitHub.cli' 'GitHub CLI' @()) }

# --- PowerShell 7
$pwsh = Find-Exe 'pwsh' @('C:\Program Files\PowerShell\7\pwsh.exe')
if ($pwsh) { Write-Host "ok         PowerShell 7 ($pwsh)" } else { [void](Invoke-Winget 'Microsoft.PowerShell' 'PowerShell 7' @()) }

}   # -Runtime: no git, gh, pwsh 7

# --- Python 3.12 + Pillow
$py = Find-Exe 'python' @('C:\Program Files\Python312\python.exe', (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'))
if (-not $py) {
  if (Invoke-Winget 'Python.Python.3.12' 'Python 3.12' @('--scope', 'machine')) { $py = Find-Exe 'python' @('C:\Program Files\Python312\python.exe') }
} else { Write-Host "ok         Python ($py)" }
if ($py) {
  $pil = & $py -c "import PIL; print(PIL.__version__)" 2>$null
  if ($LASTEXITCODE -eq 0 -and $pil) { Write-Host "ok         Pillow $pil" }
  elseif ($dry) { Write-Host 'would install  Pillow (pip)' }
  else {
    & $py -m pip install --quiet --disable-pip-version-check pillow 2>&1 | Out-Null
    $pil = & $py -c "import PIL; print(PIL.__version__)" 2>$null
    if ($LASTEXITCODE -eq 0 -and $pil) { Write-Host "installed  Pillow $pil" } else { Write-Host 'FAILED     Pillow (pip install pillow)'; $failed++ }
  }
}

if (-not $Runtime) {
# --- Visual Studio 2022 Build Tools with C++ (any edition with the MSVC x64 tools counts)
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vs = if (Test-Path $vswhere) { & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath 2>$null | Select-Object -First 1 } else { $null }
if ($vs) { Write-Host "ok         Visual Studio C++ build tools ($vs)" }
else {
  Write-Host 'note       Visual Studio Build Tools: Windows will ask for permission - answer Yes on the cabinet (about 10-20 minutes)'
  [void](Invoke-Winget 'Microsoft.VisualStudio.2022.BuildTools' 'Visual Studio 2022 Build Tools (C++)' @('--override', '--wait --quiet --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'))
}

# --- GStreamer, unpacked (not installed) next to the other tools
$gstDir = Join-Path $ToolsRoot 'gstreamer'
$gstKit = [IO.Path]::Combine($gstDir, 'gstreamer', '1.0', 'msvc_x86_64')   # not Join-Path: 5.1 throws on a missing drive
if (Test-Path ([IO.Path]::Combine($gstKit, 'include'))) { Write-Host "ok         GStreamer $gstVer kit ($gstKit)" }
elseif (Test-Path 'C:\gstreamer\1.0\msvc_x86_64\include') { Write-Host 'ok         GStreamer kit (C:\gstreamer\1.0\msvc_x86_64)' }
elseif ($dry) { Write-Host "would install  GStreamer $gstVer (runtime + devel, unpacked into $gstDir)" }
else {
  $dl = Join-Path $ToolsRoot "downloads\gstreamer-$gstVer"
  New-Item -ItemType Directory -Force $dl, $gstDir | Out-Null
  $ok = $true
  foreach ($f in "gstreamer-1.0-msvc-x86_64-$gstVer.msi", "gstreamer-1.0-devel-msvc-x86_64-$gstVer.msi") {
    Write-Host "downloading $f ..."
    & curl.exe -fsSL -o (Join-Path $dl $f) "$gstUrl/$f" 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Host "FAILED     GStreamer download ($f, curl exit $LASTEXITCODE)"; $ok = $false; break }
    $p = Start-Process msiexec.exe -ArgumentList "/a `"$(Join-Path $dl $f)`" /qn TARGETDIR=`"$gstDir`"" -Wait -PassThru
    if ($p.ExitCode -ne 0) { Write-Host "FAILED     GStreamer unpack ($f, msiexec exit $($p.ExitCode))"; $ok = $false; break }
  }
  if ($ok -and (Test-Path ([IO.Path]::Combine($gstKit, 'include')))) { Write-Host "installed  GStreamer $gstVer kit ($gstKit)"; Remove-Item $dl -Recurse -Force -ErrorAction SilentlyContinue }
  else { if ($ok) { Write-Host "FAILED     GStreamer: unpacked, but $gstKit\include is missing" }; $failed++ }
}

}   # -Runtime: a release ships RetroFE built - no compiler, no GStreamer kit

# --- ffmpeg (winget puts it under its Packages folder and a link in WinGet\Links)
$ffPkg = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Directory -Filter 'Gyan.FFmpeg*' -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem $_.FullName -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue } | Select-Object -First 1
$ff = Find-Exe 'ffmpeg' @((Join-Path $wingetLinks 'ffmpeg.exe'), $(if ($ffPkg) { $ffPkg.FullName }))
if ($ff) { Write-Host "ok         ffmpeg ($ff)" } else { [void](Invoke-Winget 'Gyan.FFmpeg' 'ffmpeg' @()) }

if ($failed) { Write-Host "prerequisites: $failed FAILED - see the lines above"; exit 1 }
Write-Host $(if ($dry) { 'prerequisites: checked (nothing installed)' } else { 'prerequisites: all in place' })
exit 0
