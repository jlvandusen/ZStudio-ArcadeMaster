<#
.SYNOPSIS
  ArcadeMaster job board on the NAS (Z:\ArcadeMaster\board) - how the cabinets (DESKTOP-RACE1, ARCADE-PEDESTAL, ...)
  and their Claude sessions coordinate. Plain files, no Python / Azure needed.
    machines\<HOST>.json        heartbeat: who is here, what it is doing, what it can do
    jobs\open\<id>.md           a job anyone (or the named machine) may claim
    jobs\claimed\<HOST>\<id>.md claimed - a claim is an atomic MOVE on the share, so only one machine wins
    jobs\done\<id>.md           finished, with the report appended
    log.md                      append-only event log
  Rules: announce yourself (beat) when a session starts; claim before working; finish with a report; never edit
  another machine's claimed job; post a job instead of asking in chat.
.EXAMPLE
  Board.ps1 beat -Doing "joined; claiming open jobs" -Can "RetroFE, 4-player panel, touch 2nd screen"
  Board.ps1 list                    # open jobs (for this machine first) + who is online
  Board.ps1 claim -Id 20261122-1350-survey
  Board.ps1 done  -Id 20261122-1350-survey -Report "report committed as reports/frontends/ARCADE-PEDESTAL.md"
  Board.ps1 post  -For ARCADE-PEDESTAL -Title "Run the frontend survey" -Body "..."
#>
param(
  [Parameter(Position = 0, Mandatory)][ValidateSet('beat', 'post', 'list', 'claim', 'done', 'who', 'show', 'log')][string]$Cmd,
  [string]$Id, [string]$Title, [string]$Body, [string]$For = 'any', [string]$Doing, [string]$Can, [string]$Report,
  [string]$Root = 'Z:\ArcadeMaster\board', [string]$Session = $env:AM_SESSION
)
$ErrorActionPreference = 'Stop'
$me = $env:COMPUTERNAME
foreach ($d in 'machines', 'jobs\open', "jobs\claimed\$me", 'jobs\done') { New-Item -ItemType Directory -Force (Join-Path $Root $d) | Out-Null }
$u8 = New-Object Text.UTF8Encoding $false
function Write-Log([string]$m) { $line = "{0:yyyy-MM-dd HH:mm:ss}  {1,-16} {2}`r`n" -f (Get-Date), $me, $m; for ($i = 0; $i -lt 5; $i++) { try { [IO.File]::AppendAllText((Join-Path $Root 'log.md'), $line, $u8); return } catch { Start-Sleep -Milliseconds 200 } } }
function Read-Job([string]$path) {
  $t = [IO.File]::ReadAllText($path); $h = [ordered]@{ path = $path; text = $t }
  if ($t -match '(?s)^---\r?\n(.*?)\r?\n---') { foreach ($l in ($Matches[1] -split "`r?`n")) { if ($l -match '^(\w+):\s*(.*)$') { $h[$Matches[1]] = $Matches[2] } } }
  return [pscustomobject]$h
}
function Find-Job([string]$id) { Get-ChildItem (Join-Path $Root 'jobs') -Recurse -Filter "$id.md" -File | Select-Object -First 1 }

switch ($Cmd) {
  'beat' {
    $f = Join-Path $Root "machines\$me.json"
    $old = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null }
    $o = [ordered]@{ host = $me; session = $(if ($Session) { $Session } elseif ($old) { $old.session } else { '' }); lastBeat = (Get-Date).ToString('s')
      doing = $(if ($Doing) { $Doing } elseif ($old) { $old.doing } else { '' }); can = $(if ($Can) { $Can } elseif ($old) { $old.can } else { '' }) }
    [IO.File]::WriteAllText($f, ($o | ConvertTo-Json), $u8)
    if ($Doing) { Write-Log "beat: $Doing" }
    Write-Host "beat: $me - $($o.doing)"
  }
  'post' {
    if (-not $Title) { throw '-Title required' }
    $slug = ($Title.ToLower() -replace '[^a-z0-9]+', '-').Trim('-'); if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
    $newId = "{0:yyyyMMdd-HHmmss}-{1}" -f (Get-Date), $slug
    $txt = "---`r`nid: $newId`r`ntitle: $Title`r`nfor: $For`r`nfrom: $me`r`ncreated: $((Get-Date).ToString('s'))`r`nstatus: open`r`n---`r`n`r`n$Body`r`n"
    [IO.File]::WriteAllText((Join-Path $Root "jobs\open\$newId.md"), $txt, $u8)
    Write-Log "posted $newId for $For : $Title"; Write-Host "posted $newId"
  }
  { $_ -in 'list', 'who' } {
    Write-Host '-- machines'
    foreach ($m in Get-ChildItem (Join-Path $Root 'machines') -Filter *.json) { $j = Get-Content $m.FullName -Raw | ConvertFrom-Json; $age = [int]((Get-Date) - [datetime]$j.lastBeat).TotalMinutes; Write-Host ("  {0,-18} {1,5} min ago  {2}" -f $j.host, $age, $j.doing) }
    if ($Cmd -eq 'who') { break }
    Write-Host '-- open jobs'
    $open = @(Get-ChildItem (Join-Path $Root 'jobs\open') -Filter *.md | ForEach-Object { Read-Job $_.FullName } | Sort-Object { if ($_.for -eq $me) { 0 } elseif ($_.for -eq 'any') { 1 } else { 2 } }, id)
    if (-not $open) { Write-Host '  (none)' }
    foreach ($j in $open) { Write-Host ("  {0}  for {1,-16} {2}" -f $j.id, $j.for, $j.title) }
    Write-Host '-- claimed'
    foreach ($d in Get-ChildItem (Join-Path $Root 'jobs\claimed') -Directory) { foreach ($f in Get-ChildItem $d.FullName -Filter *.md) { $j = Read-Job $f.FullName; Write-Host ("  {0}  by {1,-16} {2}" -f $j.id, $d.Name, $j.title) } }
  }
  'show' { $f = Find-Job $Id; if (-not $f) { throw "no job $Id" }; Get-Content $f.FullName }
  'claim' {
    $src = Join-Path $Root "jobs\open\$Id.md"; $dst = Join-Path $Root "jobs\claimed\$me\$Id.md"
    if (-not (Test-Path $src)) { throw "job $Id is not open (already claimed or done)" }
    try { [IO.File]::Move($src, $dst) } catch { throw "lost the claim on $Id - another machine took it" }   # atomic rename on the share
    $t = [IO.File]::ReadAllText($dst) -replace '(?m)^status: open', "status: claimed by $me $((Get-Date).ToString('s'))"; [IO.File]::WriteAllText($dst, $t, $u8)
    Write-Log "claimed $Id"; Write-Host "claimed $Id"
  }
  'done' {
    $src = Join-Path $Root "jobs\claimed\$me\$Id.md"; if (-not (Test-Path $src)) { throw "$Id is not claimed by $me" }
    $t = [IO.File]::ReadAllText($src) -replace '(?m)^status: .*$', "status: done by $me $((Get-Date).ToString('s'))"
    $t += "`r`n## Report ($me, $((Get-Date).ToString('s')))`r`n`r`n$Report`r`n"
    [IO.File]::WriteAllText((Join-Path $Root "jobs\done\$Id.md"), $t, $u8); Remove-Item $src
    Write-Log "done $Id"; Write-Host "done $Id"
  }
  'log' { Get-Content (Join-Path $Root 'log.md') -Tail 30 }
}
