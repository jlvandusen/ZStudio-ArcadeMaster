<#
.SYNOPSIS
  Self-test for the ArcadeMaster repo: run it before opening or merging a pull request, on any cabinet.
  Nothing here touches a live frontend, Windows settings or game data.

  Always:
    scripts    every .ps1 parses (Windows PowerShell 5.1 parser)
    encoding   a .ps1 with non-ASCII text has a UTF-8 BOM (without one, PowerShell 5.1 reads it as ANSI and breaks)
    json       every .json in tools\ and layouts\ reads
    xml        every layout .xml reads
    patches    retrofe\patches\*.patch use LF line endings (git apply fails on CRLF)
    hooks      tools\git-hooks\* use LF (sh fails on CRLF) and the commit check is switched on in this clone
  -Watchdog:
    a fake frontend that always crashes, started by Start-ArcadeMaster in a temp folder: the crash loop must put the
    ArcadeMaster theme back and then give up (about 20 s)
    theme confirm: a fake frontend on an unconfirmed new theme - nobody answers "keep this theme?" -> old theme back
    and the frontend restarted; and the frontend dying before the prompt -> the watchdog reverts (about 25 s)
  -Cabinet:
    runs this cabinet's checks for real against its frontend (ArcadeMaster.config.json, never a ProtectedPaths one):
    Repair-ArcadeHealth -NoFix and Import-LEDBlinkyPanel --dry-run must finish without a single PowerShell / Python
    error. A script can parse and still be broken (2026-11-25: a comment mid-line cut off an expression, and the health
    check failed on every TeknoParrot profile for a day).
.EXAMPLE
  tools\Test-ArcadeMaster.ps1
  tools\Test-ArcadeMaster.ps1 -Watchdog
  tools\Test-ArcadeMaster.ps1 -Cabinet
#>
param([switch]$Watchdog, [switch]$Cabinet)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
$fails = 0; $checks = 0
function Report([string]$area, [string[]]$problems, [string]$okText) {
  $script:checks++
  if ($problems) { $script:fails++; Write-Host ("FAIL  {0,-9} {1} problem(s)" -f $area, $problems.Count) -ForegroundColor Red; $problems | Select-Object -First 15 | ForEach-Object { Write-Host "        $_" } }
  else { Write-Host ("ok    {0,-9} {1}" -f $area, $okText) -ForegroundColor Green }
}
function Rel([string]$p) { $p.Substring($repo.Length + 1) }

$ps1 = @(Get-ChildItem (Join-Path $repo 'tools') -Recurse -Filter *.ps1 -File)
$bad = foreach ($f in $ps1) {
  $tok = $null; $err = $null
  [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tok, [ref]$err)
  foreach ($e in $err) { "{0}:{1} {2}" -f (Rel $f.FullName), $e.Extent.StartLineNumber, $e.Message }
}
Report 'scripts' @($bad) "$($ps1.Count) scripts parse"

$bad = foreach ($f in $ps1) {
  $b = [IO.File]::ReadAllBytes($f.FullName)
  $bom = $b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF
  if (-not $bom) { for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -gt 127) { "$(Rel $f.FullName): non-ASCII text but no BOM (save as UTF-8 with BOM, or use ASCII)"; break } } }
}
Report 'encoding' @($bad) 'non-ASCII scripts all have a BOM'

