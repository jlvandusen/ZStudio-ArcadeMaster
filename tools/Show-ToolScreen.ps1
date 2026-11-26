<#
.SYNOPSIS
  Full-screen visual "tool page" for the in-frontend TOOLS menu. Runs Invoke-CabinetTool.ps1 hidden, reads its
  "@AM {json}" events and draws them in the ArcadeMaster style, sized to the cabinet display:
    devices   -> device cards (wheel, pedals, handbrake, pad, gun, trackball, touch ...) + capability tiles
    toggle    -> big icon + ON/OFF switch (+ display diagram for the second screen)
    step      -> animated checklist; tiles -> result counters (Racing 103 / Flight 3 ...)
    stats     -> big number tiles; images -> backdrop thumbnails
    wiz-*     -> Wheel Setup: prompt per control, movement meter, captured list, LIVE wheel / pedals / buttons,
                 touch buttons SKIP / REDO / BACK / ACCEPT / FINISH
  Closes on any key, tap or joystick/wheel button once the tool is done, or after AutoCloseSec.
#>
param(
  [Parameter(Mandatory)][string]$Tool,
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Title,
  # display to cover: -1 = the one RetroFE's screenNum0 points at
  [int]$Screen = -1,
  [int]$AutoCloseSec = 15,
  [int]$TimeoutSec = 900
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AmVisual.ps1')
Add-Type -AssemblyName System.Windows.Forms
$amWinSrc = @'
using System; using System.Runtime.InteropServices;
public static class AmWin {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static void DoubleBuffer(System.Windows.Forms.Control c) {
    typeof(System.Windows.Forms.Control).GetProperty("DoubleBuffered", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic).SetValue(c, true, null);
  }
}
public class AmFeed {
  public readonly System.Collections.Concurrent.ConcurrentQueue<string> Lines = new System.Collections.Concurrent.ConcurrentQueue<string>();
  public void Attach(System.Diagnostics.Process p) {
    p.OutputDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
    p.ErrorDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue("!ERR " + e.Data); };
  }
}
'@
. (Join-Path $PSScriptRoot 'lib\AmTypeCache.ps1'); Add-AmCachedType -Source $amWinSrc -References System.Windows.Forms, System.Drawing -ProbeType AmWin
[void][AmWin]::SetProcessDPIAware()

$toolIcon = @{ WheelSetup = 'setup'; FlightSetup = 'joystick'; GpuDriver = 'display'; MenuButtons = 'buttons'; EmulatorUpdates = 'rebuild'; PanelTest = 'buttons'; DetectControllers = 'detect'; RepairIds = 'repair'; RebuildMenus = 'rebuild'; ToggleFfb = 'ffb'; ToggleTactile = 'ffb'; ToggleSecondScreen = 'screen2'; ShuffleBackgrounds = 'shuffle'; TogglePerfLog = 'perf'; CabinetType = 'cabinet'; SystemSettings = 'buttons'; SystemHealth = 'repair'; Themes = 'shuffle'; ResetTheme = 'repair' }[$Tool]
$toolColor = @{ WheelSetup = [AmPal]::Magenta; FlightSetup = [AmPal]::Cyan; GpuDriver = [AmPal]::Green; MenuButtons = [AmPal]::Cyan; EmulatorUpdates = [AmPal]::Green; PanelTest = [AmPal]::Magenta; DetectControllers = [AmPal]::Cyan; RepairIds = [AmPal]::Cyan; RebuildMenus = [AmPal]::Amber; ToggleFfb = [AmPal]::Magenta; ToggleTactile = [AmPal]::Hex('ff6a00'); ToggleSecondScreen = [AmPal]::Hex('9be7ff'); ShuffleBackgrounds = [AmPal]::Violet; TogglePerfLog = [AmPal]::Dim; CabinetType = [AmPal]::Cyan; SystemSettings = [AmPal]::Amber; SystemHealth = [AmPal]::Green; Themes = [AmPal]::Violet; ResetTheme = [AmPal]::Violet }[$Tool]
if (-not $Title) { $Title = ($Tool -creplace '(?<=[a-z])(?=[A-Z])', ' ').ToUpper() }
if ($Screen -lt 0) {
  $m = Select-String -Path (Join-Path $RetroFE 'settings.conf') -Pattern '^\s*screenNum0\s*=\s*(\d+)' -ErrorAction SilentlyContinue | Select-Object -Last 1
  $Screen = if ($m) { [int]$m.Matches[0].Groups[1].Value } else { 0 }
}
$screens = [Windows.Forms.Screen]::AllScreens
$scr = if ($Screen -lt $screens.Count) { $screens[$Screen] } else { [Windows.Forms.Screen]::PrimaryScreen }
$SB = $scr.Bounds; $SW = [float]$SB.Width; $SH = [float]$SB.Height

function F([string]$family, [double]$div, [Drawing.FontStyle]$style = 'Regular') { New-Object Drawing.Font($family, [float][Math]::Max(10, $SH / $div), $style, [Drawing.GraphicsUnit]::Pixel) }
$fnt = @{
  sub = F 'Segoe UI Semibold' 40; big = F 'Segoe UI Black' 18 'Italic'; huge = F 'Segoe UI Black' 9; text = F 'Segoe UI' 30; textB = F 'Segoe UI Semibold' 28
  small = F 'Segoe UI' 44; label = F 'Segoe UI Semibold' 46; tileV = F 'Segoe UI Black' 16; chip = F 'Segoe UI Semibold' 56; mono = F 'Consolas' 34
  toggle = F 'Segoe UI Black' 14; foot = F 'Segoe UI Semibold' 30; btn = F 'Segoe UI Black' 30
}
$ffTitle = New-Object Drawing.FontFamily 'Segoe UI Black'
function Rect([double]$x, [double]$y, [double]$w, [double]$h) { New-Object Drawing.RectangleF([float]$x, [float]$y, [float]$w, [float]$h) }
$pad = $SW * 0.04

# ---------------- model ----------------
$M = @{
  log = New-Object Collections.Generic.List[string]; devices = $null; tiles = $null; stats = $null; toggle = $null; displays = $null
  steps = [ordered]@{}; images = $null; imagesTitle = ''; imagesAt = $null; thumbs = @{}
  wiz = $null; wizEnd = $null; done = $false; exit = 0; closeAt = $null; started = Get-Date; lastButtons = [AmJoyLive]::AnyButtons(); prevButtons = [long]0; lastPoll = [long]0; rawPrev = [long]-1; stable = [long]0; noisy = [long]0; flips = @{}; downAt = @{}; doneAt = $null
  joy = $null; joyAt = [datetime]::MinValue; rest = @{}; buttons = @(); events = 0
}

# ---------------- process ----------------
$feed = New-Object AmFeed; $queue = $feed.Lines
$keyFile = Join-Path $env:TEMP ("am-wiz-key-{0}.txt" -f $PID)
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Tool {1} -RetroFE "{2}" -ManifestDir "{3}"' -f (Join-Path $PSScriptRoot 'Invoke-CabinetTool.ps1'), $Tool, $RetroFE, $ManifestDir)
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
$oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
$psi.StandardOutputEncoding = $oem; $psi.StandardErrorEncoding = $oem
$psi.EnvironmentVariables['AM_TOOL_NOPAUSE'] = '1'; $psi.EnvironmentVariables['AM_VISUAL'] = '1'; $psi.EnvironmentVariables['AM_WIZ_KEYFILE'] = $keyFile
$proc = New-Object Diagnostics.Process; $proc.StartInfo = $psi; $feed.Attach($proc)

