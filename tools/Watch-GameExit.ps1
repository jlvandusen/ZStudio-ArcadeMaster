<#
.SYNOPSIS
  Hold a button to leave ANY game: on a wheel the PS button, on a pad Back + Start, held for 5 seconds (James,
  2026-11-26: "I want to hold PS for 5 secs" - he was stuck in OutRunners; the old exit was L2 + R2 at the same
  moment, which nothing on screen tells you). Works the same in MAME, TeknoParrot, Model 2 / 3, Dolphin and PC games,
  because it reads the controller itself (winmm) and closes whatever the frontend started:
    - after 1 s of holding a card says "KEEP HOLDING TO EXIT ... 4 3 2 1" (on top where the game lets it show);
    - at 5 s every program RetroFE started for the game is asked to close; what is still there 3 s later is ended.
  In the menus (no game running) it does nothing. Started by Start-ArcadeMaster; ends with it.
.EXAMPLE
  tools\Watch-GameExit.ps1 -ParentPid 1234
#>
param(
  [int]$ParentPid = 0,                 # the launcher: the watcher ends with it
  [double]$HoldSec = 5,
  [string]$RootProcess = 'retrofe',    # what it started is "the game"
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [int]$RootPid = 0,                   # tests: this process instead of RootProcess
  [switch]$SimulateHold,               # tests: behave as if the button is held from the start
  [int]$RunSeconds = 0
)
$ErrorActionPreference = 'Stop'
$created = $false; $mutex = New-Object Threading.Mutex($true, "ArcadeMasterGameExit$(if ($RootPid) { "-$RootPid" })", [ref]$created)
if (-not $created) { Write-Host 'game exit watcher: already running'; return }
$logFile = Join-Path $ManifestDir 'game-exit.log'
function Say([string]$m) { try { Add-Content $logFile ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) } catch { } }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Runtime.InteropServices; using System.Windows.Forms;
public static class AmJoy {
  [StructLayout(LayoutKind.Sequential)] public struct JOYINFOEX { public int dwSize, dwFlags, dwXpos, dwYpos, dwZpos, dwRpos, dwUpos, dwVpos, dwButtons, dwButtonNumber, dwPOV, dwReserved1, dwReserved2; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct JOYCAPS { public ushort wMid, wPid; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname; public int wXmin, wXmax, wYmin, wYmax, wZmin, wZmax, wNumButtons, wPeriodMin, wPeriodMax, wRmin, wRmax, wUmin, wUmax, wVmin, wVmax, wCaps, wMaxAxes, wNumAxes, wMaxButtons; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szRegKey; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szOEMVxD; }
  [DllImport("winmm.dll")] static extern int joyGetPosEx(int id, ref JOYINFOEX info);
  [DllImport("winmm.dll", CharSet = CharSet.Unicode)] static extern int joyGetDevCapsW(IntPtr id, ref JOYCAPS caps, int size);
  // -1 = not there; else the pressed-button bits
  public static long Buttons(int id) { JOYINFOEX j = new JOYINFOEX(); j.dwSize = Marshal.SizeOf(typeof(JOYINFOEX)); j.dwFlags = 0x80; return joyGetPosEx(id, ref j) == 0 ? (long)(uint)j.dwButtons : -1; }
  public static string Caps(int id) { JOYCAPS c = new JOYCAPS(); return joyGetDevCapsW((IntPtr)id, ref c, Marshal.SizeOf(typeof(JOYCAPS))) == 0 ? (c.wMid.ToString("X4") + ":" + c.wPid.ToString("X4") + ":" + c.wNumButtons) : null; }
}
public class AmExitCard : Form {
  public string Line1 = "", Line2 = "";
  public AmExitCard() { FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual; BackColor = Color.FromArgb(10, 12, 20); DoubleBuffered = true; Opacity = 0.94; }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams { get { CreateParams p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x00000008 | 0x00000080; return p; } }
  protected override void OnPaint(PaintEventArgs e) {
    Graphics g = e.Graphics; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
    using (Pen pen = new Pen(Color.FromArgb(255, 176, 0), 4)) g.DrawRectangle(pen, 2, 2, Width - 5, Height - 5);
    StringFormat c = new StringFormat(); c.Alignment = StringAlignment.Center; c.LineAlignment = StringAlignment.Center;
    using (Font f1 = new Font("Segoe UI Black", 34f, FontStyle.Italic)) using (Font f2 = new Font("Segoe UI", 20f)) {
      g.DrawString(Line1, f1, Brushes.White, new RectangleF(0, 14, Width, 70), c);
      g.DrawString(Line2, f2, new SolidBrush(Color.FromArgb(255, 176, 0)), new RectangleF(0, 88, Width, 40), c);
    }
  }
}
'@
$card = $null
# AmPanel.json "ExitCard": "off" (next to the manifest folder) - hold-to-exit still works, but no card on top of the game
# (James 2026-11-26 on DESKTOP-RACE2: "kill the loading and exit screen" - Batman went windowed)
$noCard = $false
try { $apj = Join-Path (Split-Path $ManifestDir) 'AmPanel.json'; if (Test-Path $apj) { $noCard = "$((Get-Content $apj -Raw | ConvertFrom-Json).ExitCard)" -ieq 'off' } } catch { }
function Show-Card([string]$a, [string]$b) {
  if ($script:noCard) { return }
  if (-not $script:card) { $script:card = New-Object AmExitCard; $s = [Windows.Forms.Screen]::PrimaryScreen.Bounds; $script:card.Size = New-Object Drawing.Size(900, 150); $script:card.Location = New-Object Drawing.Point(($s.X + ($s.Width - 900) / 2), ($s.Y + 60)) }
  $script:card.Line1 = $a; $script:card.Line2 = $b; if (-not $script:card.Visible) { $script:card.Show() }; $script:card.Invalidate()
}
function Hide-Card { if ($script:card -and $script:card.Visible) { $script:card.Hide() } }

# which buttons, held together, mean "exit" on each controller (0-based numbers, as RetroFE's joyButtonN):
#   a Logitech wheel with a PS button (G29: 25 buttons) -> PS = 24; any other pad -> Back + Start = 6 + 7
function Get-ExitMask([string]$caps) {
  if (-not $caps) { return 0 }
  $mid, $pidHex, $n = $caps -split ':'
  if ($mid -eq '046D' -and [int]$n -ge 25) { return [long]1 -shl 24 }
  if ([int]$n -ge 8 -and [int]$n -le 20) { return ([long]1 -shl 6) -bor ([long]1 -shl 7) }
  return 0
}
$capsCache = @{}; $capsAt = [datetime]::MinValue
function Test-Held {
  if ($SimulateHold) { return $true }
  $now = Get-Date
  if (($now - $script:capsAt).TotalSeconds -ge 10) { $script:capsAt = $now; $script:capsCache = @{}; foreach ($i in 0..15) { $m = Get-ExitMask ([AmJoy]::Caps($i)); if ($m) { $script:capsCache[$i] = $m } } }   # plug / unplug: looked at again every 10 s
  foreach ($i in @($script:capsCache.Keys)) { $b = [AmJoy]::Buttons($i); if ($b -ge 0 -and (($b -band $script:capsCache[$i]) -eq $script:capsCache[$i])) { return $true } }
  return $false
}
# everything the frontend started for the game (its descendants), deepest first
function Get-GameProcesses {
  $root = if ($RootPid) { @($RootPid) } else { @(Get-Process -Name $RootProcess -ErrorAction SilentlyContinue | ForEach-Object Id) }
  if (-not $root) { return @() }
  $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name -ErrorAction SilentlyContinue)
  $out = New-Object System.Collections.Generic.List[object]; $queue = New-Object System.Collections.Generic.Queue[int]; foreach ($r in $root) { $queue.Enqueue([int]$r) }
  $seen = @{}; foreach ($r in $root) { $seen[[int]$r] = 1 }
  while ($queue.Count) { $p = $queue.Dequeue(); foreach ($c in $all) { if ([int]$c.ParentProcessId -eq $p -and -not $seen.ContainsKey([int]$c.ProcessId)) { $seen[[int]$c.ProcessId] = 1; $out.Add($c); $queue.Enqueue([int]$c.ProcessId) } } }
  $list = @($out | Where-Object { $_.Name -notmatch '^(conhost|LEDBlinky|WerFault|AmPanel)\.exe$' })
  [array]::Reverse($list); $list
}

