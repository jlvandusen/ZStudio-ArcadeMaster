<#
.SYNOPSIS
  Imports a CoinOPS / Core / any RetroFE layout as an ArcadeMaster theme. The source is never modified and an existing
  theme is never overwritten (use -Force to replace a previously IMPORTED theme).
    1. copy  <source>\layouts\<Layout>  ->  <RetroFE>\layouts\<Prefix><Layout>   (robocopy)
    2. fix   every 'layout - N.xml' without monitor="N" (else RetroFE draws it over the main screen)
    3. carry ArcadeMaster's boot intro (studio logo -> cabinet title card) and the Tools screen into the theme,
       so they work whatever theme is active (the theme's own splash is kept as splash.original.xml)
    4. score how well this cabinet's artwork covers what the theme reads (per art type, per collection)
    5. preview: start RetroFE on the theme, screenshot, restore settings  (-NoPreview to skip)
    6. record it in <ManifestDir>\themes.json  (what Tools > Themes shows)
.EXAMPLE
  Import-RetroFETheme.ps1 -Source 'E:\CoinOPS Core' -Layout 'Arcade Deluxe'
  Import-RetroFETheme.ps1 -Source 'E:\CoinOPS Core' -All
#>
param(
  [Parameter(Mandatory)][string]$Source,
  [string[]]$Layout,
  [switch]$All,
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Prefix = 'CO-',
  [switch]$Force,
  [switch]$NoPreview,
  [switch]$NoIntro
)
$ErrorActionPreference = 'Stop'
$u8 = New-Object Text.UTF8Encoding $false
# source may be a RetroFE root, a CoinOPS root with core\, or a layouts folder
$srcLayouts = @((Join-Path $Source 'layouts'), (Join-Path (Split-Path $Source) 'layouts'), $Source) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $srcLayouts) { throw "no layouts folder under $Source" }
if ($All) { $Layout = @(Get-ChildItem $srcLayouts -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'layout.xml') } | ForEach-Object { $_.Name }) }
if (-not $Layout) { throw "-Layout or -All (available: $((Get-ChildItem $srcLayouts -Directory | ForEach-Object Name) -join ', '))" }
$ours = Join-Path $RetroFE 'layouts\ArcadeMaster'
$regFile = Join-Path $ManifestDir 'themes.json'
$reg = if (Test-Path $regFile) { Get-Content $regFile -Raw | ConvertFrom-Json } else { [pscustomobject]@{ themes = @() } }
$themes = New-Object Collections.Generic.List[object]; foreach ($t in @($reg.themes)) { $themes.Add($t) }

function Get-ArtTypes([string]$dir) {
  $types = @{}
  foreach ($x in Get-ChildItem $dir -Recurse -Filter *.xml -File) {
    $txt = [IO.File]::ReadAllText($x.FullName)
    foreach ($m in [regex]::Matches($txt, '<(reloadableImage|reloadableVideo|reloadableMedia|menu)\b[^>]*?\b(?:imageType|type)="([^"]+)"')) {
      $ty = $m.Groups[2].Value
      if ($ty -match '^(custom|vertical|horizontal|wheel|title|year|manufacturer|genre|numberPlayers|ctrlType|collectionName|firstLetter|playlist.*|position|numberButtons|rating|score|playCount|lastPlayed)$' -or $ty -like 'am_*') { continue }
      $types[$ty] = [int]$types[$ty] + $(if ($m.Groups[1].Value -eq 'menu') { 3 } else { 1 })   # menu art matters most
    }
  }
  return $types
}