function On-Event($e) {
  $M.events++
  switch ($e.type) {
    'devices' { $M.devices = @($e.devices) }
    'tiles' { $M.tiles = @($e.tiles) }
    'stats' { $M.stats = @($e.stats) }
    'toggle' { $M.toggle = $e; $M.toggleAt = (Get-Date).AddSeconds(0.5) }
    'displays' { $M.displays = $e }
    'step' { $M.steps[$e.id] = @{ label = $e.label; status = $e.status } }
    'images' {
      $M.images = @($e.files); $M.imagesTitle = $e.title; $M.imagesAt = Get-Date
      foreach ($f in $M.images) { try { $img = [Drawing.Image]::FromFile($f); $tw = [int]($SW * 0.26); $th = [int]($tw * 9 / 16); $bm = New-Object Drawing.Bitmap $tw, $th; $g = [Drawing.Graphics]::FromImage($bm); [AmDraw]::Hq($g); $g.DrawImage($img, 0, 0, $tw, $th); $g.Dispose(); $img.Dispose(); $M.thumbs[$f] = $bm } catch { } }
    }
    'wizard' { if ($e.state -eq 'start') { $M.wiz = @{ step = $null; axis = $null; results = New-Object Collections.ArrayList; devices = @() } } else { $M.wizEnd = $e } }
    'wiz-devices' { if ($M.wiz) { $M.wiz.devices = @($e.devices) } }
    'wiz-step' { if ($M.wiz) { $M.wiz.step = $e; $M.wiz.axis = $null; $M.wiz.stepAt = Get-Date } }
    'wiz-axis' { if ($M.wiz) { $M.wiz.axis = $e } }
    'wiz-result' { if ($M.wiz) { [void]$M.wiz.results.Add($e) } }
    'settings' {
      $idx = if ($M.settings) { $M.settings.idx } else { 0 }
      $scroll = if ($M.settings) { $M.settings.scroll } else { 0 }
      $M.settings = @{ items = @($e.items); idx = [Math]::Min($idx, @($e.items).Count); scroll = $scroll; message = "$($e.message)"; busy = $false; at = Get-Date; armed = $null; armedAt = [datetime]::MinValue; rest = @{}; moveAt = [datetime]::MinValue; dir = 0; done = $false }
      if ($M.yielded) { $M.yielded = $false; $form.WindowState = 'Normal'; $form.Bounds = $SB; $form.TopMost = $true; $form.Activate() }
    }
    'yield' { $M.yielded = $true; if ($M.settings) { $M.settings.message = "$($e.message)" }; $form.TopMost = $false; $form.WindowState = 'Minimized' }
    'choice' { foreach ($op in @($e.options)) { if ($op.preview -and (Test-Path $op.preview) -and -not $M.thumbs[$op.preview]) { try { $bytes = [IO.File]::ReadAllBytes($op.preview); $M.thumbs[$op.preview] = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $bytes))) } catch { } } }
      $M.choice = @{ opts = @($e.options); idx = [int]$e.selected; title = $e.title; prompt = $e.prompt; confirmed = $false; at = Get-Date; rest = @{}; moveAt = [datetime]::MinValue; dir = 0 } }
    'intro' {
      $M.intro = @{ at = Get-Date; setting = $e.setting; img = @{} }
      foreach ($n in 'glow', 'icons', 'title', 'line', 'tagline') { $f = Join-Path $e.dir "intro_$n.png"; if (Test-Path $f) { $bytes = [IO.File]::ReadAllBytes($f); $M.intro.img[$n] = [Drawing.Image]::FromStream((New-Object IO.MemoryStream (, $bytes))) } }
    }
  }
}
function On-Line([string]$l) {
  if ($l.StartsWith('@AM ')) { try { On-Event ($l.Substring(4) | ConvertFrom-Json) } catch { }; return }
  $l = ($l -split "`r")[-1]
  if ($l -match '^\s*=+\s*$' -or -not $l.Trim()) { return }
  $M.log.Add($l.TrimEnd()); if ($M.log.Count -gt 400) { $M.log.RemoveAt(0) }
}

