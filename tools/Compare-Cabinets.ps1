<#
.SYNOPSIS
  Side by side: what every cabinet actually runs, from the state files they write to the NAS
  (Write-CabinetState.ps1 -> Z:\ArcadeMaster\reports\state\<PC>.json). Rows that differ are marked; a cabinet whose file
  is older than -StaleHours is flagged (it is off, or its boot / update has not run since). Writes COMPARE.md next to
  the state files and prints the differences.
.EXAMPLE
  tools\Compare-Cabinets.ps1                 # differences only on screen, full table in COMPARE.md
  tools\Compare-Cabinets.ps1 -All            # every row on screen
#>
param(
  [string]$StateDir = 'Z:\ArcadeMaster\reports\state',
  [int]$StaleHours = 6,
  [switch]$All
)
$ErrorActionPreference = 'Stop'
$files = @(Get-ChildItem $StateDir -Filter *.json -File -ErrorAction SilentlyContinue | Sort-Object Name)
if (-not $files) { throw "no cabinet state files in $StateDir (each cabinet writes one at boot: Write-CabinetState.ps1)" }
# flatten each file to "a.b.c" = text
function Flat($o, [string]$prefix, [hashtable]$into) {
  if ($null -eq $o) { $into[$prefix] = ''; return }
  if ($o -is [pscustomobject]) { foreach ($p in $o.PSObject.Properties) { Flat $p.Value ($(if ($prefix) { "$prefix.$($p.Name)" } else { $p.Name })) $into }; return }
  if ($o -is [array]) { $into[$prefix] = (@($o) | ForEach-Object { "$_" }) -join ', '; return }
  $into[$prefix] = "$o"
}
$cabs = [ordered]@{}; $order = New-Object System.Collections.Generic.List[string]
foreach ($f in $files) {
  $o = Get-Content $f.FullName -Raw | ConvertFrom-Json; $h = @{}; Flat $o '' $h
  $age = ((Get-Date) - [datetime]$o.written).TotalHours
  $h['_age'] = if ($age -gt $StaleHours) { "STALE ($([int]$age) h old)" } else { "$([int]($age * 60)) min old" }
  $cabs[$o.machine] = $h
  foreach ($k in $h.Keys) { if (-not $order.Contains($k)) { $order.Add($k) } }
}
$skip = '^(machine|root|retrofeExe|written)$'
$names = @($cabs.Keys)
$md = New-Object System.Collections.Generic.List[string]
$md.Add("# Cabinets side by side ($((Get-Date).ToString('yyyy-MM-dd HH:mm')), tools\Compare-Cabinets.ps1)")
$md.Add(''); $md.Add('Rows marked **!=** differ between cabinets. Each cabinet writes its state at boot and after every automatic update.'); $md.Add('')
$md.Add('| | ' + ($names -join ' | ') + ' |'); $md.Add('|---|' + (($names | ForEach-Object { '---' }) -join '|') + '|')
$diffs = 0
foreach ($k in @('_age') + @($order | Where-Object { $_ -ne '_age' -and $_ -notmatch $skip })) {
  $vals = @($names | ForEach-Object { "$($cabs[$_][$k])" })
  $differ = @($vals | Select-Object -Unique).Count -gt 1
  if ($differ -and $k -ne '_age') { $diffs++ }
  $label = if ($k -eq '_age') { 'state file' } else { $k }
  $md.Add("| $(if ($differ -and $k -ne '_age') { '**!=** ' })$label | " + (($vals | ForEach-Object { ($_ -replace '\|', '/') }) -join ' | ') + ' |')
  if ($All -or $differ -or $k -eq '_age') {
    Write-Host ("{0,-28}" -f $label) -NoNewline -ForegroundColor $(if ($differ -and $k -ne '_age') { 'Yellow' } else { 'Gray' })
    foreach ($i in 0..($names.Count - 1)) { Write-Host (" | {0}: {1}" -f $names[$i], $(if ($vals[$i].Length -gt 60) { $vals[$i].Substring(0, 57) + '...' } else { $vals[$i] })) -NoNewline }
    Write-Host ''
  }
}
$out = Join-Path $StateDir 'COMPARE.md'
[IO.File]::WriteAllLines($out, [string[]]$md, (New-Object Text.UTF8Encoding $false))
Write-Host "$($names.Count) cabinet(s), $diffs row(s) differ -> $out"
