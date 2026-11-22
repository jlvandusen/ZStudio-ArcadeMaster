<#
.SYNOPSIS
  READ-ONLY survey of every arcade frontend on this machine, so ArcadeMaster can borrow artwork and flow from them
  (built for the 4-player pedestal, which carries several CoinOPS builds - Core and others - plus other frontends).
  Finds: RetroFE / CoinOPS, LaunchBox / BigBox, Attract-Mode, HyperSpin, EmulationStation / ES-DE, Pegasus,
         RocketLauncher, Playnite.
  For RetroFE/CoinOPS it records each layout (resolution, monitors, video/sound use, the artwork types it reads),
  the collections (game counts, artwork folders + file counts) and the menu FLOW (Main -> sub-menus -> collections).
  Writes reports\frontends\<COMPUTER>.md + .json and a contact sheet of layout art (<COMPUTER>-layouts.png).
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\Survey-Frontends.ps1               # all fixed drives
  powershell -ExecutionPolicy Bypass -File tools\Survey-Frontends.ps1 -Roots E:\,F:\Arcade
#>
param(
  [string[]]$Roots,
  [int]$MaxDepth = 4,
  [string]$OutDir = (Join-Path $PSScriptRoot '..\reports\frontends')
)
$ErrorActionPreference = 'Stop'
if (-not $Roots) { $Roots = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null -and $_.Root -match '^[A-Z]:\\$' } | ForEach-Object { $_.Root }) }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

$markers = [ordered]@{
  'retrofe.exe' = 'RetroFE'; 'core\retrofe.exe' = 'RetroFE'; 'retrofe\retrofe.exe' = 'RetroFE'
  'LaunchBox.exe' = 'LaunchBox'; 'BigBox.exe' = 'BigBox'; 'attract.exe' = 'Attract-Mode'; 'attractplus.exe' = 'Attract-Mode Plus'
  'HyperSpin.exe' = 'HyperSpin'; 'EmulationStation.exe' = 'EmulationStation'; 'ES-DE.exe' = 'ES-DE'; 'pegasus-fe.exe' = 'Pegasus'
  'RocketLauncher.exe' = 'RocketLauncher'; 'Playnite.FullscreenApp.exe' = 'Playnite'
}
$skip = '^(roms?|medium_artwork|system_artwork|images?|videos?|snaps?|music|sounds|saves?|states|nvram|cfg|artwork|samples|\$recycle\.bin|system volume information|windows|program files.*|programdata|users|msocache|recovery)$'

# ---------- find frontend roots (directory walk, no file enumeration of game folders)
$found = New-Object Collections.Generic.List[object]
foreach ($r in $Roots) {
  $q = New-Object Collections.Generic.Queue[object]; $q.Enqueue(@($r, 0))
  while ($q.Count) {
    $item = $q.Dequeue(); $dir = $item[0]; $depth = $item[1]
    foreach ($m in $markers.Keys) { if (Test-Path -LiteralPath (Join-Path $dir $m)) { $found.Add([pscustomobject]@{ kind = $markers[$m]; root = $dir; exe = (Join-Path $dir $m) }) } }
    if ($depth -ge $MaxDepth) { continue }
    try { foreach ($d in [IO.Directory]::EnumerateDirectories($dir)) { if ((Split-Path $d -Leaf) -notmatch $skip) { $q.Enqueue(@($d, $depth + 1)) } } } catch { }
  }
}
# one entry per install: CoinOPS keeps the exe in core\ or retrofe\, LaunchBox in Core\ - fold those into the parent
$found = @($found | ForEach-Object {
  $r = $_.root; $leaf = Split-Path $r -Leaf
  if ($leaf -match '^(core|retrofe(-.*)?)$' -and $_.kind -eq 'RetroFE' -and (Test-Path (Join-Path (Split-Path $r) 'layouts'))) { $r = Split-Path $r }
  if ($leaf -eq 'Core' -and $_.kind -in 'LaunchBox', 'BigBox') { $r = Split-Path $r }
  [pscustomobject]@{ kind = $_.kind; root = $r; exe = $_.exe } } | Sort-Object root, kind -Unique)
$found = @($found | Where-Object { -not ($_.kind -eq 'RetroFE' -and -not (Test-Path (Join-Path $_.root 'layouts')) -and -not (Test-Path (Join-Path (Split-Path $_.root) 'layouts'))) })   # build folders without layouts
Write-Host ("found {0} frontend install(s)" -f $found.Count)

