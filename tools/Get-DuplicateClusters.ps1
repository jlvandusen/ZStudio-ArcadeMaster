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

# --- variant check: is each other copy an exact copy of the keeper, or a variant (standalone vs multicab,
#     patched exe, different revision)? Compare by relative path + size, ignoring run-time noise.
$noise = '(?i)\.(log|dmp|tmp)$|shader_cache|\\_archives\\| - copy\.|\\log_[^\\]+\\|\\crash'
function Get-Tree([string]$dir) {
  $h = @{}; if (-not (Test-Path -LiteralPath $dir)) { return $h }
  foreach ($p in [IO.Directory]::EnumerateFiles($dir, '*', [IO.SearchOption]::AllDirectories)) {
    $rel = $p.Substring($dir.Length + 1).ToLower(); if ($rel -match $noise) { continue }; $h[$rel] = ([IO.FileInfo]$p).Length }
  $h
}
function Compare-Tree($a, $b) {
  # try aligning b by dropping 0..2 leading folders (e.g. "Sega\Daytona\..." vs "Daytona\...")
  function Drop-Prefix($t, [int]$n) { if ($n -eq 0) { return $t }; $o = @{}; foreach ($k in $t.Keys) { $parts = $k.Split('\'); if ($parts.Count -le $n) { continue }; $o[($parts[$n..($parts.Count - 1)] -join '\')] = $t[$k] }; $o }
  $best = $null
  foreach ($da in 0..2) { foreach ($db in 0..2) {
    if ($da -gt 0 -and $db -gt 0) { continue }                                     # align one side at a time
    $aa = Drop-Prefix $a $da; $bb = Drop-Prefix $b $db
    if ($aa.Count -lt $a.Count * 0.5 -or $bb.Count -lt $b.Count * 0.5) { continue } # dropping lost most of the tree
    $diff = @($bb.Keys | Where-Object { -not $aa.ContainsKey($_) -or $aa[$_] -ne $bb[$_] }) + @($aa.Keys | Where-Object { -not $bb.ContainsKey($_) })
    if (-not $best -or $diff.Count -lt $best.Diff.Count) { $best = @{ Drop = $db - $da; Diff = @($diff | Sort-Object -Unique) } }
  } }
  $best
}
foreach ($row in $rows) {
  $keepTree = Get-Tree $row.Keep; $notes = @()
  foreach ($o in ($row.Others -split ' \| ' | Where-Object { $_ })) {
    $cmp = Compare-Tree $keepTree (Get-Tree $o)
    $kind = if ($cmp.Diff.Count -eq 0) { 'COPY' } elseif ($cmp.Diff.Count -le 60) { "VARIANT ($($cmp.Diff.Count) files differ: $((($cmp.Diff | Select-Object -First 5) -join ', '))$(if ($cmp.Diff.Count -gt 5) { ', ...' }))" } else { "DIFFERENT ($($cmp.Diff.Count) files differ)" }
    if ($cmp.Drop -ne 0) { $kind += " [folder nesting differs by $([Math]::Abs($cmp.Drop))]" }
    if ($o -match '(?i)multi|link|network|2017|ver\.|version|export|japan|usa') { $kind += ' [name suggests a separate version]' }
    $notes += "$o => $kind"
  }
  $row | Add-Member -NotePropertyName Variants -NotePropertyValue ($notes -join ' || ')
}
$rows | Export-Csv (Join-Path $OutDir 'clusters.csv') -NoTypeInformation -Encoding utf8

$total = ($rows | Measure-Object ReclaimGB -Sum).Sum
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine("# Duplicate clusters ($(Get-Date -Format yyyy-MM-dd))")
[void]$md.AppendLine('')
[void]$md.AppendLine("MD5-verified identical files grouped by game folder. **Reclaimable if one copy per cluster is kept: $([Math]::Round($total,1)) GB** across $($rows.Count) clusters (>= $MinClusterGB GB each).")
[void]$md.AppendLine('"Keep" is only a suggestion: prefer the SSD (D:) copy, skip folders named broke/backup/copy.')
[void]$md.AppendLine('**COPY** = identical to the keeper (logs, dumps and shader caches ignored), safe to drop after approval. **VARIANT** = shares the bulk data but has its own config/patch files (e.g. Daytona standalone vs multicab). Keep it as base + overlay, never delete it. **DIFFERENT** = a separate version; keep it.')
[void]$md.AppendLine('"Reclaim GB" is the upper bound if every other folder were an exact copy. Variants reduce it.')
[void]$md.AppendLine('')
[void]$md.AppendLine('| Reclaim GB | Copies | Suggested keep | Other copies |')
[void]$md.AppendLine('|---:|---:|---|---|')
$tick = [char]96
function Format-Code([string]$s) { '{0}{1}{0}' -f $tick, $s }
foreach ($r in $rows) {
  $others = ($r.Variants -split ' \|\| ' | Where-Object { $_ } | ForEach-Object { $pp = $_ -split ' => ', 2; '{0} **{1}**' -f (Format-Code $pp[0]), $pp[1] }) -join '<br>'
  [void]$md.AppendLine(('| {0} | {1} | {2} | {3} |' -f $r.ReclaimGB, $r.Copies, (Format-Code $r.Keep), $others))
}
Set-Content (Join-Path $OutDir 'clusters.md') $md.ToString() -Encoding utf8
Write-Host ("clusters: {0}  reclaimable: {1:N1} GB  -> {2}" -f $rows.Count, $total, (Join-Path $OutDir 'clusters.md'))
