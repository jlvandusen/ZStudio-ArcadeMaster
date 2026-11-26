<#
.SYNOPSIS
  Builds dist\ArcadeMaster.exe (launcher + setup + updater) from src\launcher\*.cs with the Roslyn compiler that comes
  with Visual Studio / Build Tools, against the .NET Framework 4.x already on every Windows 10/11 PC - so the exe
  runs on any cabinet with nothing extra installed. The icon is made from the Real Z Studios logo.
.EXAMPLE
  tools\Build-Launcher.ps1                       # -> dist\ArcadeMaster.exe
  tools\Build-Launcher.ps1 -InstallTo D:\ArcadeMaster   # also copy it there (outside the repo, so updates can replace it)
#>
param([string]$InstallTo)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
# Roslyn: ask vswhere where Visual Studio is (any drive) and look in its one Roslyn folder. Searching the whole Visual
# Studio tree took over 5 minutes once the C++ build tools were in (2P stand-up, 2026-11-26).
$csc = @()
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) { foreach ($vsp in @(& $vswhere -products * -property installationPath 2>$null)) { $r = [IO.Path]::Combine($vsp, 'MSBuild\Current\Bin\Roslyn\csc.exe'); if ($vsp -and (Test-Path $r)) { $csc = @(Get-Item $r); break } } }
if (-not $csc) { $csc = @(Get-ChildItem 'D:\VS', 'C:\Program Files\Microsoft Visual Studio', 'C:\Program Files (x86)\Microsoft Visual Studio' -Recurse -Filter csc.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\Roslyn\\csc\.exe$' } | Select-Object -First 1) }
$fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
# no Visual Studio (e.g. a cabinet): the C# 5 compiler that ships with .NET Framework 4.x builds the launcher as well
if (-not $csc) { $csc = @(Get-Item (Join-Path $fw 'csc.exe') -ErrorAction SilentlyContinue) }
if (-not $csc) { throw 'no C# compiler: neither Roslyn (Visual Studio Build Tools) nor the .NET Framework csc.exe was found' }
Write-Host "compiler: $($csc[0].FullName)"
$refs = 'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.Web.Extensions.dll', 'Microsoft.CSharp.dll' | ForEach-Object { "/reference:$(Join-Path $fw $_)" }
$dist = Join-Path $repo 'dist'; New-Item -ItemType Directory -Force $dist | Out-Null

# icon: PNG-compressed ICO entries (256, 64, 48, 32, 16) from the studio logo
Add-Type -AssemblyName System.Drawing
$logo = Join-Path $repo 'layouts\ArcadeMaster\images\studio_realz.png'; $ico = Join-Path $dist 'ArcadeMaster.ico'
$src = [Drawing.Image]::FromFile($logo); $pngs = @()
foreach ($s in 256, 64, 48, 32, 16) { $b = New-Object Drawing.Bitmap $s, $s; $g = [Drawing.Graphics]::FromImage($b); $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($src, 0, 0, $s, $s); $g.Dispose(); $ms = New-Object IO.MemoryStream; $b.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $pngs += , @($s, $ms.ToArray()); $b.Dispose() }
$src.Dispose()
$fs = [IO.File]::Create($ico); $w = New-Object IO.BinaryWriter $fs
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$pngs.Count); $off = 6 + 16 * $pngs.Count
foreach ($p in $pngs) { $sz = $p[0]; $w.Write([byte]($sz % 256)); $w.Write([byte]($sz % 256)); $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$p[1].Length); $w.Write([uint32]$off); $off += $p[1].Length }
foreach ($p in $pngs) { $w.Write($p[1]) }; $w.Close()

$out = Join-Path $dist 'ArcadeMaster.exe'
$srcs = @(Get-ChildItem (Join-Path $repo 'src\launcher') -Filter *.cs | ForEach-Object { $_.FullName })   # @(): one file must stay an array for splatting
$msg = & $csc.FullName /nologo /target:winexe /platform:anycpu /optimize+ "/win32icon:$ico" "/out:$out" @refs @srcs 2>&1; $msg | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE) { throw "compile failed ($LASTEXITCODE)" }
Write-Host ("built {0} ({1:N0} KB)" -f $out, ((Get-Item $out).Length / 1KB))
if ($InstallTo) { New-Item -ItemType Directory -Force $InstallTo | Out-Null; Copy-Item $out (Join-Path $InstallTo 'ArcadeMaster.exe') -Force; Write-Host "installed -> $InstallTo\ArcadeMaster.exe" }
