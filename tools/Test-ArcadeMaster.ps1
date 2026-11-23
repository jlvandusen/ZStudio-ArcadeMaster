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
.EXAMPLE
  tools\Test-ArcadeMaster.ps1
  tools\Test-ArcadeMaster.ps1 -Watchdog
#>
param([switch]$Watchdog)
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

$hooks = @(Get-ChildItem (Join-Path $repo 'tools\git-hooks') -File -ErrorAction SilentlyContinue)
$bad = @(& $crlf $hooks)
$git = (Get-Command git -ErrorAction SilentlyContinue).Source; if (-not $git -and (Test-Path 'C:\Program Files\Git\cmd\git.exe')) { $git = 'C:\Program Files\Git\cmd\git.exe' }
if ($git -and (Test-Path (Join-Path $repo '.git'))) {
  $hp = & $git -C $repo config core.hooksPath
  if ($hp -ne 'tools/git-hooks') { $bad += "commit check is off in this clone: run  git config core.hooksPath tools/git-hooks" }
}
Report 'hooks' $bad "$($hooks.Count) hooks use LF, commit check on"

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
    # no Python on PATH: the Stream Deck helper must not start against the fake frontend
    $oldPath = $env:PATH; $env:PATH = "$env:WINDIR\System32;$env:WINDIR\System32\WindowsPowerShell\v1.0"
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
}

Write-Host ("{0} of {1} checks passed" -f ($checks - $fails), $checks)
exit [int]($fails -gt 0)
