<#
.SYNOPSIS
  One coin button and one start button on the wheel, in every emulator (James, 2026-11-26: "Share credit and Options
  start for this controller"). Before, MAME had coin on L3 and start on R3, Supermodel coin on Options, Daytona 3 coin
  on Cross and start on the keyboard. Changes ONLY the coin / start bindings (a full WheelMap regenerate would rewrite
  129 files and undo later fixes):
    TeknoParrot  UserProfiles\*.xml of every copy: "Coin" / "Coin 1" and "Start" -> the wheel's button (only in
                 profiles that already use the wheel). A control that sat on that button moves to the freed one.
    MAME         ctrlr\*.cfg, cfg\*.cfg: COIN1 / START1. A wheel button is replaced, NONE is filled in, a keyboard key
                 keeps working and gets the wheel button as well.
    Supermodel   Config\Supermodel.ini: InputCoin1 / InputStart1.
    Model 2      CFG\*.input: the coin / start control codes.
  Buttons are the wheel's own numbers (G29: Share = 8, Options = 9). Dry run by default; -Apply backs each changed
  file up as <file>.coinstart-<time>.bak.
.EXAMPLE
  tools\Set-CoinStartButtons.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops
  tools\Set-CoinStartButtons.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -Apply
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [int]$Coin = 8, [int]$Start = 9,          # G29: Share, Options
  [int]$OldCoin = 11, [int]$OldStart = 10,  # what Model 2's files were written with (L3, R3)
  [string[]]$Roots,
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$wm = Join-Path $PSScriptRoot 'wheelmap'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# the wheel: its id and its place in the list, as the emulator files have them now
$st = Join-Path $ManifestDir 'emulator-devices.json'
if (-not (Test-Path -LiteralPath $st)) { throw "no $st - run tools\Repair-EmulatorDevices.ps1 -Apply once" }
$wheel = @((Get-Content -LiteralPath $st -Raw | ConvertFrom-Json).devices | Where-Object { $_.id -eq 'wheel' -or $_.vid -eq '046D' }) | Select-Object -First 1
if (-not $wheel) { throw 'no wheel in emulator-devices.json' }
$guid = ([string]$wheel.instanceGuid).ToLower(); $joy = [int]$wheel.enumIndex
Write-Host "wheel: $($wheel.productName) (JOY$joy, $guid) - coin = button $Coin, start = button $Start"

if (-not $Roots) {
  $Roots = @()
  $fe = Join-Path $RetroFE 'emulators'; if (Test-Path -LiteralPath $fe) { $Roots += @(Get-ChildItem -LiteralPath $fe -Directory | ForEach-Object FullName) }
  $tf = Join-Path $wm "targets\$env:COMPUTERNAME.json"
  if (Test-Path -LiteralPath $tf) {
    $t = Get-Content -LiteralPath $tf -Raw | ConvertFrom-Json
    foreach ($k in 'mame', 'm2emulator', 'teknoparrot') { foreach ($e in @($t.$k)) { if ($e.root) { $Roots += [string]$e.root } } }
    foreach ($e in @($t.supermodel)) { if ($e.ini) { $Roots += (Split-Path (Split-Path ([string]$e.ini))) } }
  }
  $Roots = @($Roots | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique)
}
$changed = 0; $notes = New-Object System.Collections.Generic.List[string]
function Save-Bytes([string]$f, [byte[]]$bytes, [string]$why) {
  Write-Host ("  {0} {1} ({2})" -f $(if ($Apply) { 'SET' } else { 'WOULD SET' }), $f, $why)
  if ($Apply) { Copy-Item -LiteralPath $f "$f.coinstart-$stamp.bak"; [IO.File]::WriteAllBytes($f, $bytes) }
  $script:changed++
}
$u8 = New-Object Text.UTF8Encoding($false)
function Read-Text([string]$f) { $raw = [IO.File]::ReadAllBytes($f); $bom = $raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF; @{ bom = $bom; text = $u8.GetString($raw, $(if ($bom) { 3 } else { 0 }), $raw.Length - $(if ($bom) { 3 } else { 0 })) } }
function Save-Text([string]$f, $r, [string]$new, [string]$why) { if ($new -ceq $r.text) { return }; $out = $u8.GetBytes($new); if ($r.bom) { $out = [byte[]](0xEF, 0xBB, 0xBF) + $out }; Save-Bytes $f $out $why }