function Count-Files([string]$p, [int]$cap = 50000) { $n = 0; try { foreach ($f in [IO.Directory]::EnumerateFiles($p, '*', 'AllDirectories')) { $n++; if ($n -ge $cap) { break } } } catch { }; return $n }
function Read-Conf([string]$p) { $h = [ordered]@{}; if (Test-Path -LiteralPath $p) { foreach ($l in Get-Content -LiteralPath $p) { if ($l -match '^\s*([^#=\s][^=]*?)\s*=\s*(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() } } }; return $h }

$report = [ordered]@{ machine = $env:COMPUTERNAME; surveyed = (Get-Date).ToString('s'); roots = $Roots; frontends = @() }
$thumbs = New-Object Collections.Generic.List[object]
foreach ($fe in $found) {
  $entry = [ordered]@{ kind = $fe.kind; root = $fe.root; version = (Get-Item -LiteralPath $fe.exe).VersionInfo.ProductVersion }
  switch -Regex ($fe.kind) {
    '^RetroFE$' {
      # CoinOPS layouts: <root>\layouts or one level up when the exe lives in core\ / retrofe\
      $base = $fe.root; if (-not (Test-Path (Join-Path $base 'layouts')) -and (Test-Path (Join-Path (Split-Path $base) 'layouts'))) { $base = Split-Path $base }
      $entry.base = $base
      $set = Read-Conf (Join-Path $base 'settings.conf')
      $entry.settings = [ordered]@{ layout = $set['layout']; firstCollection = $set['firstCollection']; numScreens = $set['numScreens']; horizontal = $set['horizontal']; vertical = $set['vertical']; fullscreen = $set['fullscreen'] }
      $layouts = @()
      foreach ($ld in Get-ChildItem (Join-Path $base 'layouts') -Directory -ErrorAction SilentlyContinue) {
        $lx = Join-Path $ld.FullName 'layout.xml'; $info = [ordered]@{ name = $ld.Name }
        if (Test-Path $lx) {
          $xmlText = Get-Content $lx -Raw
          $m = [regex]::Match($xmlText, '<layout[^>]*\bwidth="(\d+)"[^>]*\bheight="(\d+)"'); if ($m.Success) { $info.resolution = "$($m.Groups[1].Value)x$($m.Groups[2].Value)" }
          $info.monitors = 1 + @(Get-ChildItem $ld.FullName -Filter 'layout - *.xml' -ErrorAction SilentlyContinue).Count
          $info.collectionLayouts = @(Get-ChildItem (Join-Path $ld.FullName 'collections') -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path (Join-Path $_.FullName 'layout\layout.xml') } | ForEach-Object { $_.Name })
          $info.artTypes = @([regex]::Matches($xmlText, '(?:type|imageType)="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
          $info.usesVideo = $xmlText -match '<reloadableVideo|<video'
          $info.sounds = @([regex]::Matches($xmlText, '<sound[^>]*type="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
          $info.animations = ([regex]::Matches($xmlText, '<animate')).Count
          $info.splash = Test-Path (Join-Path $ld.FullName 'splash.xml')
          $info.fonts = @(Get-ChildItem $ld.FullName -Recurse -Include *.ttf, *.otf -ErrorAction SilentlyContinue | Select-Object -First 8 | ForEach-Object { $_.Name })
          # biggest image as a preview of the look
          $img = Get-ChildItem $ld.FullName -Recurse -Include *.png, *.jpg -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 50KB } | Sort-Object Length -Descending | Select-Object -First 1
          if ($img) { $info.preview = $img.FullName; $thumbs.Add([pscustomobject]@{ label = "$($fe.kind) $($ld.Name)"; path = $img.FullName }) }
        }
        $layouts += $info
      }
      $entry.layouts = $layouts
      # collections + artwork
      $cols = @()
      foreach ($cd in Get-ChildItem (Join-Path $base 'collections') -Directory -ErrorAction SilentlyContinue) {
        $c = [ordered]@{ name = $cd.Name }
        $roms = Join-Path $cd.FullName 'roms'; if (Test-Path $roms) { $c.roms = @([IO.Directory]::EnumerateFileSystemEntries($roms) | Select-Object -First 20000).Count }
        $inc = Join-Path $cd.FullName 'include.txt'; if (Test-Path $inc) { $c.include = @(Get-Content $inc | Where-Object { $_.Trim() }).Count }
        $c.subs = @(Get-ChildItem $cd.FullName -Filter *.sub -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
        $art = [ordered]@{}
        foreach ($ad in Get-ChildItem (Join-Path $cd.FullName 'medium_artwork') -Directory -ErrorAction SilentlyContinue) { $art[$ad.Name] = Count-Files $ad.FullName 20000 }
        $c.artwork = $art
        $menu = Join-Path $cd.FullName 'menu.txt'; $mi = @(); if (Test-Path $menu) { $mi += @(Get-Content $menu | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) }
        $mi += @(Get-ChildItem (Join-Path $cd.FullName 'menu') -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.BaseName -replace '^\d+\s*[-_. ]?\s*', '' })
        if ($mi) { $c.menu = @($mi | Select-Object -Unique) }
        $cs = Read-Conf (Join-Path $cd.FullName 'settings.conf'); if ($cs['launcher']) { $c.launcher = $cs['launcher'] }
        $cols += $c
      }
      $entry.collections = $cols
      # flow: Main menu tree (2 levels)
      $byName = @{}; foreach ($c in $cols) { $byName[$c.name] = $c }
      $flow = @()
      $main = $byName['Main']
      if ($main -and $main.menu) { foreach ($m1 in $main.menu) { $node = [ordered]@{ name = $m1; children = @() }; if ($byName[$m1]) { if ($byName[$m1].menu) { $node.children = @($byName[$m1].menu) } elseif ($byName[$m1].subs) { $node.children = @($byName[$m1].subs | ForEach-Object { "$_ (merged)" }) } }; $flow += $node } }
      $entry.flow = $flow
    }
    'LaunchBox|BigBox' {
      $entry.bigBoxThemes = @(Get-ChildItem (Join-Path $fe.root 'Themes') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
      $entry.platforms = @(Get-ChildItem (Join-Path $fe.root 'Data\Platforms') -Filter *.xml -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
      $entry.imageTypes = [ordered]@{}; foreach ($p in Get-ChildItem (Join-Path $fe.root 'Images') -Directory -ErrorAction SilentlyContinue | Select-Object -First 40) { foreach ($t in Get-ChildItem $p.FullName -Directory -ErrorAction SilentlyContinue) { $entry.imageTypes[$t.Name] = [int]$entry.imageTypes[$t.Name] + 1 } }
      $entry.videos = Test-Path (Join-Path $fe.root 'Videos')
      foreach ($th in Get-ChildItem (Join-Path $fe.root 'Themes') -Directory -ErrorAction SilentlyContinue | Select-Object -First 12) { $img = Get-ChildItem $th.FullName -Recurse -Include *.png, *.jpg -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 50KB } | Sort-Object Length -Descending | Select-Object -First 1; if ($img) { $thumbs.Add([pscustomobject]@{ label = "BigBox $($th.Name)"; path = $img.FullName }) } }
    }
    'Attract' { $entry.layouts = @(Get-ChildItem (Join-Path $fe.root 'layouts') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }); $entry.romlists = @(Get-ChildItem (Join-Path $fe.root 'romlists') -Filter *.txt -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName }) }
    'HyperSpin' { $entry.mediaSystems = @(Get-ChildItem (Join-Path $fe.root 'Media') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
    'EmulationStation|ES-DE' { $entry.themes = @(Get-ChildItem $fe.root -Recurse -Directory -Filter themes -Depth 3 -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem $_.FullName -Directory | ForEach-Object { $_.Name } }) }
    'Pegasus' { $entry.themes = @(Get-ChildItem (Join-Path $fe.root 'themes') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
    'RocketLauncher' { $entry.modules = @(Get-ChildItem (Join-Path $fe.root 'Modules') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }).Count; $entry.media = @(Get-ChildItem (Join-Path $fe.root 'Media') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
  }
  $report.frontends += $entry
}

$base = Join-Path $OutDir $env:COMPUTERNAME
$report | ConvertTo-Json -Depth 8 | Set-Content "$base.json" -Encoding UTF8

# ---------- markdown summary
$md = New-Object Text.StringBuilder
[void]$md.AppendLine("# Frontends on $env:COMPUTERNAME"); [void]$md.AppendLine(''); [void]$md.AppendLine("Surveyed $($report.surveyed) - roots: $($Roots -join ', '). Read-only; nothing was changed."); [void]$md.AppendLine('')
foreach ($fe in $report.frontends) {
  [void]$md.AppendLine("## $($fe.kind) - ``$($fe.root)``$(if ($fe.version) { " (v$($fe.version))" })"); [void]$md.AppendLine('')
  if ($fe.kind -eq 'RetroFE') {
    [void]$md.AppendLine("Active layout **$($fe.settings.layout)**, first collection $($fe.settings.firstCollection), screens $($fe.settings.numScreens)."); [void]$md.AppendLine('')
    [void]$md.AppendLine('| Layout | Resolution | Monitors | Video | Animations | Art types | Per-collection layouts |'); [void]$md.AppendLine('|---|---|---|---|---|---|---|')
    foreach ($l in $fe.layouts) { [void]$md.AppendLine("| $($l.name) | $($l.resolution) | $($l.monitors) | $($l.usesVideo) | $($l.animations) | $((@($l.artTypes) | Select-Object -First 10) -join ', ') | $(@($l.collectionLayouts).Count) |") }
    [void]$md.AppendLine(''); [void]$md.AppendLine('**Menu flow**'); [void]$md.AppendLine('')
    foreach ($n in $fe.flow) { [void]$md.AppendLine("- $($n.name)"); foreach ($ch in $n.children) { [void]$md.AppendLine("  - $ch") } }
    [void]$md.AppendLine(''); [void]$md.AppendLine('| Collection | Games | Artwork (files) |'); [void]$md.AppendLine('|---|---|---|')
    foreach ($c in ($fe.collections | Sort-Object { -[int]$_.roms })) { $n = if ($c.roms) { $c.roms } elseif ($c.include) { $c.include } else { '' }; [void]$md.AppendLine("| $($c.name) | $n | $((@($c.artwork.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" })) -join ', ') |") }
  } else {
    foreach ($k in $fe.Keys) { if ($k -notin 'kind', 'root', 'version') { $v = $fe[$k]; if ($v -is [Collections.IDictionary]) { $v = ($v.GetEnumerator() | ForEach-Object { "$($_.Key) $($_.Value)" }) -join ', ' } elseif ($v -is [array]) { $v = ($v | Select-Object -First 40) -join ', ' }; [void]$md.AppendLine("- **$k**: $v") } }
  }
  [void]$md.AppendLine('')
}
[IO.File]::WriteAllText("$base.md", $md.ToString(), (New-Object Text.UTF8Encoding $false))

# ---------- contact sheet of layout / theme art (what each frontend looks like)
if ($thumbs.Count) {
  Add-Type -AssemblyName System.Drawing
  $cols = 4; $tw = 480; $th = 270; $rows = [Math]::Ceiling([Math]::Min(32, $thumbs.Count) / $cols)
  $sheet = New-Object Drawing.Bitmap ($cols * ($tw + 10) + 10), ($rows * ($th + 40) + 10); $g = [Drawing.Graphics]::FromImage($sheet); $g.Clear([Drawing.Color]::FromArgb(12, 12, 16))
  $font = New-Object Drawing.Font 'Segoe UI', 12; $i = 0
  foreach ($t in ($thumbs | Select-Object -First 32)) {
    $x = 10 + ($i % $cols) * ($tw + 10); $y = 10 + [Math]::Floor($i / $cols) * ($th + 40)
    try { $im = [Drawing.Image]::FromFile($t.path); $s = [Math]::Min($tw / $im.Width, $th / $im.Height); $g.DrawImage($im, [int]($x + ($tw - $im.Width * $s) / 2), [int]($y + ($th - $im.Height * $s) / 2), [int]($im.Width * $s), [int]($im.Height * $s)); $im.Dispose() } catch { }
    $g.DrawString($t.label, $font, [Drawing.Brushes]::White, [float]$x, [float]($y + $th + 6)); $i++
  }
  $g.Dispose(); $sheet.Save("$base-layouts.png", [Drawing.Imaging.ImageFormat]::Png); $sheet.Dispose()
}
Write-Host "report: $base.md / .json$(if ($thumbs.Count) { " / $base-layouts.png" })"
$report.frontends | ForEach-Object { Write-Host ("  {0,-14} {1}" -f $_.kind, $_.root) }
