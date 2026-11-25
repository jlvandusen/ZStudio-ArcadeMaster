<#
.SYNOPSIS
  Builds dist\AmPanel.exe (ArcadeMaster's panel service, docs/13-panel-service.md) from src\panel\*.cs as an x86
  WinForms exe - x86 because Ultimarc's PacDrive32.dll / UltraStik32.dll are 32-bit. Same compilers as
  Build-Launcher.ps1: Roslyn when Visual Studio Build Tools are there, else the .NET Framework's own csc (C# 5).
.EXAMPLE
  tools\Build-AmPanel.ps1
  tools\Build-AmPanel.ps1 -InstallTo R:\ArcadeMaster
#>
param([string]$InstallTo)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$csc = @(Get-ChildItem 'D:\VS', 'C:\Program Files\Microsoft Visual Studio', 'C:\Program Files (x86)\Microsoft Visual Studio' -Recurse -Filter csc.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\Roslyn\\csc\.exe$' } | Select-Object -First 1)
$fw = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'      # 32-bit framework folder: same reference assemblies
if (-not $csc) { $csc = @(Get-Item (Join-Path $fw 'csc.exe') -ErrorAction SilentlyContinue) }
if (-not $csc) { throw 'no C# compiler found (Visual Studio Build Tools Roslyn or the .NET Framework csc.exe)' }
Write-Host "compiler: $($csc[0].FullName)"
$refs = 'System.dll', 'System.Core.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.Web.Extensions.dll', 'System.Management.dll', 'System.Xml.dll' | ForEach-Object { "/reference:$(Join-Path $fw $_)" }
$dist = Join-Path $repo 'dist'; New-Item -ItemType Directory -Force $dist | Out-Null
$out = Join-Path $dist 'AmPanel.exe'
$srcs = @(Get-ChildItem (Join-Path $repo 'src\panel') -Filter *.cs | ForEach-Object { $_.FullName })
$icoArg = @(); $ico = Join-Path $dist 'ArcadeMaster.ico'; if (Test-Path $ico) { $icoArg = @("/win32icon:$ico") }   # made by Build-Launcher.ps1
$msg = & $csc[0].FullName /nologo /target:winexe /platform:x86 /optimize+ @icoArg "/out:$out" @refs @srcs 2>&1; $msg | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE) { throw "compile failed ($LASTEXITCODE)" }
Write-Host ("built {0} ({1:N0} KB)" -f $out, ((Get-Item $out).Length / 1KB))
Copy-Item (Join-Path $PSScriptRoot 'panel-rules.json') (Join-Path $dist 'panel-rules.json') -Force   # the default trigger rules ship next to the exe
if ($InstallTo) {
  New-Item -ItemType Directory -Force $InstallTo | Out-Null
  $dst = Join-Path $InstallTo 'AmPanel.exe'
  if (Get-Process AmPanel -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $dst }) { Write-Warning "AmPanel is running from $dst - quit it from the tray first"; return }
  Copy-Item $out $dst -Force; Copy-Item (Join-Path $dist 'panel-rules.json') (Join-Path $InstallTo 'panel-rules.json') -Force; Write-Host "installed -> $dst"
}
