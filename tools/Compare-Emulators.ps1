<#
.SYNOPSIS
  Are the cabinets running the same emulators? (James 2026-11-28: "can we ensure both systems emulators are the same
  ones? But I won't know which emulator is the better emulator".)
    -Inventory  this cabinet's program files (exe / dll) of every emulator the frontend has (<RetroFE>\emulators, links
                followed), with size, file version, date and SHA-1, to <Share>\<COMPUTERNAME>.json. Settings, saves,
                ROMs and backups are not program files and are left out: they are meant to differ per cabinet.
    -Compare    reads every cabinet's inventory on the share and writes <Share>\compare.md: per emulator, the files that
                differ (or exist on one cabinet only), with each side's version, size and date. Which build to keep is
                decided from that and from what was tested and played on each cabinet; nothing is copied here.
  Read-only apart from the two report files.
.EXAMPLE
  tools\Compare-Emulators.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -Inventory
  tools\Compare-Emulators.ps1 -Compare
#>
param(
  [string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Share = 'Z:\ArcadeMaster\reports\emulators',
  [switch]$Inventory,
  [switch]$Compare
)
$ErrorActionPreference = 'Stop'
if (-not $Inventory -and -not $Compare) { throw 'give -Inventory (this cabinet) and/or -Compare (all cabinets on the share)' }
New-Item -ItemType Directory -Force $Share | Out-Null
function Get-RealPath([string]$p) {
  $full = (Get-Item -LiteralPath $p).FullName; $parts = $full.TrimEnd([char]92).Split([char]92); $cur = $parts[0] + [char]92
  for ($k = 1; $k -lt $parts.Count; $k++) {
    $cur = Join-Path $cur $parts[$k]; $i = Get-Item -LiteralPath $cur -ErrorAction SilentlyContinue
    if ($i -and $i.LinkType -and $i.Target) { $t = [string]@($i.Target)[0]; if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path $cur) $t }; $cur = $t }
  }
  $cur
}

if ($Inventory) {
  if (-not $RetroFE) { throw '-Inventory needs -RetroFE' }
  $emu = Join-Path $RetroFE 'emulators'
  # folders that hold backups or spare copies, not the program that runs
  $skipDir = '(?i)\\(am-update-backup[^\\]*|_before[^\\]*|[^\\]*\.am-[^\\]*|[^\\]*\.bak|backup[^\\]*|saves?|nvram|roms?|user|screenshots?|shots|logs?|cache[^\\]*|shader[^\\]*)(\\|$)'
  $out = [ordered]@{ host = $env:COMPUTERNAME; when = (Get-Date).ToString('s'); retrofe = $RetroFE; emulators = [ordered]@{} }
  foreach ($d in Get-ChildItem -LiteralPath $emu -Directory | Sort-Object Name) {
    $real = Get-RealPath $d.FullName
    # by extension, not -Include: Windows PowerShell 5.1 ignores -Include together with -LiteralPath and lists every file
    $files = @(Get-ChildItem -LiteralPath $real -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { ($_.Extension -eq '.exe' -or $_.Extension -eq '.dll') -and $_.FullName.Substring($real.Length) -notmatch $skipDir })
    $list = [ordered]@{}
    foreach ($f in $files | Sort-Object FullName) {
      $rel = $f.FullName.Substring($real.Length).TrimStart([char]92)
      $list[$rel] = [ordered]@{ size = $f.Length; version = [string]$f.VersionInfo.FileVersion; date = $f.LastWriteTime.ToString('yyyy-MM-dd'); sha1 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA1).Hash.Substring(0, 16) }
    }
    $out.emulators[$d.Name] = [ordered]@{ path = $real; files = $list }
    Write-Host ("{0,-28} {1,5} program files" -f $d.Name, $list.Count)
  }
  $f = Join-Path $Share "$env:COMPUTERNAME.json"
  $out | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $f -Encoding UTF8
  Write-Host "inventory: $f"
}

if ($Compare) {
  $inv = @(Get-ChildItem -LiteralPath $Share -Filter *.json | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
  if ($inv.Count -lt 2) { Write-Host "compare: only $($inv.Count) cabinet inventory on $Share - run -Inventory on the others"; return }
  $hosts = @($inv | ForEach-Object { $_.host } | Sort-Object)
  $md = New-Object System.Collections.Generic.List[string]
  $md.Add("# Emulators on the cabinets"); $md.Add('')
  $md.Add("Made $(Get-Date -Format 'yyyy-MM-dd HH:mm') by tools/Compare-Emulators.ps1 from: " + (($inv | ForEach-Object { "$($_.host) ($($_.when))" }) -join ', ') + '.'); $md.Add('')
  $md.Add('Program files only (exe / dll). Settings, saves and ROMs are left out: they are meant to differ per cabinet.'); $md.Add('')
  $names = @($inv | ForEach-Object { $_.emulators.PSObject.Properties.Name } | Sort-Object -Unique)
  $same = @(); $summary = @()
  foreach ($n in $names) {
    $have = @($inv | Where-Object { $_.emulators.PSObject.Properties.Name -contains $n })
    if ($have.Count -lt $hosts.Count) { $summary += "| $n | only on $((@($have | ForEach-Object { $_.host })) -join ', ') | |"; continue }
    $rel = @($have | ForEach-Object { $_.emulators.$n.files.PSObject.Properties.Name } | Sort-Object -Unique)
    $diff = @()
    foreach ($r in $rel) {
      $vals = @($have | ForEach-Object { $_.emulators.$n.files.$r })
      $shas = @($vals | Where-Object { $_ } | ForEach-Object { $_.sha1 } | Sort-Object -Unique)
      if ($vals.Count -eq $have.Count -and @($vals | Where-Object { -not $_ }).Count -eq 0 -and $shas.Count -eq 1) { continue }
      $diff += , @($r, @($have | ForEach-Object { $v = $_.emulators.$n.files.$r; if ($v) { "$($v.version) $($v.size) B $($v.date)".Trim() } else { '(missing)' } }))
    }
    if (-not $diff) { $same += $n; continue }
    $summary += "| $n | $($diff.Count) of $($rel.Count) files differ | see below |"
    $md.Add("## $n"); $md.Add('')
    $md.Add('| File | ' + ((@($have | ForEach-Object { $_.host })) -join ' | ') + ' |')
    $md.Add('|---|' + ((@($have | ForEach-Object { '---' })) -join '|') + '|')
    foreach ($row in $diff | Select-Object -First 25) { $md.Add("| $($row[0]) | " + ($row[1] -join ' | ') + ' |') }
    if ($diff.Count -gt 25) { $md.Add("| ... $($diff.Count - 25) more | |") }
    $md.Add('')
  }
  $md.Insert(6, ''); $md.Insert(6, ("**The same on every cabinet:** " + $(if ($same) { $same -join ', ' } else { 'none' })))
  $md.Insert(6, ''); foreach ($s in @($summary) + @('|---|---|---|', '| Emulator | Difference | |') ) { $md.Insert(6, $s) }
  $f = Join-Path $Share 'compare.md'
  [IO.File]::WriteAllText($f, ($md -join "`r`n"), (New-Object Text.UTF8Encoding $false))
  Write-Host "same everywhere: $($same.Count) emulator(s); different: $(@($summary).Count) - $f"
}