foreach ($name in $Layout) {
  $src = Join-Path $srcLayouts $name
  if (-not (Test-Path (Join-Path $src 'layout.xml'))) { Write-Warning "${name}: no layout.xml - skipped"; continue }
  # a layout already inside this RetroFE install is registered in place (analysed + previewed, never copied or changed)
  $inPlace = ((Resolve-Path $srcLayouts).Path.TrimEnd('\') -eq (Resolve-Path (Join-Path $RetroFE 'layouts')).Path.TrimEnd('\'))
  $destName = if ($inPlace) { $name } else { "$Prefix$name" }
  $dest = Join-Path $RetroFE "layouts\$destName"
  $existing = $themes | Where-Object { $_.name -eq $destName } | Select-Object -First 1
  if ($inPlace) { Write-Host "registering installed layout $destName (in place, unchanged)"; $fixes = @() }
  elseif (Test-Path $dest) {
    if ($destName -eq 'ArcadeMaster' -or -not $existing -or -not $Force) { Write-Warning "$destName already exists$(if (-not $existing) { ' and was not imported by this tool' }) - not touched (use -Force to replace an imported theme)"; continue }
    Remove-Item $dest -Recurse -Force
  }
  if (-not $inPlace) {
  Write-Host "importing $src -> $dest"
  & robocopy $src $dest /E /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
  $fixes = @()

  # 2. second-screen layouts must say which monitor they are for
  foreach ($lf in Get-ChildItem $dest -Recurse -Filter 'layout - *.xml' -File) {
    if ($lf.BaseName -notmatch 'layout - (\d+)$') { continue }; $mon = $Matches[1]
    $txt = [IO.File]::ReadAllText($lf.FullName); $m = [regex]::Match($txt, '<layout\b[^>]*>')
    if ($m.Success -and $m.Value -notmatch '\bmonitor=') { $txt = $txt.Substring(0, $m.Index) + $m.Value.Replace('<layout', "<layout monitor=`"$mon`"") + $txt.Substring($m.Index + $m.Length); [IO.File]::WriteAllText($lf.FullName, $txt, $u8); $fixes += "$($lf.Name): monitor=`"$mon`"" }
  }

  # 3. ArcadeMaster boot intro + Tools screen inside the theme
  if (-not $NoIntro -and (Test-Path $ours)) {
    if ((Test-Path (Join-Path $dest 'splash.xml')) -and -not (Test-Path (Join-Path $dest 'splash.original.xml'))) { Move-Item (Join-Path $dest 'splash.xml') (Join-Path $dest 'splash.original.xml') }
    Copy-Item (Join-Path $ours 'splash.xml') (Join-Path $dest 'splash.xml') -Force
    New-Item -ItemType Directory -Force (Join-Path $dest 'images\intro'), (Join-Path $dest 'collections\Tools\layout'), (Join-Path $dest 'fonts'), (Join-Path $dest 'sounds') | Out-Null
    foreach ($f in 'black.png', 'fx_sun_glow.png', 'studio_realz.png', 'fx_vignette.png', 'bg_neutral.png', 'fx_scrim_gamelist.png', 'ui_select_frame.png') { $s = Join-Path $ours "images\$f"; $d = Join-Path $dest "images\$f"; if ((Test-Path $s) -and -not (Test-Path $d)) { Copy-Item $s $d } }
    Copy-Item (Join-Path $ours 'images\intro\*') (Join-Path $dest 'images\intro') -Force -ErrorAction SilentlyContinue
    Copy-Item (Join-Path $ours 'collections\Tools\layout\layout.xml') (Join-Path $dest 'collections\Tools\layout\layout.xml') -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path (Join-Path $dest 'fonts\OpenSans.ttf'))) { Copy-Item (Join-Path $ours 'fonts\OpenSans.ttf') (Join-Path $dest 'fonts\OpenSans.ttf') -ErrorAction SilentlyContinue }
    foreach ($s in Get-ChildItem (Join-Path $ours 'sounds') -File -ErrorAction SilentlyContinue) { if (-not (Test-Path (Join-Path $dest "sounds\$($s.Name)"))) { Copy-Item $s.FullName (Join-Path $dest "sounds\$($s.Name)") } }
    $fixes += 'ArcadeMaster boot intro + Tools screen added (theme splash kept as splash.original.xml)'
  }

  # 3b. main-menu art for OUR menu items (Racing, Flight, Tools ...): the theme only has art for its own items.
  #     Our neon logo is composited onto the theme's own default frame, so it keeps the theme's style. Gaps only.
  $menuItems = @(); $mt0 = Join-Path $RetroFE 'collections\Main\menu.txt'; if (Test-Path $mt0) { $menuItems = @(Get-Content $mt0 | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) }
  $menuItems += @(Get-ChildItem (Join-Path $RetroFE 'collections\Main\menu') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
  # games too: a commonlayout menu draws EVERY list (main menu and game lists) from the same art folder, so each game
  # in the merged mode collections gets its own logo on the theme's frame
  $gameLogos = @{}
  foreach ($mc in 'Racing', 'Flight', 'Lightgun', 'Arcade', 'GAMES') {
    foreach ($sf in Get-ChildItem (Join-Path $RetroFE "collections\$mc") -Filter *.sub -File -ErrorAction SilentlyContinue) {
      foreach ($gi in (Get-Content $sf.FullName | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })) {
        $lg = Get-ChildItem (Join-Path $RetroFE "collections\$($sf.BaseName)\medium_artwork\logo") -Filter "$gi.*" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($lg) { $gameLogos[$gi] = $lg.FullName }
      }
    }
  }
  $menuItems += @($gameLogos.Keys)
  $menuTypes = @{}
  foreach ($x in Get-ChildItem $dest -Recurse -Filter *.xml -File) { foreach ($m in [regex]::Matches([IO.File]::ReadAllText($x.FullName), '<menu\b[^>]*\bimageType="([^"]+)"[^>]*\bmode="commonlayout"|<menu\b[^>]*\bmode="commonlayout"[^>]*\bimageType="([^"]+)"')) { $menuTypes[($m.Groups[1].Value + $m.Groups[2].Value)] = $true } }
  if ($menuTypes.Count -and $menuItems) {
    Add-Type -AssemblyName System.Drawing; $made = 0
    foreach ($ty in $menuTypes.Keys) {
      $dir = Join-Path $dest "collections\_common\medium_artwork\$ty"; New-Item -ItemType Directory -Force $dir | Out-Null
      $frame = Get-ChildItem $dir -Filter 'default.*' -File -ErrorAction SilentlyContinue | Select-Object -First 1
      foreach ($it in ($menuItems | Select-Object -Unique)) {
        if (Get-ChildItem $dir -Filter "$it.*" -File -ErrorAction SilentlyContinue) { continue }
        $logo = if ($gameLogos.ContainsKey($it)) { $gameLogos[$it] } else { Join-Path $ours "collections\Main\medium_artwork\logo\$it.png" }
        if ($frame) { $bg = [Drawing.Image]::FromFile($frame.FullName); $bmp = New-Object Drawing.Bitmap $bg.Width, $bg.Height; $g = [Drawing.Graphics]::FromImage($bmp); $g.DrawImage($bg, 0, 0, $bg.Width, $bg.Height); $bg.Dispose() }
        else { $bmp = New-Object Drawing.Bitmap 1000, 200; $g = [Drawing.Graphics]::FromImage($bmp); $g.Clear([Drawing.Color]::Transparent) }
        $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBicubic'
        $box = New-Object Drawing.RectangleF ([float]($bmp.Width * 0.08)), ([float]($bmp.Height * 0.14)), ([float]($bmp.Width * 0.84)), ([float]($bmp.Height * 0.72))
        if (Test-Path $logo) { $li = [Drawing.Image]::FromFile($logo); $s = [Math]::Min($box.Width / $li.Width, $box.Height / $li.Height); $w = $li.Width * $s; $h = $li.Height * $s; $g.DrawImage($li, [float]($box.X + ($box.Width - $w) / 2), [float]($box.Y + ($box.Height - $h) / 2), [float]$w, [float]$h); $li.Dispose() }
        else { $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'; $g.DrawString($it.ToUpper(), (New-Object Drawing.Font('Segoe UI Black', [float]($box.Height * 0.45), [Drawing.FontStyle]::Italic, [Drawing.GraphicsUnit]::Pixel)), [Drawing.Brushes]::White, $box, $sf) }
        $g.Dispose(); $bmp.Save((Join-Path $dir "$it.png"), [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $made++
      }
    }
    if ($made) { $fixes += "main-menu art made for $made item(s) ($(@($menuTypes.Keys) -join ', ')) on the theme's own frame" }
  }
  }   # end of copy / fix steps (skipped for in-place registration)
  # 4. artwork coverage on THIS cabinet
  $types = Get-ArtTypes $dest
  $mainMenu = @(); $mt = Join-Path $RetroFE 'collections\Main\menu.txt'; if (Test-Path $mt) { $mainMenu = @(Get-Content $mt | Where-Object { $_.Trim() }) }
  $cols = @(Get-ChildItem (Join-Path $RetroFE 'collections') -Directory | Where-Object { $_.Name -notin 'Main', 'Tools', '_common' -and ($mainMenu -contains $_.Name -or (Test-Path (Join-Path $_.FullName 'roms'))) })
  $cover = [ordered]@{}; $gaps = @(); $wSum = 0; $wGot = 0
  foreach ($ty in ($types.Keys | Sort-Object)) {
    $have = 0; $total = 0
    foreach ($c in $cols) {
      $items = @(); $subs = @(Get-ChildItem $c.FullName -Filter *.sub -File -ErrorAction SilentlyContinue)
      if ($subs) { foreach ($s in $subs) { $items += @(Get-Content $s.FullName | Where-Object { $_.Trim() } | ForEach-Object { @{ col = $s.BaseName; item = $_.Trim() } }) } }
      else { $items += @(Get-ChildItem (Join-Path $c.FullName 'roms') -ErrorAction SilentlyContinue | ForEach-Object { @{ col = $c.Name; item = $_.BaseName } }) }
      foreach ($it in ($items | Select-Object -First 400)) {
        $total++
        $art = Join-Path $RetroFE "collections\$($it.col)\medium_artwork\$ty"
        if (Test-Path $art) { if (@(Get-ChildItem $art -Filter "$($it.item).*" -File -ErrorAction SilentlyContinue).Count) { $have++ } }
      }
    }
    $pct = if ($total) { [Math]::Round(100 * $have / $total) } else { 0 }
    $cover[$ty] = $pct; $wSum += $types[$ty]; $wGot += $types[$ty] * $pct / 100
    if ($pct -lt 50) { $gaps += "$ty $pct%" }
  }
  $score = if ($wSum) { [int][Math]::Round(100 * $wGot / $wSum) } else { 0 }
  $res = ([regex]::Match((Get-Content (Join-Path $dest 'layout.xml') -Raw), '<layout[^>]*\bwidth="(\d+)"[^>]*\bheight="(\d+)"')).Groups
  $info = [ordered]@{
    name = $destName; source = $src; imported = (Get-Date).ToString('s'); resolution = "$($res[1].Value)x$($res[2].Value)"
    monitors = 1 + @(Get-ChildItem $dest -Filter 'layout - *.xml').Count; score = $score; coverage = $cover; gaps = $gaps; fixes = $fixes; preview = $(if ($existing -and $existing.preview -and (Test-Path $existing.preview)) { $existing.preview } else { $null })
  }

  # 5. preview: run RetroFE on the theme for a moment
  if (-not $NoPreview) {
    $exe = Join-Path $RetroFE 'retrofe\retrofe.exe'; $sc = Join-Path $RetroFE 'settings.conf'
    if ((Test-Path $exe) -and -not (Get-Process retrofe -ErrorAction SilentlyContinue)) {
      $orig = [IO.File]::ReadAllText($sc)
      try {
        [IO.File]::WriteAllText($sc, ($orig -replace '(?m)^layout\s*=.*$', "layout = $destName"), (New-Object Text.ASCIIEncoding))
        $p = Start-Process $exe -WorkingDirectory (Split-Path $exe) -PassThru; Start-Sleep 15   # boot intro is ~7 s
        Add-Type -Namespace AmTh -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);' -ErrorAction SilentlyContinue
        $p.Refresh(); if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void][AmTh.W]::SetForegroundWindow($p.MainWindowHandle); Start-Sleep -Milliseconds 800 }
        Add-Type -AssemblyName System.Drawing, System.Windows.Forms
        $b = [Windows.Forms.Screen]::PrimaryScreen.Bounds; $bmp = New-Object Drawing.Bitmap $b.Width, $b.Height; $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size)
        $pd = Join-Path $ManifestDir 'themes'; New-Item -ItemType Directory -Force $pd | Out-Null
        $small = New-Object Drawing.Bitmap $bmp, 960, 540; $info.preview = Join-Path $pd "$destName.png"; $small.Save($info.preview, [Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose(); $small.Dispose()
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
      } finally { [IO.File]::WriteAllText($sc, $orig, (New-Object Text.ASCIIEncoding)) }
    } else { Write-Warning 'preview skipped (RetroFE is running or missing)' }
  }
  $keep = @($themes | Where-Object { $_.name -ne $destName }); $themes = New-Object Collections.Generic.List[object]; foreach ($k in $keep) { $themes.Add($k) }
  $themes.Add([pscustomobject]$info)
  Write-Host ("  {0}: {1}, {2} monitor(s), artwork coverage {3}%{4}" -f $destName, $info.resolution, $info.monitors, $score, $(if ($gaps) { "  gaps: $($gaps -join ', ')" } else { '' }))
  $fixes | ForEach-Object { Write-Host "  fix: $_" }
}
New-Item -ItemType Directory -Force $ManifestDir | Out-Null
[pscustomobject]@{ themes = [object[]]$themes.ToArray() } | ConvertTo-Json -Depth 6 | Set-Content $regFile -Encoding UTF8
Write-Host "themes registry: $regFile ($($themes.Count) theme(s))"
exit 0   # robocopy's exit code 1 means 'copied', not failure