# ---------------- painting ----------------
function Brush($c) { New-Object Drawing.SolidBrush $c }
function Paint-Header($g) {
  [AmDraw]::Text($g, 'ARCADEMASTER TOOLS', $fnt.sub, [AmPal]::Magenta, (Rect ($pad + $SH * 0.14) ($SH * 0.03) ($SW * 0.6) ($SH * 0.035)), 'Near', 'Center')
  $spin = if ($M.done) { 0 } else { ((Get-Date) - $M.started).TotalMilliseconds / 12 % 360 }
  $live = if ($toolIcon -in 'repair') { $spin } else { 0 }
  [AmDraw]::Icon($g, $toolIcon, (Rect $pad ($SH * 0.035) ($SH * 0.115) ($SH * 0.115)), $toolColor, $live)
  [AmDraw]::Neon($g, $Title, $ffTitle, [Drawing.FontStyle]::Italic, [float]($SH / 11.5), [AmPal]::Cyan, (Rect ($pad + $SH * 0.135) ($SH * 0.06) ($SW - 2 * $pad) ($SH * 0.1)), 'Near')
  $g.FillRectangle((Brush ([AmPal]::A([AmPal]::Magenta, 220))), (Rect $pad ($SH * 0.172) ($SW - 2 * $pad) ([Math]::Max(2, $SH / 360))))
}
function Paint-Tiles($g, $tiles, [float]$y, [float]$h) {
  $n = @($tiles).Count; if (-not $n) { return }
  $gap = $SW * 0.015; $tw = ($SW - 2 * $pad - ($n - 1) * $gap) / $n
  for ($i = 0; $i -lt $n; $i++) {
    $t = $tiles[$i]; $r = Rect ($pad + $i * ($tw + $gap)) $y $tw $h
    [AmDraw]::Card($g, $r, [AmPal]::Faint, $h * 0.14, $false)
    $ic = $h * 0.56; if ($t.icon) { [AmDraw]::Icon($g, $t.icon, (Rect ($r.X + $h * 0.18) ($r.Y + ($h - $ic) / 2) $ic $ic), [AmPal]::Cyan, 0) }
    $tx = $r.X + $h * 0.3 + $ic
    $vf = Fit-Font $g "$($t.value)" @($fnt.tileV, $fnt.textB, $fnt.label) ($r.Right - $tx - $h * 0.1); [AmDraw]::Text($g, "$($t.value)", $vf, [AmPal]::Text, (Rect $tx ($r.Y + $h * 0.08) ($r.Right - $tx - $h * 0.1) ($h * 0.55)), 'Near', 'Center')
    [AmDraw]::Text($g, "$($t.label)", $fnt.chip, [AmPal]::Dim, (Rect $tx ($r.Y + $h * 0.6) ($r.Right - $tx) ($h * 0.3)), 'Near', 'Near')
  }
}
function Fit-Font($g, [string]$s, $fonts, [float]$maxW) { foreach ($f in $fonts) { if ($g.MeasureString($s, $f).Width -le $maxW) { return $f } }; return $fonts[-1] }
function Chip($g, [string]$s, [float]$x, [float]$y, $c) {
  $sz = $g.MeasureString($s, $fnt.chip); $r = Rect $x $y ($sz.Width + $SH * 0.02) ($sz.Height + $SH * 0.006)
  $p = [AmDraw]::Round($r, $r.Height / 2); $g.FillPath((Brush ([AmPal]::A($c, 45))), $p); $g.DrawPath((New-Object Drawing.Pen ([AmPal]::A($c, 200)), 2), $p)
  [AmDraw]::Text($g, $s, $fnt.chip, $c, $r, 'Center', 'Center'); return $r.Right + $SH * 0.01
}
function Paint-Devices($g, $devs, [float]$y, [float]$hMax) {
  $n = @($devs).Count; if (-not $n) { [AmDraw]::Text($g, 'No game controllers found', $fnt.text, [AmPal]::Amber, (Rect $pad $y ($SW - 2 * $pad) ($SH * 0.1)), 'Center', 'Center'); return }
  $cols = [Math]::Min(4, $n); $rows = [Math]::Ceiling($n / $cols); $gap = $SW * 0.015
  $cw = ($SW - 2 * $pad - ($cols - 1) * $gap) / $cols; $ch = [Math]::Min($SH * 0.25, ($hMax - ($rows - 1) * $gap) / $rows)
  $t = ((Get-Date) - $M.started).TotalSeconds
  for ($i = 0; $i -lt $n; $i++) {
    $d = $devs[$i]; $r = Rect ($pad + ($i % $cols) * ($cw + $gap)) ($y + [Math]::Floor($i / $cols) * ($ch + $gap)) $cw $ch
    $role = "$($d.role)"; $acc = switch -Regex ($role) { 'wheel' { [AmPal]::Magenta } 'handbrake|pedal|shifter' { [AmPal]::Amber } 'gun' { [AmPal]::Red } 'touch|display' { [AmPal]::Hex('9be7ff') } default { [AmPal]::Cyan } }
    [AmDraw]::Card($g, $r, $acc, $ch * 0.1, $true)
    $ic = $ch * 0.5; $kind = [AmDraw]::IconForRole($role)
    $live = if ($kind -eq 'wheel') { [Math]::Sin($t * 1.4) * 25 } elseif ($kind -in 'handbrake', 'pedals') { ([Math]::Sin($t * 2) + 1) / 2 } else { 0 }
    [AmDraw]::Icon($g, $kind, (Rect ($r.X + $ch * 0.1) ($r.Y + $ch * 0.12) $ic $ic), $acc, [float]$live)
    $tx = $r.X + $ch * 0.18 + $ic
    [AmDraw]::Text($g, $role.ToUpper(), $fnt.label, $acc, (Rect $tx ($r.Y + $ch * 0.1) ($r.Right - $tx - $ch * 0.06) ($ch * 0.2)), 'Near', 'Center')
    [AmDraw]::Text($g, "$($d.name)", $fnt.small, [AmPal]::Text, (Rect $tx ($r.Y + $ch * 0.3) ($r.Right - $tx - $ch * 0.06) ($ch * 0.34)), 'Near', 'Near')
    $cx = $r.X + $ch * 0.1; $cy = $r.Bottom - $ch * 0.24
    if ($d.ffb) { $cx = Chip $g 'FORCE FEEDBACK' $cx $cy ([AmPal]::Magenta) }
    if ($d.axes) { $cx = Chip $g $(if ($d.axes -eq 1) { '1 AXIS' } else { "$($d.axes) AXES" }) $cx $cy ([AmPal]::Cyan) }
    if ($d.buttons) { $cx = Chip $g $(if ($d.buttons -eq 1) { '1 BUTTON' } else { "$($d.buttons) BUTTONS" }) $cx $cy ([AmPal]::Cyan) }
  }
}
function Paint-Stats($g, $stats, [float]$y, [float]$h) {
  $n = @($stats).Count; if (-not $n) { return }; $gap = $SW * 0.015; $tw = ($SW - 2 * $pad - ($n - 1) * $gap) / $n
  for ($i = 0; $i -lt $n; $i++) {
    $s = $stats[$i]; $c = switch ($s.tone) { 'good' { [AmPal]::Green } 'warn' { [AmPal]::Amber } 'bad' { [AmPal]::Red } default { [AmPal]::Dim } }
    $r = Rect ($pad + $i * ($tw + $gap)) $y $tw $h; [AmDraw]::Card($g, $r, $c, $h * 0.14, $false)
    [AmDraw]::Check($g, (Rect ($r.X + $h * 0.2) ($r.Y + $h * 0.25) ($h * 0.5) ($h * 0.5)), $(if ($s.tone -eq 'good') { 2 } elseif ($s.tone -eq 'bad') { 3 } else { 0 }), 0)
    [AmDraw]::Text($g, "$($s.value)", $fnt.tileV, $c, (Rect ($r.X + $h * 0.9) $r.Y ($h * 1.2) $h), 'Near', 'Center')
    [AmDraw]::Text($g, "$($s.label)", $fnt.textB, [AmPal]::Text, (Rect ($r.X + $h * 2.0) $r.Y ($tw - $h * 2.1) $h), 'Near', 'Center')
  }
}
function Paint-Toggle($g, [float]$y, [float]$h) {
  $tg = $M.toggle; $on = [bool]$tg.on; $acc = if ($on) { [AmPal]::Green } else { [AmPal]::Dim }
  $hasDisp = $M.displays -and @($M.displays.displays).Count
  $left = if ($hasDisp) { $SW * 0.5 } else { $SW }
  $ic = $h * 0.36; $cx = $left / 2
  $t = ((Get-Date) - $M.started).TotalSeconds
  [AmDraw]::Icon($g, $tg.icon, (Rect ($cx - $ic / 2) $y $ic $ic), $(if ($on) { $toolColor } else { [AmPal]::Dim }), $(if ($tg.icon -eq 'ffb' -and $on) { [float]([Math]::Sin($t * 6) * 12) } elseif ($tg.icon -eq 'perf') { [float](0.55 + 0.35 * [Math]::Sin($t * 2)) } else { 0 }))
  [AmDraw]::Text($g, "$($tg.label)", $fnt.textB, [AmPal]::Text, (Rect 0 ($y + $ic + $h * 0.02) $left ($h * 0.1)), 'Center', 'Center')
  $tgW = $SH * 0.36; $tgH = $tgW * 0.42
  $k = [Math]::Max(0, [Math]::Min(1, ((Get-Date) - $M.toggleAt).TotalSeconds / 0.45)); $k = 1 - [Math]::Pow(1 - $k, 3); $pos = if ($on) { $k } else { 1 - $k }
  [AmDraw]::ToggleAt($g, (Rect ($cx - $tgW / 2) ($y + $ic + $h * 0.14) $tgW $tgH), [float]$pos, [AmPal]::Green, $fnt.toggle)
  [AmDraw]::Text($g, "$($tg.detail)", $fnt.text, [AmPal]::Dim, (Rect ($pad) ($y + $ic + $h * 0.16 + $tgH) ($left - 2 * $pad) ($h * 0.16)), 'Center', 'Center')
  if ($hasDisp) {
    $ds = @($M.displays.displays); $used = [int]$M.displays.used; $maxW = ($ds | Measure-Object w -Sum).Sum; $sc = ($SW * 0.4) / [Math]::Max(1, $maxW + 200)
    $x = $SW * 0.55; $i = 0
    foreach ($d in ($ds | Sort-Object { -[int]$_.primary })) {
      $dw = $d.w * $sc; $dh = $d.h * $sc; $r = Rect $x ($y + $h * 0.15) $dw $dh
      $active = $i -lt $used; $c = if ($i -eq 0) { [AmPal]::Cyan } elseif ($active) { [AmPal]::Magenta } else { [AmPal]::Faint }
      [AmDraw]::Card($g, $r, $c, 8, $active)
      [AmDraw]::Text($g, $(if ($i -eq 0) { 'MAIN' } elseif ($active) { 'SECOND' } else { 'NOT USED' }), $fnt.textB, $c, $r, 'Center', 'Center')
      [AmDraw]::Text($g, "$($d.w) x $($d.h)", $fnt.small, [AmPal]::Dim, (Rect $r.X ($r.Bottom + 6) $r.Width ($SH * 0.04)), 'Center', 'Near')
      $x += $dw + 40 * $sc + $SW * 0.02; $i++
    }
  }
}
function Paint-Steps($g, [float]$y, [float]$h) {
  $rowH = [Math]::Min($SH * 0.095, $h / [Math]::Max(1, $M.steps.Count)); $i = 0; $phase = [float](((Get-Date) - $M.started).TotalMilliseconds / 3 % 360)
  $hasTiles = $M.tiles -and @($M.tiles).Count -gt 0; $lw = if ($hasTiles) { $SW * 0.5 } else { $SW - 2 * $pad }
  foreach ($k in $M.steps.Keys) {
    $s = $M.steps[$k]; $st = switch ($s.status) { 'run' { 1 } 'ok' { 2 } 'fail' { 3 } default { 0 } }
    $r = Rect $pad ($y + $i * $rowH) $lw ($rowH * 0.86)
    if ($st -eq 1) { [AmDraw]::Card($g, $r, [AmPal]::Cyan, $rowH * 0.2, $true) }
    [AmDraw]::Check($g, (Rect ($r.X + $rowH * 0.18) ($r.Y + $rowH * 0.16) ($rowH * 0.54) ($rowH * 0.54)), $st, $phase)
    $c = switch ($st) { 0 { [AmPal]::Dim } 1 { [AmPal]::Text } 2 { [AmPal]::Text } 3 { [AmPal]::Red } }
    $sf = Fit-Font $g "$($s.label)" @($fnt.textB, $fnt.label, $fnt.chip) ($r.Width - $rowH * 1.1); [AmDraw]::Text($g, "$($s.label)", $sf, $c, (Rect ($r.X + $rowH * 0.95) $r.Y ($r.Width - $rowH) $r.Height), 'Near', 'Center')
    $i++
  }
  if ($hasTiles) {
    $tl = @($M.tiles); $tx = $SW * 0.56; $tw = ($SW - $pad - $tx - $SW * 0.015) / 2; $th = $SH * 0.16
    for ($j = 0; $j -lt $tl.Count; $j++) {
      $t = $tl[$j]; $r = Rect ($tx + ($j % 2) * ($tw + $SW * 0.015)) ($y + [Math]::Floor($j / 2) * ($th + $SW * 0.015)) $tw $th
      [AmDraw]::Card($g, $r, [AmPal]::Amber, $th * 0.12, $true)
      [AmDraw]::Icon($g, $t.icon, (Rect ($r.X + $th * 0.15) ($r.Y + $th * 0.2) ($th * 0.6) ($th * 0.6)), [AmPal]::Amber, 0)
      [AmDraw]::Text($g, "$($t.value)", $fnt.tileV, [AmPal]::Text, (Rect ($r.X + $th * 0.9) ($r.Y + $th * 0.05) ($tw - $th) ($th * 0.6)), 'Near', 'Center')
      [AmDraw]::Text($g, "$($t.label)$($t.suffix)", $fnt.chip, [AmPal]::Dim, (Rect ($r.X + $th * 0.9) ($r.Y + $th * 0.62) ($tw - $th) ($th * 0.3)), 'Near', 'Near')
    }
  }
}
function Paint-Images($g, [float]$y, [float]$h) {
  [AmDraw]::Text($g, $M.imagesTitle, $fnt.textB, [AmPal]::Violet, (Rect $pad $y ($SW - 2 * $pad) ($SH * 0.05)), 'Near', 'Center')
  $imgs = @($M.images); $cols = 3; $gap = $SW * 0.02; $cw = [Math]::Min(($SW - 2 * $pad - ($cols - 1) * $gap) / $cols, (($h - $SH * 0.09 - $gap) / 2) * 16 / 9); $chh = $cw * 9 / 16; $x0 = ($SW - ($cols * $cw + ($cols - 1) * $gap)) / 2
  $el = ((Get-Date) - $M.imagesAt).TotalSeconds
  for ($i = 0; $i -lt [Math]::Min(6, $imgs.Count); $i++) {
    $a = [Math]::Max(0, [Math]::Min(1, ($el - $i * 0.12) / 0.4)); if ($a -le 0) { continue }
    $sc = 0.9 + 0.1 * $a; $bw = $cw * $sc; $bh = $chh * $sc
    $cx = $x0 + ($i % $cols) * ($cw + $gap) + ($cw - $bw) / 2; $cy = $y + $SH * 0.07 + [Math]::Floor($i / $cols) * ($chh + $gap) + ($chh - $bh) / 2
    $r = Rect $cx $cy $bw $bh; $th = $M.thumbs[$imgs[$i]]
    if ($th) { $st = $g.Save(); $p = [AmDraw]::Round($r, $SH * 0.012); $g.SetClip($p); $ia = New-Object Drawing.Imaging.ImageAttributes; $cm = New-Object Drawing.Imaging.ColorMatrix; $cm.Matrix33 = [float]$a; $ia.SetColorMatrix($cm)
      $g.DrawImage($th, [Drawing.Rectangle]::Round($r), 0, 0, $th.Width, $th.Height, [Drawing.GraphicsUnit]::Pixel, $ia); $g.Restore($st) }
    $p2 = [AmDraw]::Round($r, $SH * 0.012); $g.DrawPath((New-Object Drawing.Pen ([AmPal]::A([AmPal]::Violet, [int](200 * $a))), 3), $p2)
  }
}
# Wheel Setup: prompt + meters on the left, live controls on the right
function Get-LiveJoys {
  if (((Get-Date) - $M.joyAt).TotalSeconds -gt 3) { $M.joy = [AmJoyLive]::List(); $M.joyAt = Get-Date } else { foreach ($d in $M.joy) { [void][AmJoyLive]::Read($d) } }
  return $M.joy
}
$wizButtons = @(@{ label = 'SKIP'; key = 'S' }, @{ label = 'REDO'; key = 'R' }, @{ label = 'BACK'; key = 'B' }, @{ label = 'ACCEPT'; key = 'Enter' }, @{ label = 'FINISH'; key = 'Q' })
function Get-Travel($d, [int]$a) {
  $k = "$($d.Id)/$a"; if (-not $M.rest.ContainsKey($k)) { $M.rest[$k] = $d.Axis[$a] }
  return [Math]::Min(1, [Math]::Abs($d.Axis[$a] - $M.rest[$k]) / $(if ([Math]::Abs($M.rest[$k]) -gt 0.8) { 2 } else { 1 }))
}
function Paint-Wizard($g, [float]$y, [float]$h) {
  $wz = $M.wiz; $lw = $SW * 0.54
  if ($M.wizEnd) {
    [AmDraw]::Check($g, (Rect $pad $y ($SH * 0.09) ($SH * 0.09)), $(if ($M.wizEnd.ok) { 2 } else { 3 }), 0)
    [AmDraw]::Text($g, $(if ($M.wizEnd.ok) { 'WHEEL PROFILE SAVED' } else { 'WHEEL SETUP STOPPED' }), $fnt.tileV, [AmPal]::Text, (Rect ($pad + $SH * 0.12) $y $lw ($SH * 0.09)), 'Near', 'Center')
    $y2 = $y + $SH * 0.12
  } elseif ($wz.step) {
    $s = $wz.step
    [AmDraw]::Text($g, ("STEP {0} OF {1}" -f $s.index, $s.total), $fnt.label, [AmPal]::Amber, (Rect $pad $y $lw ($SH * 0.04)), 'Near', 'Center')
    [AmDraw]::Bar($g, (Rect ($pad + $SW * 0.13) ($y + $SH * 0.012) ($lw - $SW * 0.14) ($SH * 0.016)), [float]($s.index / [Math]::Max(1, $s.total)), [AmPal]::Amber)
    $name = ($s.control -replace '^P\d+\.', '' -creplace '(?<=[a-z])(?=[A-Z])', ' ').ToUpper()
    [AmDraw]::Neon($g, $name, $ffTitle, [Drawing.FontStyle]::Italic, [float]($SH / 12), [AmPal]::Magenta, (Rect $pad ($y + $SH * 0.05) $lw ($SH * 0.1)), 'Near')
    [AmDraw]::Text($g, "$($s.prompt)", $fnt.text, [AmPal]::Text, (Rect $pad ($y + $SH * 0.16) $lw ($SH * 0.11)), 'Near', 'Near')
    if ($s.hint) { [AmDraw]::Text($g, "$($s.hint)", $fnt.small, [AmPal]::Dim, (Rect $pad ($y + $SH * 0.27) $lw ($SH * 0.05)), 'Near', 'Near') }
    if ($wz.axis -and "$($s.kind)" -like 'axis*') {
      $v = [Math]::Min(1, $wz.axis.travel / [Math]::Max(1, $wz.axis.need))
      [AmDraw]::Text($g, ("MOVEMENT  {0} {1}" -f $wz.axis.device, $wz.axis.axis).ToUpper(), $fnt.chip, [AmPal]::Dim, (Rect $pad ($y + $SH * 0.33) $lw ($SH * 0.03)), 'Near', 'Center')
      [AmDraw]::Bar($g, (Rect $pad ($y + $SH * 0.365) $lw ($SH * 0.03)), [float]$v, $(if ($v -ge 1) { [AmPal]::Green } else { [AmPal]::Magenta }))
    }
    $y2 = $y + $SH * 0.42
  } else {
    [AmDraw]::Text($g, 'Getting the controls ready...', $fnt.text, [AmPal]::Dim, (Rect $pad $y $lw ($SH * 0.08)), 'Near', 'Center'); $y2 = $y + $SH * 0.1
  }
  # captured so far (latest first)
  $res = @($wz.results); $rowH = $SH * 0.042; $max = [Math]::Max(0, [int](($y + $h - $y2) / $rowH))
  $k = 0
  for ($i = $res.Count - 1; $i -ge 0 -and $k -lt $max; $i--) {
    $e = $res[$i]; $ry = $y2 + $k * $rowH
    [AmDraw]::Check($g, (Rect $pad ($ry + $rowH * 0.15) ($rowH * 0.7) ($rowH * 0.7)), $(if ($e.ok) { 2 } else { 0 }), 0)
    [AmDraw]::Text($g, (($e.control -creplace '(?<=[a-z])(?=[A-Z])', ' ').ToUpper()), $fnt.textB, $(if ($e.ok) { [AmPal]::Text } else { [AmPal]::Dim }), (Rect ($pad + $rowH) $ry ($lw * 0.45) $rowH), 'Near', 'Center')
    [AmDraw]::Text($g, "$($e.value)", $fnt.textB, $(if ($e.ok) { [AmPal]::Green } else { [AmPal]::Dim }), (Rect ($pad + $rowH + $lw * 0.45) $ry ($lw * 0.5) $rowH), 'Near', 'Center')
    $k++
  }
  # live controls
  $joys = @(Get-LiveJoys); $rx = $SW * 0.6; $rw = $SW - $pad - $rx
  $wheel = $joys | Where-Object { $_.Name -match '(?i)wheel|racing|g29|g920|g923|driving|t300|fanatec' } | Select-Object -First 1
  if (-not $wheel) { $wheel = $joys | Sort-Object Buttons -Descending | Select-Object -First 1 }
  if ($wheel) {
    $ws = [Math]::Min($rw * 0.5, $h * 0.5)
    [AmDraw]::Card($g, (Rect $rx $y $rw ($h * 0.98)), [AmPal]::Magenta, $SH * 0.02, $true)
    [AmDraw]::Icon($g, 'wheel', (Rect ($rx + $SH * 0.03) ($y + $SH * 0.03) $ws $ws), [AmPal]::Magenta, [float]($wheel.Axis[0] * 450))
    [AmDraw]::Text($g, ("{0:+0;-0;0} deg" -f ($wheel.Axis[0] * 450)), $fnt.label, [AmPal]::Dim, (Rect ($rx + $SH * 0.03) ($y + $SH * 0.035 + $ws) $ws ($SH * 0.04)), 'Center', 'Center')
    # pedal bars: every other axis of the wheel, plus axes of other devices
    $bx = $rx + $SH * 0.06 + $ws; $bw = $rx + $rw - $bx - $SH * 0.03; $by = $y + $SH * 0.04; $bh = $SH * 0.026
    # bars show travel away from where each axis rested when the page opened (pedals rest at an extreme)
    $bars = @(); for ($a = 1; $a -lt [Math]::Min(6, [Math]::Max(1, $wheel.Axes)); $a++) { $bars += , @("AXIS $('XYZRUV'[$a])", (Get-Travel $wheel $a)) }
    foreach ($o in $joys) { if ($o.Id -ne $wheel.Id) { for ($a = 0; $a -lt [Math]::Min(2, [Math]::Max(1, $o.Axes)); $a++) { $bars += , @(("{0} {1}" -f $o.Name, 'XYZRUV'[$a]).ToUpper(), (Get-Travel $o $a)) } } }
    foreach ($bar in ($bars | Select-Object -First 7)) {
      [AmDraw]::Text($g, $bar[0], $fnt.chip, [AmPal]::Dim, (Rect $bx $by $bw ($SH * 0.025)), 'Near', 'Center')
      [AmDraw]::Bar($g, (Rect $bx ($by + $SH * 0.027) $bw $bh), [float]$bar[1], $(if ($bar[1] -gt 0.5) { [AmPal]::Green } else { [AmPal]::Amber })); $by += $SH * 0.066
    }
    # buttons
    $nb = [Math]::Min(32, [Math]::Max(1, $wheel.Buttons)); $cols = 11; $dot = [Math]::Min(($rw - $SH * 0.06) / $cols, $SH * 0.045)
    $gy = $y + $h * 0.98 - $SH * 0.03 - [Math]::Ceiling($nb / $cols) * $dot
    [AmDraw]::Text($g, 'BUTTONS', $fnt.chip, [AmPal]::Dim, (Rect ($rx + $SH * 0.03) ($gy - $SH * 0.03) $rw ($SH * 0.025)), 'Near', 'Center')
    for ($b = 0; $b -lt $nb; $b++) {
      $on = ($wheel.ButtonBits -band ([uint32]1 -shl $b)) -ne 0
      $r = Rect ($rx + $SH * 0.03 + ($b % $cols) * $dot) ($gy + [Math]::Floor($b / $cols) * $dot) ($dot * 0.8) ($dot * 0.8)
      $g.FillEllipse((Brush $(if ($on) { [AmPal]::Green } else { [AmPal]::Faint })), $r)
      [AmDraw]::Text($g, "$($b + 1)", $fnt.chip, $(if ($on) { [AmPal]::Bg } else { [AmPal]::Dim }), $r, 'Center', 'Center')
    }
  }
}
function Get-ChoiceRects([float]$y, [float]$h) {
  $n = @($M.choice.opts).Count; $pv = @($M.choice.opts | Where-Object { $_.preview }).Count -gt 0; $cols = if ($pv) { 3 } else { 4 }; $rows = [Math]::Ceiling($n / $cols); $gap = $SW * 0.012
  $cw = ($SW - 2 * $pad - ($cols - 1) * $gap) / $cols; $ch = [Math]::Min($(if ($pv) { $SH * 0.3 } else { $SH * 0.17 }), ($h - $SH * 0.06 - ($rows - 1) * $gap) / $rows)
  for ($i = 0; $i -lt $n; $i++) { Rect ($pad + ($i % $cols) * ($cw + $gap)) ($y + $SH * 0.06 + [Math]::Floor($i / $cols) * ($ch + $gap)) $cw $ch }
}
function Paint-Choice($g, [float]$y, [float]$h) {
  $c = $M.choice
  [AmDraw]::Text($g, "$($c.title)", $fnt.textB, [AmPal]::Text, (Rect $pad $y ($SW * 0.5) ($SH * 0.05)), 'Near', 'Center')
  [AmDraw]::Text($g, "$($c.prompt)", $fnt.small, [AmPal]::Dim, (Rect ($SW * 0.45) $y ($SW * 0.55 - $pad) ($SH * 0.05)), 'Far', 'Center')
  $rects = @(Get-ChoiceRects $y $h); $pulse = 0.5 + 0.5 * [Math]::Sin(((Get-Date) - $c.at).TotalSeconds * 5)
  for ($i = 0; $i -lt $rects.Count; $i++) {
    $o = $c.opts[$i]; $r = $rects[$i]; $sel = $i -eq $c.idx; $col = [AmPal]::Hex($o.color)
    if ($sel) { $r = [Drawing.RectangleF]::Inflate($r, $SH * 0.004, $SH * 0.004) }
    [AmDraw]::Card($g, $r, $(if ($sel) { $col } else { [AmPal]::Faint }), $r.Height * 0.12, $sel)
    if ($sel -and $c.confirmed) { [AmDraw]::Check($g, (Rect ($r.Right - $r.Height * 0.32) ($r.Y + $r.Height * 0.08) ($r.Height * 0.24) ($r.Height * 0.24)), 2, 0) }
    if ($o.preview -and $M.thumbs[$o.preview]) {
      # theme preview fills the card above the label
      $im = $M.thumbs[$o.preview]; $ir = Rect ($r.X + $r.Height * 0.05) ($r.Y + $r.Height * 0.05) ($r.Width - $r.Height * 0.1) ($r.Height * 0.62)
      $st0 = $g.Save(); $g.SetClip([AmDraw]::Round($ir, $r.Height * 0.04)); $g.DrawImage($im, $ir); $g.Restore($st0)
      [AmDraw]::Text($g, "$($o.label)", $fnt.textB, $(if ($sel) { [AmPal]::Text } else { [AmPal]::Dim }), (Rect ($r.X + $r.Height * 0.06) ($r.Y + $r.Height * 0.69) ($r.Width - $r.Height * 0.12) ($r.Height * 0.15)), 'Near', 'Center')
      [AmDraw]::Text($g, "$($o.sub)", $fnt.chip, $(if ($sel) { $col } else { [AmPal]::Faint }), (Rect ($r.X + $r.Height * 0.06) ($r.Y + $r.Height * 0.84) ($r.Width - $r.Height * 0.12) ($r.Height * 0.12)), 'Near', 'Center')
      continue
    }
    $ics = @($o.icons); $isz = $r.Height * 0.38; $ix = $r.X + $r.Height * 0.1
    for ($k = 0; $k -lt [Math]::Min(4, $ics.Count); $k++) {
      $icol = if ($k -ge [Math]::Ceiling($ics.Count / 2) -and $o.color2 -ne $o.color) { [AmPal]::Hex($o.color2) } else { $col }
      [AmDraw]::Icon($g, $ics[$k], (Rect $ix ($r.Y + $r.Height * 0.1) $isz $isz), $(if ($sel) { $icol } else { [AmPal]::A($icol, 150) }), 0); $ix += $isz * 1.08
    }
    $lf = Fit-Font $g "$($o.label)" @($fnt.textB, $fnt.label, $fnt.chip) ($r.Width - $r.Height * 0.2)
    [AmDraw]::Text($g, "$($o.label)", $lf, $(if ($sel) { [AmPal]::Text } else { [AmPal]::Dim }), (Rect ($r.X + $r.Height * 0.1) ($r.Y + $r.Height * 0.52) ($r.Width - $r.Height * 0.2) ($r.Height * 0.24)), 'Near', 'Center')
    [AmDraw]::Text($g, "$($o.sub)", $fnt.chip, $(if ($sel) { $col } else { [AmPal]::Faint }), (Rect ($r.X + $r.Height * 0.1) ($r.Y + $r.Height * 0.74) ($r.Width - $r.Height * 0.2) ($r.Height * 0.2)), 'Near', 'Center')
  }
}
# preview of the boot title card, composited like splash.xml (1920x1080 space scaled into the stage)
function Paint-Intro($g, [float]$y, [float]$h) {
  $im = $M.intro.img; $ph = $h * 0.9; $pw = $ph * 16 / 9; $px = ($SW - $pw) / 2; $s = $pw / 1920
  $box = Rect $px $y $pw $ph; $st = $g.Save(); $g.SetClip([AmDraw]::Round($box, $SH * 0.012)); $g.FillRectangle((Brush ([Drawing.Color]::Black)), $box)
  $el = ((Get-Date) - $M.intro.at).TotalSeconds
  function A([double]$t0, [double]$d) { [float][Math]::Max(0, [Math]::Min(1, ($el - $t0) / $d)) }
  function Put($name, [float]$cx, [float]$cy, [float]$alpha, [float]$scale = 1, [float]$wOverride = 0) {
    $i = $im[$name]; if (-not $i -or $alpha -le 0) { return }
    $w = if ($wOverride) { $wOverride } else { $i.Width * $scale }; $hh = $i.Height * $scale
    $ia = New-Object Drawing.Imaging.ImageAttributes; $cm = New-Object Drawing.Imaging.ColorMatrix; $cm.Matrix33 = $alpha; $ia.SetColorMatrix($cm)
    $r = [Drawing.Rectangle]::Round((Rect ($px + ($cx - $w / 2) * $s) ($y + ($cy - $hh / 2) * $s) ($w * $s) ($hh * $s)))
    $g.DrawImage($i, $r, 0, 0, $i.Width, $i.Height, [Drawing.GraphicsUnit]::Pixel, $ia)
  }
  $loop = $el % 4.5; $el = $loop   # replay the card every 4.5 s
  Put 'glow' 960 540 (A 0 0.6)
  $ai = A 0.1 0.6; Put 'icons' 960 ([float](430 - 50 * $ai)) $ai
  $at = A 0.5 0.3; Put 'title' 960 690 $at ([float](1.2 - 0.2 * $at))
  Put 'line' 960 800 1 1 ([float](10 + 1590 * (A 0.8 0.5)))
  Put 'tagline' 960 860 (A 1.05 0.5)
  $g.Restore($st); $g.DrawPath((New-Object Drawing.Pen ([AmPal]::A([AmPal]::Cyan, 200)), 3), [AmDraw]::Round($box, $SH * 0.012))
  [AmDraw]::Text($g, ("BOOT INTRO PREVIEW   -   cabinetType = {0}" -f $M.intro.setting), $fnt.chip, [AmPal]::Dim, (Rect $px ($y + $ph + $SH * 0.008) $pw ($SH * 0.03)), 'Center', 'Center')
}
# Settings rows. An item may carry (all optional, so the old switch-only list still draws):
#   group    a header row is drawn where the group changes      kind     switch (default) | cycle | info | action
#   value    text shown for cycle / info / action rows           confirm  false = no second press (default: true)
# The list scrolls so the selected row (and the header above it) stays on screen.
function Get-SettingRows([float]$y, [float]$h) {
  $st = $M.settings; $items = @($st.items); $rows = New-Object Collections.ArrayList; $grp = $null
  for ($i = 0; $i -lt $items.Count; $i++) {
    $g0 = "$($items[$i].group)"; if ($g0 -and $g0 -ne $grp) { [void]$rows.Add(@{ t = 'h'; text = $g0; i = -1 }) }; $grp = $g0
    [void]$rows.Add(@{ t = 'i'; i = $i })
  }
  [void]$rows.Add(@{ t = 'd'; i = $items.Count })
  $rh = $SH * 0.058; $top = $y + $SH * 0.06; $vis = [Math]::Max(3, [int][Math]::Floor(($h - $SH * 0.06) / $rh))
  $selRow = 0; for ($r = 0; $r -lt $rows.Count; $r++) { if ($rows[$r].i -eq $st.idx) { $selRow = $r } }
  $sc = [int]$st.scroll
  if ($selRow - 1 -lt $sc) { $sc = [Math]::Max(0, $selRow - 1) }
  if ($selRow -ge $sc + $vis) { $sc = $selRow - $vis + 1 }
  $sc = [Math]::Max(0, [Math]::Min($sc, $rows.Count - $vis)); $st.scroll = $sc
  $out = New-Object Collections.ArrayList
  for ($r = $sc; $r -lt [Math]::Min($rows.Count, $sc + $vis); $r++) { $row = $rows[$r]; $row.rect = Rect $pad ($top + ($r - $sc) * $rh) ($SW - 2 * $pad - $SH * 0.02) ($rh * 0.9); [void]$out.Add($row) }
  return @{ rows = $out; total = $rows.Count; first = $sc; vis = $vis; top = $top; rh = $rh }
}
function Paint-Settings($g, [float]$y, [float]$h) {
  $st = $M.settings; $items = @($st.items)
  [AmDraw]::Text($g, "$($st.message)", $fnt.textB, $(if ($st.busy) { [AmPal]::Amber } elseif ($st.armed) { [AmPal]::Red } else { [AmPal]::Dim }), (Rect $pad $y ($SW - 2 * $pad) ($SH * 0.05)), 'Near', 'Center')
  $L = Get-SettingRows $y $h
  foreach ($row in $L.rows) {
    $r = $row.rect
    if ($row.t -eq 'h') {
      [AmDraw]::Text($g, $row.text, $fnt.label, [AmPal]::Magenta, (Rect ($r.X + $r.Height * 0.1) $r.Y ($r.Width * 0.6) $r.Height), 'Near', 'Far')
      $g.FillRectangle((Brush ([AmPal]::A([AmPal]::Magenta, 120))), (Rect $r.X ($r.Bottom - 2) $r.Width 2)); continue
    }
    $sel = $row.i -eq $st.idx
    if ($row.t -eq 'd') {
      [AmDraw]::Card($g, $r, $(if ($sel) { [AmPal]::Green } else { [AmPal]::Faint }), $r.Height * 0.3, $sel)
      [AmDraw]::Text($g, 'DONE', $fnt.btn, $(if ($sel) { [AmPal]::Green } else { [AmPal]::Dim }), $r, 'Center', 'Center'); continue
    }
    $it = $items[$row.i]; $kind = if ($it.kind) { "$($it.kind)" } else { 'switch' }
    [AmDraw]::Card($g, $r, $(if ($st.armed -eq $it.id) { [AmPal]::Red } elseif ($sel) { [AmPal]::Amber } else { [AmPal]::Faint }), $r.Height * 0.2, $sel)
    $lw = $r.Width * 0.33; $lf = Fit-Font $g "$($it.label)" @($fnt.textB, $fnt.label, $fnt.chip) ($lw - $r.Height * 0.3)
    [AmDraw]::Text($g, "$($it.label)", $lf, $(if ($sel) { [AmPal]::Text } else { [AmPal]::Dim }), (Rect ($r.X + $r.Height * 0.3) $r.Y $lw $r.Height), 'Near', 'Center')
    $cw = $r.Height * 4.2
    [AmDraw]::Text($g, "$($it.detail)", $fnt.small, [AmPal]::Dim, (Rect ($r.X + $r.Height * 0.3 + $lw) $r.Y ($r.Width - $lw - $cw - $r.Height * 0.8) $r.Height), 'Near', 'Center')
    $tr = Rect ($r.Right - $cw - $r.Height * 0.2) ($r.Y + $r.Height * 0.14) $cw ($r.Height * 0.72)
    if ($sel -and $st.busy) { [AmDraw]::Check($g, (Rect ($tr.Right - $tr.Height * 1.6) $tr.Y $tr.Height $tr.Height), 1, [float](((Get-Date) - $st.at).TotalMilliseconds / 3 % 360)); continue }
    switch ($kind) {
      'switch' { $tw = $r.Height * 1.7; [AmDraw]::Toggle($g, (Rect ($tr.Right - $tw) $tr.Y $tw $tr.Height), [bool]$it.on, [AmPal]::Green, $fnt.label) }
      'info' { [AmDraw]::Text($g, "$($it.value)", (Fit-Font $g "$($it.value)" @($fnt.label, $fnt.chip) $cw), [AmPal]::Cyan, $tr, 'Far', 'Center') }
      default {
        # cycle: the value in a pill (each press steps to the next preset); action: a button
        $c = if ($kind -eq 'action') { [AmPal]::Red } else { [AmPal]::Cyan }
        $p = [AmDraw]::Round($tr, $tr.Height / 2); $g.FillPath((Brush ([AmPal]::A($c, $(if ($sel) { 70 } else { 35 })))), $p); $g.DrawPath((New-Object Drawing.Pen ([AmPal]::A($c, 210)), 2), $p)
        $txt = "$($it.value)" + $(if ($kind -eq 'cycle') { '  >' } else { '' })
        [AmDraw]::Text($g, $txt, (Fit-Font $g $txt @($fnt.label, $fnt.chip) ($cw - $tr.Height * 0.5)), $(if ($sel) { [AmPal]::Text } else { $c }), $tr, 'Center', 'Center')
      }
    }
  }
  # scroll bar when the list is longer than the page
  if ($L.total -gt $L.vis) {
    $bx = $SW - $pad - $SH * 0.008; $bh = $L.vis * $L.rh
    $g.FillRectangle((Brush ([AmPal]::A([AmPal]::Faint, 160))), (Rect $bx $L.top ($SH * 0.006) $bh))
    $g.FillRectangle((Brush ([AmPal]::A([AmPal]::Amber, 220))), (Rect $bx ($L.top + $bh * $L.first / $L.total) ($SH * 0.006) ([Math]::Max($SH * 0.02, $bh * $L.vis / $L.total))))
  }
}
function Activate-Setting {
  $st = $M.settings; if (-not $st -or $st.busy -or $st.done) { return }
  if (((Get-Date) - $st.at).TotalMilliseconds -lt 700) { return }   # ignore presses that arrive while the list (re)loads
  if ($st.idx -ge @($st.items).Count) { $st.done = $true; Send-WizKey 'CHOICE:done'; return }
  $it = $st.items[$st.idx]; $kind = if ($it.kind) { "$($it.kind)" } else { 'switch' }
  if ($kind -eq 'info') { $st.message = "$($it.label): $($it.detail)"; return }
  # Windows switches and actions need a confirming second press on the same row within 4 s (confirm = false: one press)
  $needs = if ($null -ne $it.confirm) { [bool]$it.confirm } else { $true }
  if ($needs -and ($st.armed -ne $it.id -or ((Get-Date) - $st.armedAt).TotalSeconds -gt 4)) {
    $st.armed = $it.id; $st.armedAt = Get-Date
    $st.message = switch ($kind) { 'switch' { "PRESS AGAIN TO TURN {0} {1}" -f $it.label, $(if ($it.on) { 'OFF' } else { 'ON' }) } 'action' { "PRESS AGAIN TO {0}" -f $it.label } default { "PRESS AGAIN TO CHANGE {0}" -f $it.label } }
    return
  }
  $st.armed = $null
  $st.busy = $true; $st.at = Get-Date; $st.message = "changing $($it.label) ..."; Send-WizKey ('TOGGLE:' + $it.id)
}
function Paint-Log($g, [float]$y, [float]$h) {
  $lh = $fnt.mono.GetHeight($g); $n = [Math]::Max(1, [int]($h / $lh)); $lines = @($M.log | Select-Object -Last $n); $i = 0
  foreach ($l in $lines) {
    $c = if ($l -like '!ERR *') { [AmPal]::Red } elseif ($l -match '(?i)\b(error|failed)\b') { [AmPal]::Red } elseif ($l -match '(?i)\bwarn') { [AmPal]::Amber } else { [AmPal]::Text }
    [AmDraw]::Text($g, ($l -replace '^!ERR ', ''), $fnt.mono, $c, (Rect $pad ($y + $i * $lh) ($SW - 2 * $pad) $lh), 'Near', 'Near'); $i++
  }
}
function Get-ButtonRects {
  $n = $wizButtons.Count; $gap = $SW * 0.015; $bw = [Math]::Min($SW * 0.16, ($SW - 2 * $pad - ($n - 1) * $gap) / $n); $bh = $SH * 0.075
  $x0 = ($SW - ($n * $bw + ($n - 1) * $gap)) / 2
  for ($i = 0; $i -lt $n; $i++) { Rect ($x0 + $i * ($bw + $gap)) ($SH * 0.875) $bw $bh }
}
function Paint-Footer($g) {
  $now = Get-Date
  if ($M.settings -and -not $M.settings.done -and -not $M.done) {
    [AmDraw]::Text($g, "TURN THE WHEEL / STICK OR TAP TO PICK  -  PRESS A BUTTON TO CHANGE  -  DONE WHEN FINISHED", $fnt.foot, [AmPal]::Amber, (Rect $pad ($SH * 0.875) ($SW - 2 * $pad) ($SH * 0.075)), 'Center', 'Center'); return
  }
  if ($M.choice -and -not $M.choice.confirmed -and -not $M.done) {
    [AmDraw]::Text($g, "TURN THE WHEEL / JOYSTICK OR TAP TO CHOOSE   -   PRESS A BUTTON TO CONFIRM", $fnt.foot, [AmPal]::Amber, (Rect $pad ($SH * 0.875) ($SW - 2 * $pad) ($SH * 0.075)), 'Center', 'Center'); return
  }
  if ($M.wiz -and -not $M.wizEnd -and -not $M.done) {
    $rects = @(Get-ButtonRects)
    for ($i = 0; $i -lt $rects.Count; $i++) {
      $c = @([AmPal]::Amber, [AmPal]::Cyan, [AmPal]::Cyan, [AmPal]::Green, [AmPal]::Magenta)[$i]
      [AmDraw]::Card($g, $rects[$i], $c, $rects[$i].Height * 0.3, $false); [AmDraw]::Text($g, $wizButtons[$i].label, $fnt.btn, $c, $rects[$i], 'Center', 'Center')
    }
    return
  }
  $fr = Rect $pad ($SH * 0.875) ($SW - 2 * $pad) ($SH * 0.075)
  if (-not $M.done) {
    $dots = '.' * (1 + [int](($now - $M.started).TotalMilliseconds / 400) % 3)
    [AmDraw]::Text($g, "WORKING$dots", $fnt.foot, [AmPal]::Amber, $fr, 'Center', 'Center')
  } else {
    $left = [Math]::Max(0, [int][Math]::Ceiling(($M.closeAt - $now).TotalSeconds))
    $msg = if ($M.exit -ne 0) { "FINISHED WITH ERRORS  -  PRESS ANY BUTTON OR TAP TO RETURN  ($left)" } else { "DONE  -  PRESS ANY BUTTON OR TAP TO RETURN  ($left)" }
    [AmDraw]::Text($g, $msg, $fnt.foot, $(if ($M.exit -ne 0) { [AmPal]::Red } else { [AmPal]::Amber }), $fr, 'Center', 'Center')
    # countdown bar
    $g.FillRectangle((Brush ([AmPal]::A([AmPal]::Amber, 120))), (Rect $pad ($SH * 0.955) (($SW - 2 * $pad) * [Math]::Max(0, ($M.closeAt - $now).TotalSeconds) / $AutoCloseSec) ([Math]::Max(2, $SH / 300))))
  }
}
function Paint-All($g) {
  [AmDraw]::Hq($g); $g.Clear([AmPal]::Bg)
  # soft vignette glow in the tool colour
  $gp = New-Object Drawing.Drawing2D.GraphicsPath; $gp.AddEllipse((Rect (-$SW * 0.2) (-$SH * 0.6) ($SW * 0.9) ($SH * 1.2)))
  $pb = New-Object Drawing.Drawing2D.PathGradientBrush $gp; $pb.CenterColor = [AmPal]::A($toolColor, 28); $pb.SurroundColors = @([AmPal]::A($toolColor, 0)); $g.FillPath($pb, $gp)
  Paint-Header $g
  $y = $SH * 0.2; $h = $SH * 0.65
  if ($M.intro) { Paint-Intro $g $y $h }
  elseif ($M.settings -and -not $M.done) { Paint-Settings $g $y $h }
  elseif ($M.choice -and -not ($M.choice.confirmed -and $M.images)) { Paint-Choice $g $y $h }
  elseif ($M.wiz) { Paint-Wizard $g $y $h }
  elseif ($M.toggle) { Paint-Toggle $g $y $h }
  elseif ($M.steps.Count) { Paint-Steps $g $y $h }
  elseif ($M.images) { Paint-Images $g $y $h }
  elseif ($M.devices) {
    $ty = $y; if ($M.tiles) { Paint-Tiles $g $M.tiles $y ($SH * 0.1); $ty += $SH * 0.125 }
    $statsH = if ($M.stats) { $SH * 0.1 } else { 0 }
    Paint-Devices $g $M.devices $ty ($y + $h - $ty - $statsH - $(if ($statsH) { $SH * 0.025 } else { 0 }))
    if ($M.stats) { Paint-Stats $g $M.stats ($y + $h - $statsH) $statsH }
  }
  elseif ($M.done) { Paint-Log $g $y $h }
  else {
    # waiting for the first result: big pulsing tool icon
    $p = 0.92 + 0.08 * [Math]::Sin(((Get-Date) - $M.started).TotalSeconds * 4); $s = $SH * 0.3 * $p
    [AmDraw]::Icon($g, $toolIcon, (Rect (($SW - $s) / 2) ($y + ($h - $s) / 2) $s $s), $toolColor, [float](((Get-Date) - $M.started).TotalMilliseconds / 8 % 360))
  }
  Paint-Footer $g
  # latest log line as a quiet ticker
  if ($M.log.Count -and -not $M.done) {
    [AmDraw]::Text($g, ($M.log[$M.log.Count - 1] -replace '^!ERR ', ''), $fnt.chip, [AmPal]::Faint, (Rect $pad ($SH * 0.962) ($SW - 2 * $pad) ($SH * 0.03)), 'Near', 'Center')
  }
}

