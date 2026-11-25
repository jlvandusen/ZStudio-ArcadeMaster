<#
.SYNOPSIS
  "Keep this theme?" - shown over the frontend after a theme change (manifest\theme-pending.json), counting down.
    keep   : START (1), button 1 (Left Ctrl), Return or Space - or any short press of a joystick / wheel button
    revert : Escape, or no answer before the countdown ends
  Reverting puts back the previous layout, cabinetTheme.<mode> and style (skins.json), deletes the pending file, then -
  with -RetroFEPid - writes restart.request and ends the frontend, so the launcher's watchdog brings it back with the
  old theme. If the frontend itself closes during the countdown the script stops (exit 4) and the watchdog reverts
  (Start-ArcadeMaster.ps1). Every step goes to <RetroFE>\arcademaster-launcher.log.
  The window: borderless, topmost, DPI-aware (sized in real pixels of the display RetroFE's screenNum0 is on, so a 4K
  TV at 200 % gets a sharp, large prompt), takes the focus while counting and gives it back to RetroFE afterwards.
  Keys are read with GetAsyncKeyState as well, so they count even if Windows refuses to hand over the focus.
  Exit: 0 kept (or nothing waiting), 3 reverted, 4 frontend gone (the caller reverts).
.EXAMPLE
  Confirm-ThemeChange.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest -TimeoutSec 3 -NoUi
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [int]$TimeoutSec = 15,
  [int]$RetroFEPid = 0,       # the running frontend: ended (after restart.request) when the theme is put back
  [switch]$NoUi,              # no window, no keys: the countdown just runs out (tests without a person)
  [switch]$NoRestart,         # revert the settings but leave the frontend running
  [int]$Screen = -1           # display to use; -1 = the one settings.conf screenNum0 points at
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AmSettings.ps1'); . (Join-Path $PSScriptRoot 'lib\AmTheme.ps1')
function Log([string]$m) { Write-AmLauncherLog $RetroFE $m; Write-Host $m }
$pf = Get-AmPendingPath $ManifestDir
if (-not (Test-Path -LiteralPath $pf)) { Write-Host 'no theme change is waiting for a confirm'; exit 0 }
$pend = $null; try { $pend = Get-Content -LiteralPath $pf -Raw | ConvertFrom-Json } catch { }
$choice = if ($pend) { "$($pend.choice)" } else { '?' }
$nice = $choice -replace '^skin:', '' -replace '^CO-', ''
function Get-Frontend { if ($RetroFEPid) { Get-Process -Id $RetroFEPid -ErrorAction SilentlyContinue } }
Log ("theme confirm: asking to keep '{0}' ({1} s{2})" -f $choice, $TimeoutSec, $(if ($NoUi) { ', no window - test' } else { '' }))

