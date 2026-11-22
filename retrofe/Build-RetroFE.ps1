<#
.SYNOPSIS
  Reproducible build of the ArcadeMaster RetroFE (CoinOPS-Official/RetroFE, branch `current`, pinned commit)
  plus a ready-to-run runtime folder.

  Steps
    1. clone the pinned commit (with the RetroFE-windows-deps submodule)
    2. apply retrofe\patches\*.patch (ArcadeMaster crash fixes)
    3. SDL include shim  (source uses <SDL2/SDL.h>; vendored ThirdParty headers are flat)
    4. CMake + MSVC x64 Release WITH symbols (/Zi + /DEBUG -> retrofe.pdb; crash logs resolve file:line)
    5. assemble <Out>\retrofe\ runtime:
         - GStreamer runtime that MATCHES the headers built against (deps submodule ships 1.22.7: mismatch => crashes)
         - gst-plugin-scanner.exe (plugins are probed out-of-process; a bad DLL can't take RetroFE down)
         - ThirdParty DLLs missing from the deps bundle (libusb, libserialport, libcurl, zlib)
         - EXCLUDES gstfrei0r.dll and PacDrive64.dll (both crash the in-folder plugin scan; nothing uses them)

.PARAMETER GstRoot   GStreamer 1.24.x MSVC x86_64 root containing bin\, lib\, include\ (runtime + devel MSIs,
                     unpacked with `msiexec /a <msi> /qn TARGETDIR=<dir>` - no system install needed)
.EXAMPLE
  .\Build-RetroFE.ps1 -GstRoot D:\ArcadeMaster\_tools\gstreamer\gstreamer\1.0\msvc_x86_64 -Out D:\ArcadeMaster\build
#>
param(
  [Parameter(Mandatory)][string]$GstRoot,
  [string]$Work = 'D:\ArcadeMaster\src',
  [string]$Out = 'D:\ArcadeMaster\build\retrofe-runtime',
  [string]$Commit = 'caab32e604a831d89b1f7f5905457de6ba5c4018',
  [string]$Repo = 'https://github.com/CoinOPS-Official/RetroFE.git',
  [string]$Git = 'git',
  [string]$CMake = 'cmake'
)
$ErrorActionPreference = 'Stop'
function Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
$here = $PSScriptRoot
$src = Join-Path $Work 'RetroFE'

# --- 1. source
if (-not (Test-Path (Join-Path $src '.git'))) {
  Step "clone $Repo"
  & $Git clone --branch current --recurse-submodules --shallow-submodules $Repo $src
  if ($LASTEXITCODE) { throw 'clone failed' }
}
Step "checkout $Commit"
& $Git -C $src fetch --depth 200 origin current 2>$null
& $Git -C $src checkout --force $Commit; if ($LASTEXITCODE) { throw "commit $Commit not available" }
& $Git -C $src submodule update --init --recursive

# --- 2. patches
foreach ($p in Get-ChildItem (Join-Path $here 'patches') -Filter *.patch | Sort-Object Name) {
  & $Git -C $src apply --check --reverse $p.FullName 2>$null
  if ($LASTEXITCODE -eq 0) { Step "patch already applied: $($p.Name)"; continue }
  Step "apply $($p.Name)"; & $Git -C $src apply $p.FullName; if ($LASTEXITCODE) { throw "patch failed: $($p.Name)" }
}

# --- 3. SDL include shim
$tp = Join-Path $src 'RetroFE\ThirdParty'
$shim = Join-Path $Work 'shim\include'
New-Item -ItemType Directory -Force (Join-Path $shim 'SDL2') | Out-Null
foreach ($d in Get-ChildItem $tp -Directory -Filter 'SDL2*') { Copy-Item (Join-Path $d.FullName 'include\*.h') (Join-Path $shim 'SDL2') -Force }

# --- 4. build
$build = Join-Path $src 'RetroFE\Build'
Step 'cmake configure'
& $CMake -A x64 -B $build -S (Join-Path $src 'RetroFE\Source') "-DGSTREAMER_ROOT=$GstRoot" `
  "-DSDL2_INCLUDE_DIR=$shim" "-DSDL2_IMAGE_INCLUDE_DIR=$shim" "-DSDL2_MIXER_INCLUDE_DIR=$shim" "-DSDL2_TTF_INCLUDE_DIR=$shim" `
  "-DCMAKE_CXX_FLAGS_RELEASE=/O2 /Ob2 /Zi /DNDEBUG" "-DCMAKE_C_FLAGS_RELEASE=/O2 /Ob2 /Zi /DNDEBUG" `
  "-DCMAKE_EXE_LINKER_FLAGS_RELEASE=/DEBUG /OPT:REF /OPT:ICF /INCREMENTAL:NO"
if ($LASTEXITCODE) { throw 'configure failed' }
Step 'cmake build'
& $CMake --build $build --config Release --parallel; if ($LASTEXITCODE) { throw 'build failed' }

# --- 5. runtime folder
$rt = Join-Path $Out 'retrofe'
Step "assemble runtime -> $rt"
if (Test-Path $rt) { Remove-Item $rt -Recurse -Force }
New-Item -ItemType Directory -Force $rt | Out-Null
$deps = Join-Path $src 'Package\Environment\Windows\retrofe'
$gstBin = Get-ChildItem (Join-Path $GstRoot 'bin') -Filter *.dll
$gstBinNames = @($gstBin.Name)
$exclude = @('gstfrei0r.dll', 'PacDrive64.dll', 'registry.bin', '.gitignore', 'README.md', 'LICENSE')
# non-GStreamer files from the deps bundle (fonts, SDL, ...) - never its gst*.dll or anything the 1.24 bin provides
Get-ChildItem $deps -File | Where-Object { $_.Name -notlike 'gst*.dll' -and $_.Name -notin $gstBinNames -and $_.Name -notin $exclude } | Copy-Item -Destination $rt
$gstBin | Copy-Item -Destination $rt
Get-ChildItem (Join-Path $GstRoot 'lib\gstreamer-1.0') -Filter *.dll | Where-Object { $_.Name -notin $exclude } | Copy-Item -Destination $rt
Copy-Item (Join-Path $GstRoot 'libexec\gstreamer-1.0\gst-plugin-scanner.exe') $rt
foreach ($d in 'SDL2-*', 'SDL2_image-*', 'SDL2_mixer-*', 'SDL2_ttf-*') {            # SDL DLLs matching the headers we compiled with
  Get-ChildItem $tp -Directory -Filter $d | ForEach-Object { Copy-Item (Join-Path $_.FullName 'lib\x64\*.dll') $rt -Force }
}
foreach ($n in 'libusb-1.0.dll', 'libserialport.dll', 'libcurl.dll', 'zlib.dll', 'zlib1.dll') {
  $f = Get-ChildItem $tp -Recurse -Filter $n | Where-Object { $_.FullName -notmatch '\\(x86|Win32|debug)\\' } | Select-Object -First 1
  if ($f) { Copy-Item $f.FullName $rt -Force } else { Write-Warning "ThirdParty DLL not found: $n" }
}
Copy-Item (Join-Path $build 'Release\retrofe.exe'), (Join-Path $build 'Release\retrofe.pdb') $rt
Step ("done: {0} files, {1:N0} MB" -f (Get-ChildItem $rt).Count, ((Get-ChildItem $rt | Measure-Object Length -Sum).Sum / 1MB))
