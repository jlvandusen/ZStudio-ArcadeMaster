<#
.SYNOPSIS
  Point fixes for emulator configs, applied at every start so emulator setup stays hands-off (James 2026-11-28):
    catalog\emulator-fixes.json        TeknoParrot buttons by name (a control a newer GameProfile added, a game's own
                                       button layout) - optional 'hosts' per entry
    tools\wheelmap\templates\supermodel.json 'settings'   extra Supermodel [ Global ] lines (the steering saturation)
  Only what is missing or different is changed; each changed file is backed up first (<file>.emufix-<time>.bak); a run
  with nothing to do writes nothing. An emulator that is running is left alone (its files are read at its start).
  A profile without the named control, or a wheel button another control already uses, is reported and skipped.
  Wheel cabinets only: the wheel comes from <manifest>\emulator-devices.json. Dry run unless -Apply.
.EXAMPLE
  tools\Set-EmulatorFixes.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE
  tools\Set-EmulatorFixes.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -Apply
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Catalog,
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
if (-not $Catalog) { $Catalog = Join-Path $repo 'catalog\emulator-fixes.json' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$st = Join-Path $ManifestDir 'emulator-devices.json'
if (-not (Test-Path -LiteralPath $st)) { Write-Host "emulator fixes: no $st (not a wheel cabinet yet) - nothing to do"; return }
$wheel = @((Get-Content -LiteralPath $st -Raw | ConvertFrom-Json).devices | Where-Object { $_.id -eq 'wheel' -or $_.vid -eq '046D' }) | Select-Object -First 1
if (-not $wheel) { Write-Host 'emulator fixes: no wheel on this cabinet - nothing to do'; return }
$guid = ([string]$wheel.instanceGuid).ToLower(); $joy = [int]$wheel.enumIndex
$cat = Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json
$latin = [Text.Encoding]::GetEncoding(28591); $u8 = New-Object Text.UTF8Encoding($false)
$changed = 0; $notes = New-Object System.Collections.Generic.List[string]
function Save-File([string]$f, [byte[]]$bytes, [string]$why) {
  Write-Host ("  {0} {1} ({2})" -f $(if ($Apply) { 'SET' } else { 'WOULD SET' }), $f, $why)
  if ($Apply) { Copy-Item -LiteralPath $f "$f.emufix-$stamp.bak"; [IO.File]::WriteAllBytes($f, $bytes) }
  $script:changed++
}
function Test-Running([string[]]$names) { [bool](Get-Process -Name $names -ErrorAction SilentlyContinue) }
function Test-ForHost($entry) { -not $entry.hosts -or (@($entry.hosts) -contains $env:COMPUTERNAME) }

# where the emulators are: the frontend's emulators folder, plus the cabinet's WheelMap targets (RACE1 also has D:\Emulators)
$roots = @()
$fe = Join-Path $RetroFE 'emulators'; if (Test-Path -LiteralPath $fe) { $roots += @(Get-ChildItem -LiteralPath $fe -Directory | ForEach-Object FullName) }
$tf = Join-Path $PSScriptRoot "wheelmap\targets\$env:COMPUTERNAME.json"
$smInis = @()
if (Test-Path -LiteralPath $tf) {
  $t = Get-Content -LiteralPath $tf -Raw | ConvertFrom-Json
  foreach ($e in @($t.teknoparrot)) { if ($e.root) { $roots += [string]$e.root } }
  foreach ($e in @($t.supermodel)) { if ($e.ini) { $smInis += [string]$e.ini } }
}
# the folder's real place: a link anywhere on the way is followed (RACE2: <frontend>\emulators\TeknoParrot is a junction;
# RACE1: <frontend>\emulators itself is a link to E:\DRIVE Collection\emulators), so one folder reached by two paths is
# written - and backed up - once
function Get-RealPath([string]$p) {
  $full = (Get-Item -LiteralPath $p).FullName; $parts = $full.TrimEnd([char]92).Split([char]92); $cur = $parts[0] + [char]92
  for ($k = 1; $k -lt $parts.Count; $k++) {
    $cur = Join-Path $cur $parts[$k]; $i = Get-Item -LiteralPath $cur -ErrorAction SilentlyContinue
    if ($i -and $i.LinkType -and $i.Target) { $t = [string]@($i.Target)[0]; if (-not [IO.Path]::IsPathRooted($t)) { $t = Join-Path (Split-Path $cur) $t }; $cur = $t }
  }
  $cur
}
$roots = @($roots | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object { Get-RealPath $_ } | Sort-Object -Unique)

# ---------------- TeknoParrot: buttons by name
$tpRoots = @($roots | Where-Object { Test-Path -LiteralPath (Join-Path $_ 'UserProfiles') })
if ($tpRoots -and (Test-Running 'TeknoParrotUi', 'OpenParrotLoader', 'OpenParrotLoader64', 'BudgieLoader')) { $notes.Add('TeknoParrot is running - its profiles are left for the next start'); $tpRoots = @() }
$seenFiles = @{}
foreach ($r in $tpRoots) {
  foreach ($game in @($cat.teknoparrot.PSObject.Properties | Where-Object { $_.Name -notlike '_*' })) {
    if (-not (Test-ForHost $game.Value)) { continue }
    $f = Join-Path $r "UserProfiles\$($game.Name).xml"; if (-not (Test-Path -LiteralPath $f)) { continue }
    if ($seenFiles.ContainsKey($f)) { continue }; $seenFiles[$f] = 1
    $raw = [IO.File]::ReadAllText($f)
    if ($raw.ToLower().IndexOf($guid) -lt 0) { $notes.Add("$($game.Name) ($r): not bound to this wheel - left alone"); continue }
    $x = New-Object Xml.XmlDocument; $x.PreserveWhitespace = $false; $x.LoadXml($raw)
    $nodes = @($x.SelectNodes('//JoystickButtons'))
    $onWheel = { param($n) $n.DirectInputButton -and ([string]$n.DirectInputButton.JoystickGuid).ToLower() -eq $guid }
    $prefix = 'Driving'; foreach ($n in $nodes) { if ((& $onWheel $n) -and [string]$n.BindNameDi -match '^(.*?) ?Buttons ?\d+$') { $prefix = $Matches[1]; break } }
    $tmpl = $nodes | Where-Object { (& $onWheel $_) -and [string]$_.BindNameDi -match 'Buttons ?\d+$' } | Select-Object -First 1
    $gp = Join-Path $r "GameProfiles\$($game.Name).xml"
    $gpNodes = if (Test-Path -LiteralPath $gp) { @(([xml](Get-Content -LiteralPath $gp -Raw)).SelectNodes('//JoystickButtons')) } else { @() }
    $known = @($gpNodes | ForEach-Object { [string]$_.ButtonName })
    $done = @()
    foreach ($b in @($game.Value.buttons.PSObject.Properties)) {
      $want = [int]$b.Value.wheel; $name = "$prefix Buttons$want"
      $n = $nodes | Where-Object { [string]$_.ButtonName -eq $b.Name } | Select-Object -First 1
      if ($n -and (& $onWheel $n) -and [string]$n.BindNameDi -eq $name) { continue }                       # already right
      $other = $nodes | Where-Object { $_ -ne $n -and (& $onWheel $_) -and [string]$_.BindNameDi -eq $name } | Select-Object -First 1
      if ($other) { $notes.Add("$($game.Name) ($r): '$($b.Name)' not set - wheel button $want is '$($other.ButtonName)'"); continue }
      if (-not $n) {
        # a control the emulator's own GameProfile has, missing from this older profile: add it
        if ($known -and $known -notcontains $b.Name) { $notes.Add("$($game.Name) ($r): '$($b.Name)' is not a control of this TeknoParrot's profile - skipped"); continue }
        if (-not $tmpl) { $notes.Add("$($game.Name) ($r): no wheel button to copy the layout from - '$($b.Name)' skipped"); continue }
        # the control's own entry from the emulator's GameProfile (its InputMapping and flags), else a wheel button's
        $src = $gpNodes | Where-Object { [string]$_.ButtonName -eq $b.Name } | Select-Object -First 1
        if ($src) { $n = $x.ImportNode($src, $true) } else { $n = $tmpl.CloneNode($true); $n.ButtonName = $b.Name }
        if ($b.Value.mapping) { $m = $n.SelectSingleNode('InputMapping'); if ($m) { $m.InnerText = [string]$b.Value.mapping } }
        [void]$tmpl.ParentNode.InsertAfter($n, ($nodes | Select-Object -Last 1)); $nodes = @($x.SelectNodes('//JoystickButtons'))
      }
      if (-not $n.DirectInputButton) { [void]$n.AppendChild($tmpl.DirectInputButton.CloneNode($true)) }
      $d = $n.DirectInputButton
      $set = @{ Button = "$(48 + $want)"; IsAxis = 'false'; IsAxisMinus = 'false'; IsFullAxis = 'false'; PovDirection = '0'; IsReverseAxis = 'false'; JoystickGuid = $guid }
      foreach ($k in $set.Keys) { $e = $d.SelectSingleNode($k); if (-not $e) { $e = $x.CreateElement($k); [void]$d.AppendChild($e) }; $e.InnerText = $set[$k] }
      foreach ($tag in 'BindNameDi', 'BindName') { $e = $n.SelectSingleNode($tag); if (-not $e) { $e = $x.CreateElement($tag); [void]$n.AppendChild($e) }; $e.InnerText = $name }
      $done += "$($b.Name) -> wheel button $want"
    }
    if (-not $done) { continue }
    $s = New-Object Xml.XmlWriterSettings; $s.Indent = $true; $s.Encoding = $u8
    $ms = New-Object IO.MemoryStream; $w = [Xml.XmlWriter]::Create($ms, $s); $x.Save($w); $w.Close()
    Save-File $f $ms.ToArray() ("TeknoParrot $($game.Name): " + ($done -join ', '))
  }
}

# ---------------- Supermodel: extra [ Global ] lines from the WheelMap template
$tplFile = Join-Path $PSScriptRoot 'wheelmap\templates\supermodel.json'
$extra = if (Test-Path -LiteralPath $tplFile) { (Get-Content -LiteralPath $tplFile -Raw | ConvertFrom-Json).settings } else { $null }
if ($extra) {
  # only a Supermodel the frontend starts (a launcher's executable is in it) or the WheelMap target names - not a
  # spare copy lying beside it ("Supermodel - Copy" on the DRIVE drive)
  $used = @(Get-ChildItem -LiteralPath (Join-Path $RetroFE 'launchers.windows') -Filter *.conf -File -ErrorAction SilentlyContinue | ForEach-Object {
      $l = Select-String -LiteralPath $_.FullName -Pattern '^\s*executable\s*=\s*(.+)$' | Select-Object -First 1
      if ($l) { $e = $l.Matches[0].Groups[1].Value.Trim(); if (-not [IO.Path]::IsPathRooted($e)) { $e = Join-Path $RetroFE $e }; if (Test-Path -LiteralPath (Split-Path $e)) { Get-RealPath (Split-Path $e) } } })
  $inis = @(@($smInis) + @($roots | Where-Object { $used -contains $_ } | ForEach-Object { Join-Path $_ 'Config\Supermodel.ini' })) | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique
  if ($inis -and (Test-Running 'Supermodel')) { $notes.Add('Supermodel is running - its file is left for the next start'); $inis = @() }
  foreach ($ini in $inis) {
    $text = $latin.GetString([IO.File]::ReadAllBytes($ini)); $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [Collections.Generic.List[string]]($text -split "`r?`n")
    $gs = -1; for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[\s*Global\s*\]') { $gs = $i; break } }
    if ($gs -lt 0) { $notes.Add("$ini has no [ Global ] section - skipped"); continue }
    $done = @()
    foreach ($p in $extra.PSObject.Properties) {
      $k = $p.Name.Replace('{wheel}', "$joy"); $v = [string]$p.Value
      $ge = $lines.Count; for ($i = $gs + 1; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[') { $ge = $i; break } }
      $at = -1; for ($i = $gs + 1; $i -lt $ge; $i++) { if ($lines[$i] -match ('^\s*' + [regex]::Escape($k) + '\s*=')) { $at = $i } }
      if ($at -ge 0) {
        if (($lines[$at] -replace '^[^=]*=\s*', '' -replace '\s*;.*$', '').Trim('"', ' ') -eq $v) { continue }   # already right
        $lines[$at] = "$k = $v"
      }
      else {
        # after the steering line when there is one (where it belongs), else at the end of [ Global ]
        $ins = -1; for ($i = $gs + 1; $i -lt $ge; $i++) { if ($lines[$i] -match '^\s*InputSteering\s*=') { $ins = $i + 1 } }
        if ($ins -lt 0) { $ins = $ge; while ($ins -gt $gs + 1 -and -not $lines[$ins - 1].Trim()) { $ins-- } }
        $lines.Insert($ins, "$k = $v")
      }
      $done += "$k = $v"
    }
    if ($done) { Save-File $ini $latin.GetBytes(($lines -join $nl)) ("Supermodel: " + ($done -join ', ')) }
  }
}

$notes | ForEach-Object { Write-Host "  NOTE $_" }
Write-Host ("emulator fixes: {0} file(s) {1}" -f $changed, $(if ($Apply) { 'set' } else { 'to set (dry run)' }))