$result = 'timeout'
if ($NoUi) {
  $end = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $end) {
    if ($RetroFEPid -and -not (Get-Frontend)) { $result = 'frontend-gone'; break }
    if (-not (Test-Path -LiteralPath $pf)) { $result = 'cleared'; break }
    Start-Sleep -Milliseconds 200
  }
} else {
  Add-Type -AssemblyName System.Windows.Forms, System.Drawing
  $src = @'
using System; using System.Runtime.InteropServices;
public static class AmConfirmWin {
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  // per-monitor v2 first (Windows 10 1703+), then the older system-wide call
  public static void DpiAware() { try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return; } catch { } try { SetProcessDPIAware(); } catch { } }
  public static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }
  // Windows only lets the foreground process hand over the focus: borrow its input queue for the switch.
  // F24 counts as "last input" without meaning anything to RetroFE (Alt would: it is RetroFE's back key).
  public static bool Focus(IntPtr h) {
    IntPtr fg = GetForegroundWindow(); if (fg == h) return true;
    uint me = GetCurrentThreadId(), other = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, IntPtr.Zero);
    bool att = other != 0 && other != me && AttachThreadInput(me, other, true);
    try { ShowWindow(h, 5); BringWindowToTop(h); SetForegroundWindow(h); } finally { if (att) AttachThreadInput(me, other, false); }
    if (GetForegroundWindow() != h) { keybd_event(0x87, 0, 0, UIntPtr.Zero); keybd_event(0x87, 0, 2, UIntPtr.Zero); SetForegroundWindow(h); }
    return GetForegroundWindow() == h;
  }
}
'@
  . (Join-Path $PSScriptRoot 'lib\AmTypeCache.ps1'); Add-AmCachedType -Source $src -ProbeType AmConfirmWin
  [AmConfirmWin]::DpiAware()
  # joystick / wheel buttons (winmm, lib\AmVisual) - optional: a missing or broken read never stops the prompt
  $joy = $false; try { . (Join-Path $PSScriptRoot 'lib\AmVisual.ps1'); [void][AmJoyLive]::AnyButtons(); $joy = $true } catch { }

  if ($Screen -lt 0) { $sn = Get-AmConf (Join-Path $RetroFE 'settings.conf') 'screenNum0'; $Screen = if ("$sn" -match '^\d+$') { [int]$sn } else { 0 } }
  $screens = [Windows.Forms.Screen]::AllScreens; $scr = if ($Screen -lt $screens.Count) { $screens[$Screen] } else { [Windows.Forms.Screen]::PrimaryScreen }
  $SB = $scr.Bounds; $W = [int]($SB.Width * 0.74); $H = [int]($SB.Height * 0.3)
  $form = New-Object Windows.Forms.Form
  $form.FormBorderStyle = 'None'; $form.StartPosition = 'Manual'; $form.TopMost = $true; $form.ShowInTaskbar = $false; $form.KeyPreview = $true
  $form.Bounds = New-Object Drawing.Rectangle ($SB.X + [int](($SB.Width - $W) / 2)), ($SB.Y + [int]($SB.Height * 0.35)), $W, $H
  $form.BackColor = [Drawing.Color]::FromArgb(10, 12, 24); $form.Text = 'ArcadeMaster - keep this theme?'
  $dbl = [Windows.Forms.Control].GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic'); $dbl.SetValue($form, $true, $null)
  function PxFont([string]$f, [double]$px, [Drawing.FontStyle]$st = 'Regular') { New-Object Drawing.Font($f, [float][Math]::Max(10, $px), $st, [Drawing.GraphicsUnit]::Pixel) }
  $fTitle = PxFont 'Segoe UI Black' ($H * 0.2) 'Italic'; $fName = PxFont 'Segoe UI Semibold' ($H * 0.095); $fLine = PxFont 'Segoe UI Semibold' ($H * 0.1); $fNum = PxFont 'Segoe UI Black' ($H * 0.42)
  $magenta = [Drawing.Color]::FromArgb(255, 47, 160); $cyan = [Drawing.Color]::FromArgb(46, 200, 255); $amber = [Drawing.Color]::FromArgb(255, 176, 0); $white = [Drawing.Color]::FromArgb(235, 238, 245)
  $dash = [string][char]0x2014
  $state = @{ start = Get-Date; result = $null; prevKeys = @{}; joyStart = [long]0; joyPrev = [long]0; joyDownAt = @{}; focused = $false }
  # keys: Return, Left Ctrl, 1 (and keypad 1), Space keep; Escape reverts. Keys already held when the prompt opens do not count.
  $keepKeys = @(0x0D, 0xA2, 0x31, 0x61, 0x20); $allKeys = $keepKeys + 0x1B
  foreach ($k in $allKeys) { $state.prevKeys[$k] = [AmConfirmWin]::Down($k) }
  if ($joy) { $state.joyStart = [AmJoyLive]::AnyButtons(); $state.joyPrev = $state.joyStart }

  $form.Add_Paint({ param($s, $e)
      $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
      $left = [Math]::Max(0, $TimeoutSec - ((Get-Date) - $state.start).TotalSeconds); $n = [int][Math]::Ceiling($left)
      $bw = [float][Math]::Max(4, $H * 0.025)
      $g.DrawRectangle((New-Object Drawing.Pen $magenta, $bw), [float]($bw / 2), [float]($bw / 2), [float]($W - $bw), [float]($H - $bw))
      $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Near'; $sf.LineAlignment = 'Center'; $sf.Trimming = 'EllipsisCharacter'; $sf.FormatFlags = 'NoWrap'
      $x = [float]($H * 0.12); $tw = [float]($W - $H * 0.95)
      $g.DrawString('KEEP THIS THEME?', $fTitle, (New-Object Drawing.SolidBrush $cyan), (New-Object Drawing.RectangleF $x, ([float]($H * 0.08)), $tw, ([float]($H * 0.3))), $sf)
      $g.DrawString($nice.ToUpper(), $fName, (New-Object Drawing.SolidBrush $white), (New-Object Drawing.RectangleF $x, ([float]($H * 0.38)), $tw, ([float]($H * 0.16))), $sf)
      $g.DrawString("Press START or button 1 to keep $dash reverting in $n", $fLine, (New-Object Drawing.SolidBrush $amber), (New-Object Drawing.RectangleF $x, ([float]($H * 0.56)), $tw, ([float]($H * 0.18))), $sf)
      $sc = New-Object Drawing.StringFormat; $sc.Alignment = 'Center'; $sc.LineAlignment = 'Center'
      $g.DrawString("$n", $fNum, (New-Object Drawing.SolidBrush $magenta), (New-Object Drawing.RectangleF ([float]($W - $H * 0.85)), ([float]($H * 0.08)), ([float]($H * 0.75)), ([float]($H * 0.7))), $sc)
      # countdown bar
      $g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(60, 255, 176, 0))), $x, [float]($H * 0.82), [float]($W - 2 * $x), [float]($H * 0.06))
      $g.FillRectangle((New-Object Drawing.SolidBrush $amber), $x, [float]($H * 0.82), [float](($W - 2 * $x) * $left / [Math]::Max(1, $TimeoutSec)), [float]($H * 0.06))
    })
  $timer = New-Object Windows.Forms.Timer; $timer.Interval = 40
  $timer.Add_Tick({
      $now = Get-Date
      if (-not $state.focused -and ($now - $state.start).TotalMilliseconds -gt 150) { $state.focused = [AmConfirmWin]::Focus($form.Handle); if (-not $state.focused -and ($now - $state.start).TotalSeconds -gt 3) { $state.focused = $true } }
      foreach ($k in $allKeys) {
        $d = [AmConfirmWin]::Down($k)
        if ($d -and -not $state.prevKeys[$k]) { $state.result = $(if ($k -eq 0x1B) { 'escape' } else { 'keep' }); $state.key = ('{0:X2}' -f $k) }
        $state.prevKeys[$k] = $d
      }
      if ($joy -and -not $state.result) {
        try {
          $b = [AmJoyLive]::AnyButtons()
          for ($i = 0; $i -lt 32; $i++) { $bit = [long]1 -shl $i
            if (($b -band $bit) -and -not ($state.joyPrev -band $bit)) { $state.joyDownAt[$i] = $now }
            # a short press-and-release of a button that was not already held: chatter and latched buttons never count
            if (-not ($b -band $bit) -and ($state.joyPrev -band $bit) -and -not ($state.joyStart -band $bit) -and $state.joyDownAt[$i]) {
              $held = ($now - $state.joyDownAt[$i]).TotalMilliseconds; if ($held -ge 40 -and $held -le 1500) { $state.result = 'keep'; $state.key = "joystick button $($i + 1)" } } }
          $state.joyPrev = $b
        } catch { }
      }
      if (-not $state.result -and $RetroFEPid -and -not (Get-Frontend)) { $state.result = 'frontend-gone' }
      if (-not $state.result -and ($now - $state.start).TotalSeconds -ge $TimeoutSec) { $state.result = 'timeout' }
      if ($state.result) { $timer.Stop(); $form.Close(); return }
      if (-not $form.TopMost) { $form.TopMost = $true }
      $form.Invalidate()
    })
  $form.Add_Shown({ [void][AmConfirmWin]::Focus($form.Handle); $timer.Start() })
  [void]$form.ShowDialog(); $form.Dispose()
  $result = if ($state.result) { $state.result } else { 'timeout' }
  if ($result -eq 'keep') { Log "theme confirm: keep pressed ($($state.key))" } elseif ($result -eq 'escape') { Log 'theme confirm: Escape pressed' }
}

