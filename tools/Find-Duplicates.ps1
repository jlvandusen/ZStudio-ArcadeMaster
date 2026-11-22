<#
.SYNOPSIS
  Read-only duplicate finder for the arcade game trees.
  Size-group -> 64KB prefix hash -> full MD5. Writes CSV reports; never modifies scanned files.
.OUTPUTS
  <OutDir>\files.csv          every scanned file (Path,Size)
  <OutDir>\dupes.csv          confirmed duplicate files (Hash,Size,Path)
  <OutDir>\folder-pairs.csv   shared bytes aggregated per (game folder A, game folder B)
  <OutDir>\progress.log
#>
param(
  [string[]]$Roots = @('D:\Arcade PC','E:\DRIVE Collection','E:\Raw Thrills','D:\LaunchBox\Games','D:\LaunchBox\Videos','D:\Emulators'),
  [string]$OutDir = (Join-Path $PSScriptRoot '..\reports\dupes'),
  [long]$MinSize = 65536,
  # path depth (below root) that identifies a "game folder" for aggregation
  [int]$FolderDepth = 2,
  # skip enumeration and load <OutDir>\files.csv from a previous run
  [switch]$ReuseFileList
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$log = Join-Path $OutDir 'progress.log'
function Write-Log($m){ $l = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $m; Add-Content -Path $log -Value $l -Encoding utf8; Write-Host $l }

# ---------- 1. enumerate (manual walk: survives access-denied, skips reparse points)
$files = New-Object 'System.Collections.Generic.List[object]'
$filesCsv = Join-Path $OutDir 'files.csv'
if ($ReuseFileList -and (Test-Path $filesCsv)) {
  Write-Log "reusing $filesCsv"
  foreach ($r in [IO.File]::ReadLines($filesCsv) | Select-Object -Skip 1) {
    $c = $r.Split([char]','); if ($c.Count -lt 3) { continue }
    $files.Add([pscustomobject]@{ Root = $c[0].Trim('"'); Path = ($c[1..($c.Count - 2)] -join ',').Trim('"'); Size = [long]$c[-1].Trim('"') })
  }
  Write-Log ("loaded {0:N0} files" -f $files.Count)
}
else {
foreach ($root in $Roots) {
  if (-not (Test-Path -LiteralPath $root)) { Write-Log "skip missing root $root"; continue }
  $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
  $stack.Push([IO.DirectoryInfo]$root); $n0 = $files.Count
  while ($stack.Count) {
    $d = $stack.Pop()
    try { $entries = $d.GetFileSystemInfos() } catch { Write-Log "denied: $($d.FullName)"; continue }
    foreach ($e in $entries) {
      if ($e.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
      if ($e -is [IO.DirectoryInfo]) { $stack.Push($e) }
      else { $files.Add([pscustomobject]@{ Root = $root; Path = $e.FullName; Size = $e.Length }) }
    }
  }
  Write-Log ("enumerated {0:N0} files in {1}" -f ($files.Count - $n0), $root)
}
$files | Export-Csv $filesCsv -NoTypeInformation -Encoding utf8
}

# ---------- 2. size groups (Dictionary, not Group-Object: PS 5.1 Group-Object stalls on 1M+ items)
$bySize = New-Object 'System.Collections.Generic.Dictionary[long,System.Collections.Generic.List[object]]'
foreach ($f in $files) {
  if ($f.Size -lt $MinSize) { continue }
  $l = $null
  if (-not $bySize.TryGetValue($f.Size, [ref]$l)) { $l = New-Object 'System.Collections.Generic.List[object]'; $bySize[$f.Size] = $l }
  $l.Add($f)
}
$cands = foreach ($kv in $bySize.GetEnumerator()) { if ($kv.Value.Count -gt 1) { [pscustomobject]@{ Group = $kv.Value } } }
$candFiles = @($cands | ForEach-Object { $_.Group })
$candBytes = ($candFiles | Measure-Object Size -Sum).Sum
Write-Log ("size-collision candidates: {0:N0} files, {1:N1} GB" -f $candFiles.Count, ($candBytes / 1GB))

$md5 = [Security.Cryptography.MD5]::Create()
function Get-PrefixHash($p) {
  $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
  try { $buf = New-Object byte[] 65536; $n = $fs.Read($buf, 0, $buf.Length); [BitConverter]::ToString($md5.ComputeHash($buf, 0, $n)) } finally { $fs.Dispose() }
}
function Get-FullHash($p) {
  # explicit types: with string enums PS 5.1 reports "Multiple ambiguous overloads" for this ctor
  $fs = [IO.FileStream]::new($p, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, [int]1MB, [IO.FileOptions]::SequentialScan)
  try { [BitConverter]::ToString($md5.ComputeHash($fs)) } finally { $fs.Dispose() }
}

# ---------- 3. prefix hash filter
$i = 0; $survivors = New-Object 'System.Collections.Generic.List[object]'
foreach ($g in $cands) {
  $byPrefix = @{}
  foreach ($f in $g.Group) {
    $i++; if ($i % 5000 -eq 0) { Write-Log ("prefix {0:N0}/{1:N0}" -f $i, $candFiles.Count) }
    try { $h = Get-PrefixHash $f.Path } catch { continue }
    if (-not $byPrefix.ContainsKey($h)) { $byPrefix[$h] = New-Object 'System.Collections.Generic.List[object]' }
    $byPrefix[$h].Add($f)
  }
  foreach ($l in $byPrefix.Values) { if ($l.Count -gt 1) { foreach ($f in $l) { $survivors.Add($f) } } }
}
$survivors | Export-Csv (Join-Path $OutDir 'survivors.csv') -NoTypeInformation -Encoding utf8
$survBytes = ($survivors | Measure-Object Size -Sum).Sum
Write-Log ("prefix survivors: {0:N0} files, {1:N1} GB -> full hashing" -f $survivors.Count, ($survBytes / 1GB))

# ---------- 4. full hash (largest first so the report is useful early if interrupted)
$dupOut = Join-Path $OutDir 'dupes-raw.csv'
'"Hash","Size","Path"' | Set-Content $dupOut -Encoding utf8
$done = 0L; $sw = [Diagnostics.Stopwatch]::StartNew()
foreach ($f in ($survivors | Sort-Object Size -Descending)) {
  try { $h = Get-FullHash $f.Path } catch { Write-Log "hash fail: $($f.Path)"; continue }
  ('"{0}","{1}","{2}"' -f $h, $f.Size, $f.Path) | Add-Content $dupOut -Encoding utf8
  $done += $f.Size
  if ($sw.Elapsed.TotalSeconds -ge 60) { Write-Log ("hashed {0:N1}/{1:N1} GB" -f ($done / 1GB), ($survBytes / 1GB)); $sw.Restart() }
}

# ---------- 5. confirmed dupes + folder-pair aggregation
$byHash = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[object]]'
foreach ($r in Import-Csv $dupOut) {
  $k = "$($r.Hash)|$($r.Size)"; $l = $null
  if (-not $byHash.TryGetValue($k, [ref]$l)) { $l = New-Object 'System.Collections.Generic.List[object]'; $byHash[$k] = $l }
  $l.Add($r)
}
$groups = @(foreach ($kv in $byHash.GetEnumerator()) { if ($kv.Value.Count -gt 1) { [pscustomobject]@{ Group = $kv.Value; Count = $kv.Value.Count } } })
$groups | ForEach-Object { $_.Group } | Export-Csv (Join-Path $OutDir 'dupes.csv') -NoTypeInformation -Encoding utf8
$waste = ($groups | ForEach-Object { [long]$_.Group[0].Size * ($_.Count - 1) } | Measure-Object -Sum).Sum
Write-Log ("CONFIRMED duplicate groups: {0:N0}; reclaimable {1:N1} GB" -f $groups.Count, ($waste / 1GB))

function Get-GameFolder($p) {
  $m = [regex]::Match($p, '^(.*?\\roms\\[^\\]+)\\', 'IgnoreCase')   # RetroFE collections\<c>\roms\<game>
  if ($m.Success) { return $m.Groups[1].Value }
  foreach ($r in $Roots) {
    if ($p.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) {
      $rel = $p.Substring($r.Length + 1).Split('\')
      $take = [Math]::Min($FolderDepth, $rel.Count - 1); if ($take -lt 1) { return $r }
      return (Join-Path $r ($rel[0..($take - 1)] -join '\'))
    }
  }
  return (Split-Path $p)
}
$pairs = @{}
foreach ($g in $groups) {
  $folders = @($g.Group | ForEach-Object { Get-GameFolder $_.Path } | Sort-Object -Unique)
  for ($a = 0; $a -lt $folders.Count; $a++) { for ($b = $a + 1; $b -lt $folders.Count; $b++) {
    $k = "$($folders[$a])|$($folders[$b])"; $pairs[$k] = [long]$pairs[$k] + [long]$g.Group[0].Size } }
}
$pairs.GetEnumerator() | ForEach-Object { $ab = $_.Key.Split('|'); [pscustomobject]@{ FolderA = $ab[0]; FolderB = $ab[1]; SharedGB = [Math]::Round($_.Value / 1GB, 2) } } |
  Sort-Object SharedGB -Descending | Export-Csv (Join-Path $OutDir 'folder-pairs.csv') -NoTypeInformation -Encoding utf8
Write-Log 'DONE'