# ---------------- window ----------------
$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'; $form.StartPosition = 'Manual'; $form.Bounds = $SB; $form.TopMost = $true
$form.BackColor = [AmPal]::Bg; $form.KeyPreview = $true; $form.ShowInTaskbar = $false; $form.Text = "ArcadeMaster Tools - $Title"
[AmWin]::DoubleBuffer($form)
$form.Add_Paint({ param($s, $e) try { Paint-All $e.Graphics } catch { $msg = "paint: $($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"; if ($M.lastPaintErr -ne $msg) { $M.lastPaintErr = $msg; $M.log.Add("!ERR $msg"); try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'am-toolscreen-errors.txt'), "$(Get-Date -f s) $Tool $msg`r`n") } catch { } } } })

function Close-Screen([string]$why = '?') {
  $timer.Stop()
  try { [IO.File]::AppendAllText((Join-Path $env:TEMP 'am-toolscreen.log'), ("{0:s} {1} closed: {2} (tool exit {3}, {4:0}s)`r`n" -f (Get-Date), $Tool, $why, $(if ($M.done) { $M.exit } else { 'running' }), ((Get-Date) - $M.started).TotalSeconds)) } catch { }
  $form.Close()
}
function Send-WizKey([string]$k) { try { [IO.File]::WriteAllText($keyFile, $k) } catch { } }
function Confirm-Choice { $c = $M.choice; if (-not $c -or $c.confirmed) { return }; $c.confirmed = $true; Send-WizKey ("CHOICE:" + $c.opts[$c.idx].id) }