# the frontend gets the focus back (it was in front before the prompt)
function Focus-Frontend { $f = Get-Frontend; if ($f -and $f.MainWindowHandle -ne [IntPtr]::Zero -and ('AmConfirmWin' -as [type])) { [void][AmConfirmWin]::Focus($f.MainWindowHandle) } }
switch ($result) {
  'keep' { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue; Log "theme confirm: '$choice' kept"; Focus-Frontend; exit 0 }
  'cleared' { Log 'theme confirm: the waiting change was cleared elsewhere (Reset theme) - nothing to do'; exit 0 }
  'frontend-gone' { Log 'theme confirm: the frontend closed during the countdown - the launcher puts the previous theme back'; exit 4 }
  default {
    $why = if ($result -eq 'escape') { 'Escape pressed' } else { "no answer in $TimeoutSec s" }
    $msg = Restore-AmThemePending $RetroFE $ManifestDir $why; Write-Host $msg
    $f = Get-Frontend
    if ($f -and -not $NoRestart) {
      [IO.File]::WriteAllText((Join-Path $ManifestDir 'restart.request'), "theme '$choice' not kept - previous theme restored")
      Log 'theme confirm: restarting the frontend with the previous theme'
      try { [void]$f.CloseMainWindow() } catch { }
      if (-not $f.WaitForExit(6000)) { try { $f.Kill() } catch { }; Log 'theme confirm: the frontend did not close by itself - ended' }
    } elseif (-not $RetroFEPid) { Log 'theme confirm: previous theme restored - it shows after the next frontend start' }
    exit 3
  }
}