$json = @(Get-ChildItem (Join-Path $repo 'tools'), (Join-Path $repo 'layouts') -Recurse -Filter *.json -File)
$bad = foreach ($f in $json) { try { [void](Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json) } catch { "$(Rel $f.FullName): $($_.Exception.Message.Split("`n")[0])" } }
Report 'json' @($bad) "$($json.Count) files read"

$xml = @(Get-ChildItem (Join-Path $repo 'layouts') -Recurse -Filter *.xml -File)
$bad = foreach ($f in $xml) { try { $d = New-Object Xml.XmlDocument; $d.Load($f.FullName) } catch { "$(Rel $f.FullName): $($_.Exception.Message)" } }
Report 'xml' @($bad) "$($xml.Count) layout files read"

$crlf = { param($files) foreach ($f in $files) { if ([IO.File]::ReadAllText($f.FullName).Contains("`r`n")) { "$(Rel $f.FullName): has CRLF line endings (if git has it right: delete the file, then git checkout -- <file>)" } } }
$pt = @(Get-ChildItem (Join-Path $repo 'retrofe\patches') -Filter *.patch -File -ErrorAction SilentlyContinue)
Report 'patches' @(& $crlf $pt) "$($pt.Count) patches use LF"

# retrofe\fork.txt (docs/21): Update-Cabinet builds nothing unless it names a repo and a FULL 40-character commit
# (2026-11-27: a short id was merged and every cabinet would have stopped updating)
$forkTxt = Join-Path $repo 'retrofe\fork.txt'
if (Test-Path $forkTxt) {
  $ft = Get-Content $forkTxt
  $bad = @()
  if (-not ($ft | Where-Object { $_ -match '^\s*repo\s*=\s*\S+' })) { $bad += 'retrofe\fork.txt has no repo= line' }
  if (-not ($ft | Where-Object { $_ -match '^\s*commit\s*=\s*[0-9a-f]{40}\s*$' })) { $bad += 'retrofe\fork.txt needs commit= with the full 40-character commit id (git rev-parse <id>)' }
  Report 'fork' $bad 'retrofe\fork.txt pins a full commit'
}

$hooks = @(Get-ChildItem (Join-Path $repo 'tools\git-hooks') -File -ErrorAction SilentlyContinue)
$bad = @(& $crlf $hooks)
$git = (Get-Command git -ErrorAction SilentlyContinue).Source; if (-not $git -and (Test-Path 'C:\Program Files\Git\cmd\git.exe')) { $git = 'C:\Program Files\Git\cmd\git.exe' }
if ($git -and (Test-Path (Join-Path $repo '.git'))) {
  $hp = & $git -C $repo config core.hooksPath
  if ($hp -ne 'tools/git-hooks') { $bad += "commit check is off in this clone: run  git config core.hooksPath tools/git-hooks" }
}
Report 'hooks' $bad "$($hooks.Count) hooks use LF, commit check on"

# ---- game list views: only pictures the release carries ----
# A view (layouts\AM-*\gamelist.layout.xml) is copied into a list's own layout folder, so its pictures are named from
# there (../../../). Every one must be in the repo: the theme's own (layouts\ArcadeMaster) or the view's images folder.
# A picture that exists only on a cabinet would be a hole on a fresh install.
$bad = @(); $lay = Join-Path $repo 'layouts'; $nViews = 0
foreach ($vf in Get-ChildItem -LiteralPath $lay -Filter 'gamelist.layout.xml' -Recurse -File) {
  $nViews++; $vdir = Split-Path $vf.FullName; $vt = [IO.File]::ReadAllText($vf.FullName)
  try { [void][xml]$vt } catch { $bad += "$($vf.Directory.Name): not well-formed ($($_.Exception.Message))"; continue }
  if ($vt -notmatch 'ArcadeMaster game list view: \w+|WALL OF GAMES - game list') { $bad += "$($vf.Directory.Name): no 'ArcadeMaster game list view: <name>' mark, so -View default could not take it away" }
  foreach ($m in [regex]::Matches($vt, '(?:src|font)="([^"]+)"')) {
    $p = $m.Groups[1].Value
    if ($p -like '../../../images/am-views/*') { $q = Join-Path $vdir ('images\' + ($p -replace '^.*/am-views/', '')) }
    elseif ($p -like '../../../*') { $q = Join-Path $lay ('ArcadeMaster\' + ($p.Substring(9) -replace '/', '\')) }
    else { $q = Join-Path $lay ('ArcadeMaster\' + ($p -replace '/', '\')) }
    if (-not (Test-Path -LiteralPath $q)) { $bad += "$($vf.Directory.Name): $p is not in the repo" }
  }
}
Report 'views' $bad "$nViews game list views use only pictures and fonts that are in the repo"

if ($Watchdog) {
  $t = Join-Path $env:TEMP ("am-selftest-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
  $problems = @()
  try {
    New-Item -ItemType Directory -Force "$t\root\retrofe", "$t\root\layouts\ArcadeMaster", "$t\root\layouts\CO-Broken", "$t\root\collections", "$t\manifest" | Out-Null
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    Set-Content "$t\crash.cs" 'class P { static int Main() { System.IO.File.AppendAllText("runs.txt", System.IO.File.ReadAllText(@"..\settings.conf").Contains("layout = ArcadeMaster") ? "AM\n" : "BROKEN\n"); return 3; } }'
    & $csc /nologo "/out:$t\root\retrofe\retrofe.exe" "$t\crash.cs" | Out-Null
    '<layout/>' | Set-Content "$t\root\layouts\ArcadeMaster\layout.xml"; '<layout/>' | Set-Content "$t\root\layouts\CO-Broken\layout.xml"
    "fullscreen = yes`r`nlayout = CO-Broken`r`nnumScreens = 1" | Set-Content "$t\root\settings.conf"
    '{ "streamDeck": false }' | Set-Content "$t\manifest\ui.json"   # Python is found off PATH too: keep the deck helper away from the fake
    # no Python on PATH: the Stream Deck helper must not start against the fake frontend
    $env:AM_NO_UPDATE = '1'; $oldPath = $env:PATH; $env:PATH = "$env:WINDIR\System32;$env:WINDIR\System32\WindowsPowerShell\v1.0"
    $ErrorActionPreference = 'Continue'   # the launcher's own error output must not stop this test; its log is checked below
    try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Start-ArcadeMaster.ps1') -Root "$t\root" -ManifestDir "$t\manifest" -NoDeviceCheck -NoShuffle -MaxCrashes 4 2>&1 | Out-String }
    finally { $env:PATH = $oldPath; $ErrorActionPreference = 'Stop' }
    $errs = @($out -split "`r?`n" | Where-Object { $_ -match '^\S.*: ' -and $_ -match '(?i)exception|error|cannot|already exists' })
    if ($errs) { $problems += "the launcher printed errors: $($errs[0].Trim())" }
    $runs = @(Get-Content "$t\root\retrofe\runs.txt" -ErrorAction SilentlyContinue)
    $log = Get-Content "$t\root\arcademaster-launcher.log" -Raw -ErrorAction SilentlyContinue
    if ($runs -notcontains 'BROKEN') { $problems += 'the broken theme was never started (test setup problem)' }
    if ($runs[-1] -ne 'AM') { $problems += "the last start did not use the ArcadeMaster theme (starts: $($runs -join ' '))" }
    if ($log -notmatch 'switched back to the ArcadeMaster theme') { $problems += 'the log has no theme fallback line' }
    if ($log -notmatch 'giving up') { $problems += 'the watchdog did not give up after the crash loop' }
    if (-not (Test-Path "$t\root\settings.conf.before-theme-fallback")) { $problems += 'settings.conf.before-theme-fallback was not kept' }
  } catch { $problems += $_.Exception.Message }
  finally { Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
  Report 'watchdog' $problems 'a crashing theme falls back to ArcadeMaster, then the watchdog gives up'

  # theme confirm: a fake frontend on a new theme (CO-New) with theme-pending.json waiting. Nobody answers the prompt
  # (no window, 2 s): the theme must be reverted, the frontend restarted on ArcadeMaster. Crash variant: it dies
  # before the prompt - the watchdog itself reverts. Both end with a clean exit of the fake on ArcadeMaster.
  foreach ($crash in $false, $true) {
    $area = if ($crash) { 'confirm-crash' } else { 'confirm' }
    $t = Join-Path $env:TEMP ("am-selftest-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    $problems = @()
    try {
      New-Item -ItemType Directory -Force "$t\root\retrofe", "$t\root\layouts\ArcadeMaster", "$t\root\layouts\CO-New", "$t\root\collections", "$t\manifest" | Out-Null
      $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
      Set-Content "$t\fake.cs" 'class P { static int Main() { bool n = System.IO.File.ReadAllText(@"..\settings.conf").Contains("layout = CO-New"); System.IO.File.AppendAllText("runs.txt", n ? "NEW\n" : "AM\n"); if (n && System.IO.File.Exists(@"..\crash.flag")) return 3; if (n) System.Threading.Thread.Sleep(60000); return 0; } }'
      & $csc /nologo "/out:$t\root\retrofe\retrofe.exe" "$t\fake.cs" | Out-Null
      '<layout/>' | Set-Content "$t\root\layouts\ArcadeMaster\layout.xml"; '<layout/>' | Set-Content "$t\root\layouts\CO-New\layout.xml"
      "fullscreen = yes`r`nlayout = CO-New`r`nnumScreens = 1`r`ncabinetTheme.racing = CO-New" | Set-Content "$t\root\settings.conf"
      if ($crash) { 'x' | Set-Content "$t\root\crash.flag" }
      '{ "streamDeck": false }' | Set-Content "$t\manifest\ui.json"
      '{ "at": "2026-01-01T00:00:00", "choice": "CO-New", "mode": "racing", "previous": { "layout": "ArcadeMaster", "cabinetThemeKey": "cabinetTheme.racing", "cabinetTheme": null, "skins": null } }' | Set-Content "$t\manifest\theme-pending.json"
      $env:AM_NO_UPDATE = '1'; $oldPath = $env:PATH; $env:PATH = "$env:WINDIR\System32;$env:WINDIR\System32\WindowsPowerShell\v1.0"
      $env:AM_THEME_CONFIRM_NOUI = '1'; $env:AM_THEME_NOART = '1'; $ErrorActionPreference = 'Continue'
      try { $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Start-ArcadeMaster.ps1') -Root "$t\root" -ManifestDir "$t\manifest" -NoDeviceCheck -NoShuffle -ThemeConfirmSec 2 -ThemeSettleSec 2 2>&1 | Out-String }
      finally { $env:PATH = $oldPath; $env:AM_THEME_CONFIRM_NOUI = $null; $env:AM_THEME_NOART = $null; $ErrorActionPreference = 'Stop' }
      $errs = @($out -split "`r?`n" | Where-Object { $_ -match '^\S.*: ' -and $_ -match '(?i)exception|error|cannot|already exists' })
      if ($errs) { $problems += "the launcher printed errors: $($errs[0].Trim())" }
      $runs = @(Get-Content "$t\root\retrofe\runs.txt" -ErrorAction SilentlyContinue)
      $log = Get-Content "$t\root\arcademaster-launcher.log" -Raw -ErrorAction SilentlyContinue
      $sct = Get-Content "$t\root\settings.conf" -Raw
      if (($runs -join ' ') -ne 'NEW AM') { $problems += "starts should be 'NEW AM', were '$($runs -join ' ')'" }
      if ($sct -notmatch '(?m)^layout = ArcadeMaster\s*$') { $problems += 'settings.conf layout was not put back to ArcadeMaster' }
      if ($sct -match 'cabinetTheme\.racing') { $problems += 'cabinetTheme.racing (absent before the change) was not removed' }
      if (Test-Path "$t\manifest\theme-pending.json") { $problems += 'theme-pending.json is still there' }
      $want = if ($crash) { 'not kept \(the frontend closed before it was confirmed' } else { 'not kept \(no answer in 2 s\)' }
      if ($log -notmatch $want) { $problems += "the log has no '$want' line" }
      if (-not $crash -and $log -notmatch 'restart requested \(theme') { $problems += 'the confirm did not restart the frontend through restart.request' }
      if ($log -notmatch 'RetroFE exited cleanly') { $problems += 'the watchdog did not end with the clean exit on ArcadeMaster' }
      if ($problems) { Write-Host $log }
    } catch { $problems += $_.Exception.Message }
    finally { Get-Process retrofe -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$t*" } | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 300; Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue }
    Report $area $problems $(if ($crash) { 'frontend dies before the theme is confirmed: the watchdog puts the old theme back' } else { 'no answer to "keep this theme?": old theme back, frontend restarted on it' })
  }
}

if ($Cabinet) {
  $problems = @(); $cfg = $null
  foreach ($cf in (Join-Path (Split-Path (Split-Path $PSScriptRoot)) 'ArcadeMaster.config.json'), 'R:\ArcadeMaster\ArcadeMaster.config.json', 'D:\ArcadeMaster\ArcadeMaster.config.json', 'C:\ArcadeMaster\ArcadeMaster.config.json') { if (Test-Path $cf) { $cfg = Get-Content $cf -Raw | ConvertFrom-Json; break } }
  if (-not $cfg -or -not $cfg.RetroFERoot -or -not (Test-Path $cfg.RetroFERoot)) { $problems += 'no ArcadeMaster.config.json with a RetroFERoot that exists on this machine' }
  else {
    . (Join-Path $PSScriptRoot 'lib\AmPython.ps1'); $py = Find-AmPython
    $prot = $null
    if ($py) { $prot = & $py -c "import sys; sys.path.insert(0, r'$PSScriptRoot\lib'); from am_guard import is_protected; print(is_protected(r'$($cfg.RetroFERoot)', r'$($cfg.ManifestDir)'))" 2>$null }
    if ("$prot".Trim() -eq 'True') { $problems += "$($cfg.RetroFERoot) is a protected live frontend (ProtectedPaths): not testing against it" }
    else {
      # a child PowerShell, so every error record of the health check lands on stderr (2>&1) and is counted
      $ErrorActionPreference = 'Continue'
      $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Repair-ArcadeHealth.ps1') -RetroFE $cfg.RetroFERoot -ManifestDir $cfg.ManifestDir -NoFix 2>&1
      $errs = @($out | Where-Object { $_ -is [Management.Automation.ErrorRecord] })
      if ($errs) { $problems += "Repair-ArcadeHealth -NoFix: $($errs.Count) error(s), first: $(($errs[0].ToString() -split "`n")[0])" }
      if (-not ($out | Where-Object { "$_" -match '^health: ' })) { $problems += 'Repair-ArcadeHealth did not reach its summary line' }
      if ($py) {
        # the Python tools Rebuild Game Menus runs, each in its write-nothing mode
        foreach ($tool in @(@('Import-LEDBlinkyPanel.py', '--manifest'), @('New-Marquees.py', '--manifest'), @('New-GameStories.py', '--manifest'))) {
          $pOut = & $py -B (Join-Path $PSScriptRoot $tool[0]) --retrofe $cfg.RetroFERoot $tool[1] $cfg.ManifestDir --dry-run 2>&1
          if ($LASTEXITCODE) { $problems += "$($tool[0]) --dry-run exited $LASTEXITCODE`: $((@($pOut) | Select-Object -Last 1))" }
          elseif (@($pOut) -match '^Traceback') { $problems += "$($tool[0]) --dry-run printed a Python traceback" }
        }
      }
      # the MAME per-game mappings: the json reads, every cfg it names parses (dry run writes nothing)
      $mOut = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Set-MameControls.ps1') -RetroFE $cfg.RetroFERoot 2>&1
      $mErr = @($mOut | Where-Object { $_ -is [Management.Automation.ErrorRecord] })
      # a frontend without MAME (a fresh release install) has no MAME cfg folder: nothing to check there, not a problem
    if (($mOut | Out-String) -match 'no MAME cfg folder') { $mErr = @(); $LASTEXITCODE = 0 }
    if ($mErr -or $LASTEXITCODE) { $problems += "Set-MameControls (dry run): $(if ($mErr) { ($mErr[0].ToString() -split "`n")[0] } else { "exit $LASTEXITCODE" })" }
      $ErrorActionPreference = 'Stop'
    }
  }
  Report 'cabinet' $problems "health check, panel, marquees, stories and MAME mappings run clean against $($cfg.RetroFERoot)"
}

Write-Host ("{0} of {1} checks passed" -f ($checks - $fails), $checks)
exit [int]($fails -gt 0)
