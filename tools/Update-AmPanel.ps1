<#
.SYNOPSIS
  Keeps a cabinet's installed AmPanel (the panel service: lights, Esc ends games, marquee, loading screen ...) in step
  with the repo. Before this, a fix to src\panel reached a cabinet only when somebody ran Build-AmPanel.ps1 -InstallTo
  by hand. The boot (Start-ArcadeMaster) runs it just before AmPanel starts:

  - key = a fingerprint of src\panel\*.cs, Build-AmPanel.ps1, panel-rules.json and exit-rules.json;
    <ArcadeMaster>\AmPanel.build.txt records the key that is installed
  - same key: nothing happens
  - new key: Build-AmPanel.ps1 compiles it (Visual Studio Build Tools or the .NET Framework's csc) and installs it next
    to the launcher, the LEDBlinky.exe shim included. A compile that fails changes nothing - the installed AmPanel stays.
  - a running AmPanel is closed first only with -Boot (it is started again right after); otherwise the install waits
  - a cabinet without AmPanel installed is left alone (installing it is a deliberate step, docs/13)
.EXAMPLE
  tools\Update-AmPanel.ps1 -ManifestDir D:\ArcadeMaster\manifest -Boot
  tools\Update-AmPanel.ps1 -ManifestDir D:\ArcadeMaster\manifest -Show
#>
param(
  [Parameter(Mandatory)][string]$ManifestDir,
  [switch]$Boot,
  [switch]$Show,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$amRoot = Split-Path $ManifestDir
$amExe = Join-Path $amRoot 'AmPanel.exe'
$stamp = Join-Path $amRoot 'AmPanel.build.txt'
if (-not (Test-Path $amExe)) { if ($Show) { Write-Host "AmPanel is not installed in $amRoot" }; return }

$parts = @(Get-ChildItem (Join-Path $repo 'src\panel') -Filter *.cs -File | Sort-Object Name) +
         @(Get-Item (Join-Path $PSScriptRoot 'Build-AmPanel.ps1'), (Join-Path $PSScriptRoot 'panel-rules.json'), (Join-Path $PSScriptRoot 'exit-rules.json'))
$sha = [Security.Cryptography.SHA1]::Create(); $all = New-Object IO.MemoryStream
foreach ($p in $parts) {
  $b = [Text.Encoding]::UTF8.GetBytes($p.Name + "`n"); $all.Write($b, 0, $b.Length)
  # line endings do not count: a clone with CRLF and one with LF want the same build
  $c = [Text.Encoding]::UTF8.GetBytes(([IO.File]::ReadAllText($p.FullName) -replace "`r", '')); $all.Write($c, 0, $c.Length)
}
$key = (-join ($sha.ComputeHash($all.ToArray()) | ForEach-Object { $_.ToString('x2') })).Substring(0, 10)
$have = if (Test-Path $stamp) { ((Get-Content $stamp | Where-Object { $_ -match '^key=' } | Select-Object -First 1) -replace '^key=', '').Trim() } else { '' }
if ($Show) { Write-Host "AmPanel: installed $(if ($have) { $have } else { 'unknown' }), repo wants $key"; return }
if ($have -eq $key -and -not $Force) { return }

$running = @(Get-Process AmPanel, LEDBlinky -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($amRoot, [StringComparison]::OrdinalIgnoreCase) })
if ($running -and -not $Boot) { Write-Host "AmPanel $key is ready to install; it goes in at the next frontend start (AmPanel is running)"; return }

# compile first (into the repo's dist\): a failure leaves the running / installed AmPanel alone
try { $null = & (Join-Path $PSScriptRoot 'Build-AmPanel.ps1') 6>&1 2>&1 }
catch { Write-Host "AmPanel $key not built ($($_.Exception.Message)) - the installed one stays"; return }
if ($running) { $running | Stop-Process -Force; Start-Sleep -Milliseconds 700 }
$o = (& (Join-Path $PSScriptRoot 'Build-AmPanel.ps1') -InstallTo $amRoot 6>&1 3>&1 2>&1 | Out-String)
if ($o -notmatch 'installed ->') { Write-Host "AmPanel $key built but not installed: $($o.Trim())"; return }
Set-Content $stamp "key=$key`r`ninstalled=$(Get-Date -Format s)`r`ncommit=$(& git -C $repo rev-parse --short HEAD 2>$null)" -Encoding ascii
Write-Host "installed AmPanel $key (was $(if ($have) { $have } else { 'unknown' }))$(if ($running) { '; the old one was closed and starts again now' })"