foreach ($r in $Roots) {
  # ---------------- TeknoParrot
  foreach ($f in Get-ChildItem -LiteralPath (Join-Path $r 'UserProfiles') -Filter *.xml -File -ErrorAction SilentlyContinue) {
    $raw = [IO.File]::ReadAllText($f.FullName)
    if ($raw.ToLower().IndexOf($guid) -lt 0) { continue }                       # this game is not on the wheel
    try { $x = New-Object Xml.XmlDocument; $x.PreserveWhitespace = $false; $x.LoadXml($raw) } catch { continue }
    $nodes = @($x.SelectNodes('//JoystickButtons'))
    $onWheel = { param($n) $n.DirectInputButton -and ([string]$n.DirectInputButton.JoystickGuid).ToLower() -eq $guid -and [string]$n.BindNameDi -match '^(.*?) ?Buttons ?(\d+)$' }
    $prefix = 'Driving'; foreach ($n in $nodes) { if ((& $onWheel $n) -and [string]$n.BindNameDi -match '^(.*?) ?Buttons ?\d+$') { $prefix = $Matches[1]; break } }
    $tmpl = $nodes | Where-Object { & $onWheel $_ } | Select-Object -First 1
    $done = @()
    foreach ($want in @(@{ rx = '^(Coin|Coin ?1|P1 Coin|Player 1 Coin)$'; btn = $Coin; what = 'coin' }, @{ rx = '^(Start|Start ?1|P1 Start|Player 1 Start|Start Button)$'; btn = $Start; what = 'start' })) {
      foreach ($n in @($nodes | Where-Object { [string]$_.ButtonName -match $want.rx })) {
        $name = "$prefix Buttons$($want.btn)"
        if ((& $onWheel $n) -and [string]$n.BindNameDi -eq $name) { continue }                # already right
        $oldBtn = if ((& $onWheel $n) -and [string]$n.BindNameDi -match 'Buttons ?(\d+)$') { [int]$Matches[1] } else { -1 }
        # something else on the wanted button: it moves to the button this control leaves
        foreach ($o in @($nodes | Where-Object { $_ -ne $n -and (& $onWheel $_) -and [string]$_.BindNameDi -eq $name })) {
          if ($oldBtn -ge 0) { $o.DirectInputButton.Button = "$(48 + $oldBtn)"; $o.BindNameDi = "$prefix Buttons$oldBtn"; if ($o.SelectSingleNode('BindName')) { $o.BindName = "$prefix Buttons$oldBtn" }; $done += "$($o.ButtonName) -> button $oldBtn" }
          else { $notes.Add("$($f.Name): '$($o.ButtonName)' is on button $($want.btn) as well as $($want.what)") }
        }
        if (-not $n.DirectInputButton) { if (-not $tmpl) { continue }; [void]$n.AppendChild($tmpl.DirectInputButton.CloneNode($true)) }
        $d = $n.DirectInputButton
        $set = @{ Button = "$(48 + $want.btn)"; IsAxis = 'false'; IsAxisMinus = 'false'; IsFullAxis = 'false'; PovDirection = '0'; IsReverseAxis = 'false'; JoystickGuid = $guid }
        foreach ($k in $set.Keys) { $e = $d.SelectSingleNode($k); if (-not $e) { $e = $x.CreateElement($k); [void]$d.AppendChild($e) }; $e.InnerText = $set[$k] }
        foreach ($tag in 'BindNameDi', 'BindName') { $e = $n.SelectSingleNode($tag); if (-not $e) { $e = $x.CreateElement($tag); [void]$n.AppendChild($e) }; $e.InnerText = $name }
        $done += "$($n.ButtonName) -> button $($want.btn)"
      }
    }
    if (-not $done) { continue }
    $sb = New-Object Text.StringBuilder; $s = New-Object Xml.XmlWriterSettings; $s.Indent = $true; $s.Encoding = $u8
    $ms = New-Object IO.MemoryStream; $w = [Xml.XmlWriter]::Create($ms, $s); $x.Save($w); $w.Close()
    Save-Bytes $f.FullName $ms.ToArray() ("TeknoParrot: " + ($done -join ', '))
  }
  # ---------------- MAME
  foreach ($sub in 'ctrlr', 'cfg') {
    foreach ($f in Get-ChildItem -LiteralPath (Join-Path $r $sub) -Filter *.cfg -File -ErrorAction SilentlyContinue) {
      $t = Read-Text $f.FullName; if ($t.text -notmatch 'type="(COIN1|START1)"') { continue }
      $new = [regex]::Replace($t.text, '(?s)(<port\b[^>]*\btype="(COIN1|START1)"[^>]*>\s*<newseq\b[^>]*type="standard"[^>]*>)(.*?)(</newseq>)', {
        param($m)
        $target = "JOYCODE_${joy}_BUTTON$((($(if ($m.Groups[2].Value -eq 'COIN1') { $Coin } else { $Start })) + 1))"
        $seq = $m.Groups[3].Value.Trim(); $lead = [regex]::Match($m.Groups[3].Value, '^\s*').Value; $tail = [regex]::Match($m.Groups[3].Value, '\s*$').Value
        if ($seq -match "\b$target\b") { return $m.Value }
        $nseq = if (-not $seq -or $seq -eq 'NONE') { $target }
                elseif ($seq -match "JOYCODE_${joy}_BUTTON\d+") { [regex]::Replace($seq, "JOYCODE_${joy}_BUTTON\d+", $target, 1) }
                else { "$seq OR $target" }
        $m.Groups[1].Value + $lead + $nseq + $tail + $m.Groups[4].Value
      })
      Save-Text $f.FullName $t $new 'MAME coin / start'
    }
  }
  # ---------------- Supermodel
  $ini = Join-Path $r 'Config\Supermodel.ini'
  if (Test-Path -LiteralPath $ini) {
    $t = Read-Text $ini
    $new = [regex]::Replace($t.text, '(?m)^(\s*Input(Coin1|Start1)\s*=\s*)"([^"]*)"', {
      param($m)
      $target = "JOY${joy}_BUTTON$((($(if ($m.Groups[2].Value -eq 'Coin1') { $Coin } else { $Start })) + 1))"
      $keep = @($m.Groups[3].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch "^JOY${joy}_BUTTON\d+$" })
      $m.Groups[1].Value + '"' + ((@($keep) + $target) -join ',') + '"'
    })
    Save-Text $ini $t $new 'Supermodel coin / start'
  }
  # ---------------- Model 2
  $code = { param([int]$b) $n = $b + 1; [uint32](($joy -shl 8) -bor (($n -band 0xF) -shl 4) -bor (($n -shr 4) -shl 12)) }
  $map = @{}; $map[(& $code $OldCoin)] = (& $code $Coin); $map[(& $code $OldStart)] = (& $code $Start); $map[(& $code $Coin)] = (& $code $OldCoin); $map[(& $code $Start)] = (& $code $OldStart)
  foreach ($f in Get-ChildItem -LiteralPath (Join-Path $r 'CFG') -Filter *.input -File -ErrorAction SilentlyContinue) {
    $b = [IO.File]::ReadAllBytes($f.FullName); $out = [byte[]]$b.Clone(); $n = 0; $words = [int]($b.Length / 4) - 2
    $has = $false; for ($i = 0; $i -lt $words; $i++) { $v = [BitConverter]::ToUInt32($b, $i * 4); if ($v -eq (& $code $OldCoin) -or $v -eq (& $code $OldStart)) { $has = $true } }
    if (-not $has) { continue }                                                 # already done (or never on those buttons)
    for ($i = 0; $i -lt $words; $i++) { $v = [BitConverter]::ToUInt32($b, $i * 4); if ($map.ContainsKey($v)) { [BitConverter]::GetBytes([uint32]$map[$v]).CopyTo($out, $i * 4); $n++ } }
    if ($n) { Save-Bytes $f.FullName $out "Model 2: $n control code(s)" }
  }
}
$notes | Select-Object -Unique | ForEach-Object { Write-Host "  NOTE $_" }
Write-Host ("coin / start: {0} file(s) {1} in {2} folder(s)" -f $changed, $(if ($Apply) { 'set' } else { 'to set (dry run)' }), $Roots.Count)