Say "game exit watcher started (hold $HoldSec s)"
$heldSince = $null; $startedAt = Get-Date; $lastParent = Get-Date; $cooldownUntil = [datetime]::MinValue
try {
  while ($true) {
    $now = Get-Date
    if ($RunSeconds -and ($now - $startedAt).TotalSeconds -ge $RunSeconds) { break }
    if ($ParentPid -and ($now - $lastParent).TotalSeconds -ge 5) { $lastParent = $now; if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break } }
    if ($now -lt $cooldownUntil) { Hide-Card; [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 150; continue }
    if (Test-Held) {
      if (-not $heldSince) { $heldSince = $now }
      $held = ($now - $heldSince).TotalSeconds
      if ($held -ge 1 -and $held -lt $HoldSec) {
        $game = @(Get-GameProcesses)
        if ($game.Count) { Show-Card 'KEEP HOLDING TO EXIT' ("back to the menu in {0}" -f [Math]::Ceiling($HoldSec - $held)) } else { $heldSince = $now }   # in the menu: nothing to leave
      }
      elseif ($held -ge $HoldSec) {
        $game = @(Get-GameProcesses)
        if ($game.Count) {
          Say ("exit held: closing " + (($game | ForEach-Object Name | Select-Object -Unique) -join ', '))
          Show-Card 'EXITING' 'back to the menu'
          foreach ($g in $game) { try { $p = Get-Process -Id $g.ProcessId -ErrorAction Stop; if ($p.MainWindowHandle -ne [IntPtr]::Zero) { [void]$p.CloseMainWindow() } } catch { } }
          $deadline = (Get-Date).AddSeconds(3)
          while ((Get-Date) -lt $deadline -and @(Get-GameProcesses).Count) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
          foreach ($g in @(Get-GameProcesses)) { try { Stop-Process -Id $g.ProcessId -Force -ErrorAction Stop; Say "ended $($g.Name)" } catch { } }
        }
        $heldSince = $null; $cooldownUntil = (Get-Date).AddSeconds(3)
      }
    }
    else { $heldSince = $null; Hide-Card }
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
  }
}
finally { if ($card) { $card.Close() }; $mutex.ReleaseMutex(); Say 'game exit watcher stopped' }