$timer = New-Object Windows.Forms.Timer; $timer.Interval = 33
$timer.Add_Tick({
  $n = 0; $l = $null
  while ($n -lt 300 -and $queue.TryDequeue([ref]$l)) { On-Line $l; $n++ }
  $now = Get-Date
  if (-not $M.done) {
    if ($proc.HasExited) {
      $proc.WaitForExit(); while ($queue.TryDequeue([ref]$l)) { On-Line $l }
      $M.done = $true; $M.exit = $proc.ExitCode; $M.closeAt = $now.AddSeconds($AutoCloseSec); $M.doneAt = $now
    } elseif (($now - $M.started).TotalSeconds -gt $TimeoutSec) { try { $proc.Kill() } catch { }; $M.log.Add("!ERR stopped after $TimeoutSec s") }
  }
  # joystick buttons: track chatter all the time (the G29 reports phantom presses on some buttons)
  $raw = [AmJoyLive]::AnyButtons(); if ($raw -eq $M.rawPrev) { $M.stable = $raw }; $M.rawPrev = $raw
  $btn = [long]$M.stable; $flip = $btn -bxor $M.prevButtons
  if ($flip) { for ($b = 0; $b -lt 32; $b++) { if ($flip -band ([long]1 -shl $b)) {
    $q = $M.flips[$b]; if (-not $q) { $q = New-Object Collections.Generic.Queue[datetime]; $M.flips[$b] = $q }
    $q.Enqueue($now); while ($q.Count -and ($now - $q.Peek()).TotalSeconds -gt 2) { [void]$q.Dequeue() }
    if ($q.Count -ge 4) { $M.noisy = $M.noisy -bor ([long]1 -shl $b) } } } }
  $M.prevButtons = $btn
  # remember when each button went down
  for ($b = 0; $b -lt 32; $b++) { $bit = [long]1 -shl $b; if (($btn -band $bit) -and -not ($M.lastPoll -band $bit)) { $M.downAt[$b] = $now } }
  if ($M.settings -and -not $M.settings.done -and -not $M.done -and -not $M.yielded) {
    $c = $M.settings; $n = @($c.items).Count + 1; $dir = 0
    foreach ($d in @(Get-LiveJoys)) {
      $k = "$($d.Id)"; if (-not $c.rest.ContainsKey($k)) { $c.rest[$k] = $d.Axis[0] }
      if ([Math]::Abs($c.rest[$k]) -lt 0.5) { $dx = $d.Axis[0] - $c.rest[$k]; if ($dx -gt 0.15) { $dir = 1 } elseif ($dx -lt -0.15) { $dir = -1 } }
      if ($d.Pov -ge 0) { if ($d.Pov -ge 13500 -and $d.Pov -le 22500) { $dir = 1 } elseif ($d.Pov -le 4500 -or $d.Pov -ge 31500) { $dir = -1 } }
    }
    if ($dir -ne 0 -and ($dir -ne $c.dir -or ($now - $c.moveAt).TotalMilliseconds -gt 450)) { $c.idx = [Math]::Max(0, [Math]::Min($n - 1, $c.idx + $dir)); $c.moveAt = $now }
    $c.dir = $dir
    $released = $M.lastPoll -band (-bnot $btn) -band (-bnot $M.noisy)
    for ($b = 0; $b -lt 32 -and $released; $b++) { $bit = [long]1 -shl $b
      if (($released -band $bit) -and $M.downAt[$b] -and $M.downAt[$b] -ge $c.at -and ($now - $M.downAt[$b]).TotalSeconds -lt 1.5) { Activate-Setting; break } }
  }
  if ($M.choice -and -not $M.choice.confirmed -and -not $M.done) {
    $c = $M.choice
    # move: any centring axis 0 (wheel / stick X) or a hat, relative to where it rested when the picker opened
    $dir = 0
    foreach ($d in @(Get-LiveJoys)) {
      $k = "$($d.Id)"; if (-not $c.rest.ContainsKey($k)) { $c.rest[$k] = $d.Axis[0] }
      if ([Math]::Abs($c.rest[$k]) -lt 0.5) { $dx = $d.Axis[0] - $c.rest[$k]; if ($dx -gt 0.15) { $dir = 1 } elseif ($dx -lt -0.15) { $dir = -1 } }
      if ($d.Pov -ge 0) { if ($d.Pov -ge 4500 -and $d.Pov -le 13500) { $dir = 1 } elseif ($d.Pov -ge 22500 -and $d.Pov -le 31500) { $dir = -1 } }
    }
    if ($dir -ne 0 -and ($dir -ne $c.dir -or ($now - $c.moveAt).TotalMilliseconds -gt 450)) { $c.idx = ($c.idx + $dir + $c.opts.Count) % $c.opts.Count; $c.moveAt = $now }
    $c.dir = $dir
    $released = $M.lastPoll -band (-bnot $btn) -band (-bnot $M.noisy)
    for ($b = 0; $b -lt 32 -and $released; $b++) { $bit = [long]1 -shl $b
      if (($released -band $bit) -and $M.downAt[$b] -and $M.downAt[$b] -ge $c.at -and ($now - $M.downAt[$b]).TotalSeconds -lt 1.5) { Confirm-Choice; break } }
  }
  if ($M.done) {
    # close on a short press-and-release (< 1.5 s) that started after the tool finished. Latching inputs
    # (an H-shifter sitting in gear reports a held button) and chattering buttons never close the page.
    $released = $M.lastPoll -band (-bnot $btn) -band (-bnot $M.noisy)
    for ($b = 0; $b -lt 32 -and $released; $b++) { $bit = [long]1 -shl $b
      if (($released -band $bit) -and $M.downAt[$b] -and $M.downAt[$b] -ge $M.doneAt -and ($now - $M.downAt[$b]).TotalSeconds -lt 1.5) { Close-Screen ("joystick button {0}" -f ($b + 1)); return } }
    if ($now -ge $M.closeAt) { Close-Screen 'timeout'; return }
  }
  $M.lastPoll = $btn
  $form.Invalidate()
})
$form.Add_KeyDown({ param($s, $e)
  if ($M.done) { Close-Screen "key $($e.KeyCode)"; return }
  if ($M.settings -and -not $M.settings.done) { $st = $M.settings; $n = @($st.items).Count + 1
    switch ($e.KeyCode) { 'Down' { $st.idx = [Math]::Min($n - 1, $st.idx + 1) } 'Up' { $st.idx = [Math]::Max(0, $st.idx - 1) } 'Return' { Activate-Setting } 'Space' { Activate-Setting } 'Escape' { $st.idx = $n - 1; Activate-Setting } }; return }
  if ($M.choice -and -not $M.choice.confirmed) { $c = $M.choice; $n = $c.opts.Count
    switch ($e.KeyCode) { 'Right' { $c.idx = ($c.idx + 1) % $n } 'Left' { $c.idx = ($c.idx - 1 + $n) % $n } 'Down' { $c.idx = [Math]::Min($n - 1, $c.idx + 4) } 'Up' { $c.idx = [Math]::Max(0, $c.idx - 4) } 'Return' { Confirm-Choice } 'Escape' { Close-Screen 'cancelled (Esc)' } }; return }
  if ($M.wiz -and -not $M.wizEnd) { switch ($e.KeyCode) { 'S' { Send-WizKey 'S' } 'R' { Send-WizKey 'R' } 'B' { Send-WizKey 'B' } 'Q' { Send-WizKey 'Q' } 'Return' { Send-WizKey 'Enter' } 'Escape' { $M.cancelled = $true; Close-Screen 'cancelled (Esc)' } } }
})
$form.Add_MouseDown({ param($s, $e)
  if ($M.done) { Close-Screen 'tap/click'; return }
  if ($M.settings -and -not $M.settings.done) { foreach ($row in (Get-SettingRows ($SH * 0.2) ($SH * 0.65)).rows) { if ($row.t -ne 'h' -and $row.rect.Contains([float]$e.X, [float]$e.Y)) { $M.settings.idx = $row.i; Activate-Setting; break } }; return }
  if ($M.choice -and -not $M.choice.confirmed) { $rects = @(Get-ChoiceRects ($SH * 0.2) ($SH * 0.65)); for ($i = 0; $i -lt $rects.Count; $i++) { if ($rects[$i].Contains([float]$e.X, [float]$e.Y)) { $M.choice.idx = $i; Confirm-Choice } }; return }
  if ($M.wiz -and -not $M.wizEnd) { $rects = @(Get-ButtonRects); for ($i = 0; $i -lt $rects.Count; $i++) { if ($rects[$i].Contains([float]$e.X, [float]$e.Y)) { Send-WizKey $wizButtons[$i].key } } }
})
$form.Add_Shown({
  $form.Activate(); [void][AmWin]::SetForegroundWindow($form.Handle)
  [void]$proc.Start(); $proc.StandardInput.Close(); $proc.BeginOutputReadLine(); $proc.BeginErrorReadLine(); $timer.Start()
})
# closing early cancels the tool: kill the whole tree (Invoke-CabinetTool -> WheelMap ...) so nothing half-done is saved
$form.Add_FormClosed({ try { if (-not $proc.HasExited) { & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null } } catch { }; Remove-Item $keyFile -ErrorAction SilentlyContinue })
[void]$form.ShowDialog()
$form.Dispose()
