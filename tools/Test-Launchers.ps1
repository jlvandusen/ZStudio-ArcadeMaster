<#
.SYNOPSIS
  Smoke test: does every list's direct launcher really start a game? For each collection whose launcher is AM_DL_*
  (tools/New-DirectLaunchers.py), the first game in its folder is started exactly as the frontend would start it (the
  list's own launcher, or a per-game one from collections\<list>\launchers\<game>.conf), left running for -Seconds, and
  judged:
    PASS        the emulator is still running and has a window
    NO WINDOW   still running, but no window appeared (a console-only start, a hidden error box ...)
    EXITED      it ended by itself before the time was up (missing BIOS, a bad path, a crash) - its exit code is kept
  then closed (its whole process tree). The game hooks (play time) are not run. Results: <manifest>\launcher-test.json.
  Puts games on the screen one after another: run it when nobody is using the cabinet (it refuses while the frontend
  or a game is open, unless -Force).
.EXAMPLE
  tools\Test-Launchers.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest -Lists 'Super Nintendo*','Wii U'
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [Parameter(Mandatory)][string]$ManifestDir,
  [string[]]$Lists = @('*'),
  [int]$Seconds = 12,
  [switch]$DryRun,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $Force -and (Get-Process retrofe -ErrorAction SilentlyContinue)) { throw 'the frontend is open - close it first (or -Force)' }
$cols = Join-Path $RetroFE 'collections'; $lw = Join-Path $RetroFE 'launchers.windows'
function Read-Conf([string]$p) { $h = @{}; foreach ($l in Get-Content -LiteralPath $p) { if ($l -match '^\s*([A-Za-z.]+)\s*=\s*(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() } }; $h }
function Stop-Tree([int]$id) { & taskkill.exe /T /F /PID $id 2>$null | Out-Null }
Add-Type @'
using System;using System.Collections.Generic;using System.Runtime.InteropServices;
public class LT{delegate bool P(IntPtr h,IntPtr l);[DllImport("user32.dll")]static extern bool EnumWindows(P p,IntPtr l);[DllImport("user32.dll")]static extern int GetWindowThreadProcessId(IntPtr h,out int p);[DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr h);
public static bool HasWindow(HashSet<int> pids){bool f=false;EnumWindows((h,l)=>{int p;GetWindowThreadProcessId(h,out p);if(pids.Contains(p)&&IsWindowVisible(h)){f=true;return false;}return true;},IntPtr.Zero);return f;}}
'@
function Get-Tree([int]$root) {
  $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId
  $set = New-Object 'System.Collections.Generic.HashSet[int]'; [void]$set.Add($root); $grew = $true
  while ($grew) { $grew = $false; foreach ($p in $all) { if ($set.Contains([int]$p.ParentProcessId) -and $set.Add([int]$p.ProcessId)) { $grew = $true } } }
  ,$set
}
$results = @()
foreach ($dir in Get-ChildItem $cols -Directory | Sort-Object Name) {
  if (-not ($Lists | Where-Object { $dir.Name -like $_ })) { continue }
  $sc = Join-Path $dir.FullName 'settings.conf'; if (-not (Test-Path -LiteralPath $sc)) { continue }
  $s = Read-Conf $sc
  if ($s['launcher'] -notmatch '^AM_DL_') { continue }
  $lp = $s['list.path']; if (-not $lp) { continue }
  if (-not [IO.Path]::IsPathRooted($lp)) { $lp = Join-Path $RetroFE $lp }
  $exts = @(($s['list.extensions'] -split ',') | ForEach-Object { '.' + $_.Trim().ToLower() } | Where-Object { $_ -ne '.' })
  $game = Get-ChildItem -LiteralPath $lp -File -ErrorAction SilentlyContinue | Where-Object { $exts -contains $_.Extension.ToLower() } | Sort-Object Name | Select-Object -First 1
  if (-not $game) { $results += [pscustomobject]@{ List = $dir.Name; Game = ''; Result = 'NO GAMES'; Detail = $lp }; continue }
  $name = [IO.Path]::GetFileNameWithoutExtension($game.Name)
  $per = Join-Path $dir.FullName "launchers\$name.conf"
  $lname = if (Test-Path -LiteralPath $per) { (Get-Content -LiteralPath $per -TotalCount 1).Trim() } else { $s['launcher'] }
  $L = Read-Conf (Join-Path $lw "$lname.conf")
  $vars = @{ '%ITEM_FILEPATH%' = $game.FullName; '%ITEM_NAME%' = $name; '%ITEM_FILENAME%' = $game.Name; '%ITEM_DIRECTORY%' = $game.DirectoryName; '%ITEM_COLLECTION_NAME%' = $dir.Name }
  $a = $L['arguments']; foreach ($k in $vars.Keys) { $a = $a.Replace($k, $vars[$k]) }
  $cwd = if ($L['currentDirectory']) { $L['currentDirectory'] } else { Split-Path $L['executable'] }
  if ($DryRun) { $results += [pscustomobject]@{ List = $dir.Name; Game = $game.Name; Result = 'DRY RUN'; Detail = "$($L['executable']) $a" }; continue }
  Write-Host ("{0,-40} {1}" -f $dir.Name, $game.Name)
  $t0 = Get-Date; $res = 'PASS'; $detail = ''
  try {
    $p = Start-Process $L['executable'] -ArgumentList $a -WorkingDirectory $cwd -PassThru
    $seenWindow = $false
    while (((Get-Date) - $t0).TotalSeconds -lt $Seconds) {
      Start-Sleep -Milliseconds 700
      if ($p.HasExited) { break }
      if (-not $seenWindow -and [LT]::HasWindow((Get-Tree $p.Id))) { $seenWindow = $true }
    }
    if ($p.HasExited) { $res = 'EXITED'; $detail = "exit $($p.ExitCode) after $([int]((Get-Date) - $t0).TotalSeconds) s" }
    elseif (-not $seenWindow) { $res = 'NO WINDOW' }
    if (-not $p.HasExited) { Stop-Tree $p.Id }
  }
  catch { $res = 'EXITED'; $detail = $_.Exception.Message }
  Start-Sleep 2
  $results += [pscustomobject]@{ List = $dir.Name; Game = $game.Name; Result = $res; Detail = $detail }
}
$results | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$out = Join-Path $ManifestDir 'launcher-test.json'
@{ when = (Get-Date).ToString('s'); seconds = $Seconds; results = $results } | ConvertTo-Json -Depth 4 | Set-Content $out -Encoding UTF8
Write-Host ("launcher test: {0} PASS, {1} other - {2}" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -ne 'PASS').Count, $out)
