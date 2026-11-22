<#
.SYNOPSIS
  Turns Find-Duplicates output (dupes.csv) into per-game clusters: which folders are copies of the same
  game, how much each copy shares, and what is reclaimable if one copy is kept. Read-only.
  Writes <OutDir>\clusters.md (human summary, safe to commit) and clusters.csv.
#>
param(
  [string]$OutDir = (Join-Path $PSScriptRoot '..\reports\dupes'),
  [double]$MinClusterGB = 0.25,
  [string[]]$Roots = @('D:\Arcade PC', 'E:\DRIVE Collection', 'E:\Raw Thrills', 'D:\LaunchBox\Games', 'D:\LaunchBox\Videos', 'D:\Emulators'),
  [int]$FolderDepth = 2
)
$ErrorActionPreference = 'Stop'
$OutDir = (Resolve-Path $OutDir).Path
function Get-GameFolder([string]$p) {
  $m = [regex]::Match($p, '^(.*?\\roms\\[^\\]+)\\', 'IgnoreCase'); if ($m.Success) { return $m.Groups[1].Value }
  foreach ($r in $Roots) {
    if ($p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) {
      $rel = $p.Substring($r.Length + 1).Split('\'); $take = [Math]::Min($FolderDepth, $rel.Count - 1)
      if ($take -lt 1) { return $r }; return (Join-Path $r ($rel[0..($take - 1)] -join '\'))
    }
  }
  Split-Path $p
}

# --- load groups
$groups = @{}
foreach ($r in Import-Csv (Join-Path $OutDir 'dupes.csv')) {
  $k = "$($r.Hash)|$($r.Size)"
  if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object 'System.Collections.Generic.List[string]' }
  $groups[$k].Add($r.Path)
}

# --- folder totals (to judge "is this folder mostly a copy of that one")
$folderTotal = @{}
foreach ($line in [IO.File]::ReadLines((Join-Path $OutDir 'files.csv')) | Select-Object -Skip 1) {
  $c = $line.Split([char]','); if ($c.Count -lt 3) { continue }
  $p = ($c[1..($c.Count - 2)] -join ',').Trim('"'); $f = Get-GameFolder $p
  $folderTotal[$f] = [long]$folderTotal[$f] + [long]$c[-1].Trim('"')
}

# --- pairwise shared bytes, ignoring files spread over many folders (shared runtimes/middleware)
$MaxSpread = 12
$pairShared = @{}
$folderBytes = @{}   # folder -> bytes that are duplicated elsewhere
$groupFolders = @{}
foreach ($k in $groups.Keys) {
  $size = [long]$k.Split('|')[1]
  $fs = @($groups[$k] | ForEach-Object { Get-GameFolder $_ } | Sort-Object -Unique)
  $groupFolders[$k] = $fs
  foreach ($f in $fs) { $folderBytes[$f] = [long]$folderBytes[$f] + $size }
  if ($fs.Count -lt 2 -or $fs.Count -gt $MaxSpread) { continue }
  for ($i = 0; $i -lt $fs.Count; $i++) { for ($j = $i + 1; $j -lt $fs.Count; $j++) { $pk = "$($fs[$i])|$($fs[$j])"; $pairShared[$pk] = [long]$pairShared[$pk] + $size } }
}

# --- union-find: link folders only when they are substantially the same content
$parent = @{}
foreach ($f in $folderBytes.Keys) { $parent[$f] = $f }
function Find([string]$x) { while ($parent[$x] -ne $x) { $parent[$x] = $parent[$parent[$x]]; $x = $parent[$x] }; $x }
function Union([string]$a, [string]$b) { $ra = Find $a; $rb = Find $b; if ($ra -ne $rb) { $parent[$rb] = $ra } }
foreach ($pk in $pairShared.Keys) {
  $ab = $pk.Split('|'); $shared = $pairShared[$pk]
  $small = [Math]::Max([long]1, [Math]::Min([long]$folderTotal[$ab[0]], [long]$folderTotal[$ab[1]]))
  if ($shared -ge 100MB -and $shared / $small -ge 0.5) { Union $ab[0] $ab[1] }
}

# --- aggregate per cluster
$clusters = @{}
foreach ($k in $groups.Keys) {
  $size = [long]$k.Split('|')[1]
  $perRoot = @{}
  foreach ($p in $groups[$k]) { $rt = Find (Get-GameFolder $p); $perRoot[$rt] = [int]$perRoot[$rt] + 1 }
  foreach ($rt in $perRoot.Keys) {
    if ($perRoot[$rt] -lt 2) { continue }                 # copies in different clusters don't free space by keeping one per cluster
    if (-not $clusters.ContainsKey($rt)) { $clusters[$rt] = @{ Waste = 0L; Folders = @{} } }
    $clusters[$rt].Waste += $size * ($perRoot[$rt] - 1)
  }
}
foreach ($f in @($parent.Keys)) { $rt = Find $f; if ($clusters.ContainsKey($rt)) { $clusters[$rt].Folders[$f] = $true } }
$rows = foreach ($c in $clusters.Values) {
  $gb = $c.Waste / 1GB; if ($gb -lt $MinClusterGB) { continue }
  $folders = @($c.Folders.Keys | Sort-Object { -[long]$folderBytes[$_] })
  # suggested keeper: SSD (D:) copy with the most duplicated content; avoid names hinting at broken/backup copies
  $keep = $folders | Where-Object { $_ -notmatch '(?i)\.broke|backup|copy|old' } | Sort-Object { if ($_ -like 'D:*') { 0 } else { 1 } }, { -[long]$folderBytes[$_] } | Select-Object -First 1
  if (-not $keep) { $keep = $folders[0] }
  [pscustomobject]@{ ReclaimGB = [Math]::Round($gb, 2); Copies = $folders.Count; Keep = $keep; Others = (($folders | Where-Object { $_ -ne $keep }) -join ' | ') }
}
$rows = @($rows | Sort-Object ReclaimGB -Descending)
$rows | Export-Csv (Join-Path $OutDir 'clusters.csv') -NoTypeInformation -Encoding utf8

$total = ($rows | Measure-Object ReclaimGB -Sum).Sum
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Duplicate clusters ($(Get-Date -Format yyyy-MM-dd))")
[void]$md.AppendLine('')
[void]$md.AppendLine("MD5-verified identical files grouped by game folder. **Reclaimable if one copy per cluster is kept: $([Math]::Round($total,1)) GB** across $($rows.Count) clusters (>= $MinClusterGB GB each).")
[void]$md.AppendLine('"Keep" is only a suggestion: prefer the SSD (D:) copy, skip folders named broke/backup/copy. Partial clusters (copies that differ) need a per-game decision before anything is removed.')
[void]$md.AppendLine('')
[void]$md.AppendLine('| Reclaim GB | Copies | Suggested keep | Other copies |')
[void]$md.AppendLine('|---:|---:|---|---|')
$tick = [char]96
function Format-Code([string]$s) { '{0}{1}{0}' -f $tick, $s }
foreach ($r in $rows) {
  $others = ($r.Others -split ' \| ' | ForEach-Object { Format-Code $_ }) -join '<br>'
  [void]$md.AppendLine(('| {0} | {1} | {2} | {3} |' -f $r.ReclaimGB, $r.Copies, (Format-Code $r.Keep), $others))
}
Set-Content (Join-Path $OutDir 'clusters.md') $md.ToString() -Encoding utf8
Write-Host ("clusters: {0}  reclaimable: {1:N1} GB  -> {2}" -f $rows.Count, $total, (Join-Path $OutDir 'clusters.md'))
