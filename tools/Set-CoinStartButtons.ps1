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
  Test / service (operator menus, calibration) the same way: the wheel's Plus = Test, Minus = Service (2026-11-26; they
  were on F1 / F2, Plus / Minus or the D-pad depending on the game). A keyboard key in MAME / Supermodel keeps working.
  Buttons are the wheel's own numbers (G29: Share = 8, Options = 9, Plus = 19, Minus = 20). Dry run by default; -Apply backs each changed
  file up as <file>.coinstart-<time>.bak.
.EXAMPLE
  tools\Set-CoinStartButtons.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops
  tools\Set-CoinStartButtons.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops -Apply
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [int]$Coin = 8, [int]$Start = 9,          # G29: Share, Options
  [int]$Test = 19, [int]$Service = 20,      # G29: Plus, Minus (operator menus / calibration); -1 = leave alone
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
Write-Host "wheel: $($wheel.productName) (JOY$joy, $guid) - coin = button $Coin, start = $Start, test = $Test, service = $Service"

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
    $wants = @(@{ rx = '^(Coin|Coin ?1|P1 Coin|Player 1 Coin)$'; btn = $Coin; what = 'coin' }, @{ rx = '^(Start|Start ?1|P1 Start|Player 1 Start|Start Button)$'; btn = $Start; what = 'start' })
    if ($Test -ge 0) { $wants += @{ rx = '^(Test|Test Button|Test Switch|Test SW)$'; btn = $Test; what = 'test' } }
    if ($Service -ge 0) { $wants += @{ rx = '^(Service|Service ?1|Service Button|Service SW)$'; btn = $Service; what = 'service' } }
    foreach ($want in $wants) {
      foreach ($n in @($nodes | Where-Object { [string]$_.ButtonName -match $want.rx })) {
        $name = "$prefix Buttons$($want.btn)"
        if ((& $onWheel $n) -and [string]$n.BindNameDi -eq $name) { continue }                # already right
        $oldBtn = if ((& $onWheel $n) -and [string]$n.BindNameDi -match 'Buttons ?(\d+)$') { [int]$Matches[1] } else { -1 }
        # something else on the wanted button: it moves to the button this control leaves
        # A control of the same kind waiting to move off it (Service on Plus, about to go to Minus) does not count.
        $taken = @($nodes | Where-Object { $_ -ne $n -and (& $onWheel $_) -and [string]$_.BindNameDi -eq $name })
        $taken = @($taken | Where-Object { $tn = [string]$_.ButtonName; -not @($wants | Where-Object { $tn -match $_.rx }).Count })
        if ($taken.Count -and $oldBtn -lt 0) {
          # the button belongs to another control (Raw Thrills games: Volume Up / Down on Plus / Minus, which their test
          # menu uses) and this one has no wheel button to give in exchange: leave it as it is rather than double up
          $notes.Add("$($f.Name): $($want.what) left as it is ('$($taken[0].ButtonName)' uses button $($want.btn))"); continue
        }
        foreach ($o in $taken) { $o.DirectInputButton.Button = "$(48 + $oldBtn)"; $o.BindNameDi = "$prefix Buttons$oldBtn"; if ($o.SelectSingleNode('BindName')) { $o.BindName = "$prefix Buttons$oldBtn" }; $done += "$($o.ButtonName) -> button $oldBtn" }
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
      $mameBtn = @{ COIN1 = $Coin; START1 = $Start }; if ($Test -ge 0) { $mameBtn['SERVICE'] = $Test }; if ($Service -ge 0) { $mameBtn['SERVICE1'] = $Service }   # MAME: SERVICE = the test switch
      $t = Read-Text $f.FullName; if ($t.text -notmatch 'type="(COIN1|START1|SERVICE1?)"') { continue }
      $new = [regex]::Replace($t.text, '(?s)(<port\b[^>]*\btype="(COIN1|START1|SERVICE1|SERVICE)"[^>]*>\s*<newseq\b[^>]*type="standard"[^>]*>)(.*?)(</newseq>)', {
        param($m)
        if (-not $mameBtn.ContainsKey($m.Groups[2].Value)) { return $m.Value }
        $target = "JOYCODE_${joy}_BUTTON$($mameBtn[$m.Groups[2].Value] + 1)"
        $seq = $m.Groups[3].Value.Trim(); $lead = [regex]::Match($m.Groups[3].Value, '^\s*').Value; $tail = [regex]::Match($m.Groups[3].Value, '\s*$').Value
        if ($seq -match "\b$target\b") { return $m.Value }
        $nseq = if (-not $seq -or $seq -eq 'NONE') { $target }
                elseif ($seq -match "JOYCODE_${joy}_BUTTON\d+") { [regex]::Replace($seq, "JOYCODE_${joy}_BUTTON\d+", $target, 1) }
                else { "$seq OR $target" }
        $m.Groups[1].Value + $lead + $nseq + $tail + $m.Groups[4].Value
      })
      Save-Text $f.FullName $t $new 'MAME coin / start / test / service'
    }
  }
  # ---------------- Supermodel
  $ini = Join-Path $r 'Config\Supermodel.ini'
  if (Test-Path -LiteralPath $ini) {
    $t = Read-Text $ini
    $smBtn = @{ Coin1 = $Coin; Start1 = $Start }; if ($Test -ge 0) { $smBtn['TestA'] = $Test }; if ($Service -ge 0) { $smBtn['ServiceA'] = $Service }
    $new = [regex]::Replace($t.text, '(?m)^(\s*Input(Coin1|Start1|TestA|ServiceA)\s*=\s*)"([^"]*)"', {
      param($m)
      if (-not $smBtn.ContainsKey($m.Groups[2].Value)) { return $m.Value }
      $target = "JOY${joy}_BUTTON$($smBtn[$m.Groups[2].Value] + 1)"
      $keep = @($m.Groups[3].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch "^JOY${joy}_BUTTON\d+$" })
      $m.Groups[1].Value + '"' + ((@($keep) + $target) -join ',') + '"'
    })
    Save-Text $ini $t $new 'Supermodel coin / start / test / service'
  }
  # ---------------- Model 2
  $code = { param([int]$b) $n = $b + 1; [uint32](($joy -shl 8) -bor (($n -band 0xF) -shl 4) -bor (($n -shr 4) -shl 12)) }
  # Each pair (old button -> new button) is handled by itself, and only in a file that still HAS the old one. A pair that
  # does not change (coin stays on Share) is skipped. The first version built one two-way table and looked for "any old
  # code": on a second visit (the frontend's copy and the E: copy are the same files) it swapped start straight back.
  $pairs = @(@{ old = $OldCoin; new = $Coin }, @{ old = $OldStart; new = $Start }) | Where-Object { $_.old -ne $_.new -and $_.old -ge 0 -and $_.new -ge 0 }
  foreach ($f in Get-ChildItem -LiteralPath (Join-Path $r 'CFG') -Filter *.input -File -ErrorAction SilentlyContinue) {
    $b = [IO.File]::ReadAllBytes($f.FullName); $out = [byte[]]$b.Clone(); $n = 0; $words = [int]($b.Length / 4) - 2
    foreach ($pr in $pairs) {
      $co = (& $code $pr.old); $cn = (& $code $pr.new)
      $at = @(0..($words - 1) | Where-Object { [BitConverter]::ToUInt32($out, $_ * 4) -eq $co }); if (-not $at) { continue }
      $clash = @(0..($words - 1) | Where-Object { [BitConverter]::ToUInt32($out, $_ * 4) -eq $cn })      # another control on the new button: it takes the old one
      foreach ($i in $at) { [BitConverter]::GetBytes([uint32]$cn).CopyTo($out, $i * 4); $n++ }
      foreach ($i in $clash) { [BitConverter]::GetBytes([uint32]$co).CopyTo($out, $i * 4); $n++ }
    }
    if ($n) { Save-Bytes $f.FullName $out "Model 2: $n control code(s)" }
  }
}
$notes | Select-Object -Unique | ForEach-Object { Write-Host "  NOTE $_" }
Write-Host ("coin / start: {0} file(s) {1} in {2} folder(s)" -f $changed, $(if ($Apply) { 'set' } else { 'to set (dry run)' }), $Roots.Count)
