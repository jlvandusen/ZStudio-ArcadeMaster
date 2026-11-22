<#
.SYNOPSIS
  Full-screen "tool screen" for the in-frontend TOOLS menu. Runs Invoke-CabinetTool.ps1 hidden and shows its
  output in a borderless, topmost window sized to the cabinet display, with text scaled to the resolution
  (readable from the control panel, unlike a desktop console). Closes on any key, mouse click, touch tap or
  joystick/wheel button once the tool is done, or by itself after AutoCloseSec.
#>
param(
  [Parameter(Mandatory)][string]$Tool,
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Title,
  # display to cover: -1 = the display RetroFE's screenNum0 points at (falls back to the primary)
  [int]$Screen = -1,
  [int]$AutoCloseSec = 15,
  # kill a tool that hangs
  [int]$TimeoutSec = 900
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class AmJoy {
  [StructLayout(LayoutKind.Sequential)] public struct JOYINFOEX { public int dwSize, dwFlags, dwXpos, dwYpos, dwZpos, dwRpos, dwUpos, dwVpos, dwButtons, dwButtonNumber, dwPOV, dwReserved1, dwReserved2; }
  [DllImport("winmm.dll")] static extern int joyGetPosEx(int id, ref JOYINFOEX info);
  // bitmask of pressed buttons across the first 16 joysticks (0 if none)
  public static long Buttons() { long all = 0; for (int i = 0; i < 16; i++) { var j = new JOYINFOEX(); j.dwSize = Marshal.SizeOf(j); j.dwFlags = 0x80; if (joyGetPosEx(i, ref j) == 0) all |= (long)(uint)j.dwButtons; } return all; }
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
// reads a child's stdout/stderr on .NET threads (PowerShell event actions don't run while ShowDialog blocks)
public class AmFeed {
  public readonly System.Collections.Concurrent.ConcurrentQueue<string> Lines = new System.Collections.Concurrent.ConcurrentQueue<string>();
  public void Attach(System.Diagnostics.Process p) {
    p.OutputDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
    p.ErrorDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue("!ERR " + e.Data); };
  }
}
'@
[void][AmJoy]::SetProcessDPIAware()   # real pixels, so the window covers the display exactly at any scaling

if (-not $Title) { $Title = ($Tool -creplace '(?<=[a-z])(?=[A-Z])', ' ').ToUpper() }
if ($Screen -lt 0) {
  $m = Select-String -Path (Join-Path $RetroFE 'settings.conf') -Pattern '^\s*screenNum0\s*=\s*(\d+)' -ErrorAction SilentlyContinue | Select-Object -Last 1
  $Screen = if ($m) { [int]$m.Matches[0].Groups[1].Value } else { 0 }
}
$screens = [Windows.Forms.Screen]::AllScreens
$scr = if ($Screen -lt $screens.Count) { $screens[$Screen] } else { [Windows.Forms.Screen]::PrimaryScreen }
$B = $scr.Bounds; $H = $B.Height
function Px([double]$div) { [Math]::Max(12, [int]($H / $div)) }

# palette (ArcadeMaster neon)
$bg = [Drawing.Color]::FromArgb(8, 9, 14); $magenta = [Drawing.ColorTranslator]::FromHtml('#ff2fa0'); $cyan = [Drawing.ColorTranslator]::FromHtml('#2ec8ff')
$text = [Drawing.ColorTranslator]::FromHtml('#e6e9f0'); $dim = [Drawing.ColorTranslator]::FromHtml('#9aa3b2'); $amber = [Drawing.ColorTranslator]::FromHtml('#ffb000'); $green = [Drawing.ColorTranslator]::FromHtml('#3ddc84'); $red = [Drawing.ColorTranslator]::FromHtml('#ff5a5a')
$pad = [int]($B.Width * 0.04)

$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'; $form.StartPosition = 'Manual'; $form.Bounds = $B; $form.TopMost = $true
$form.BackColor = $bg; $form.KeyPreview = $true; $form.ShowInTaskbar = $false; $form.Text = "ArcadeMaster Tools - $Title"; $form.Cursor = [Windows.Forms.Cursors]::Default

$head = New-Object Windows.Forms.Label
$head.Text = $Title; $head.ForeColor = $cyan; $head.BackColor = $bg; $head.TextAlign = 'MiddleLeft'
$head.Font = New-Object Drawing.Font('Segoe UI Black', (Px 13), [Drawing.FontStyle]::Italic, [Drawing.GraphicsUnit]::Pixel)
$head.SetBounds($pad, [int]($H * 0.04), $B.Width - 2 * $pad, [int]($H * 0.11))

$sub = New-Object Windows.Forms.Label
$sub.Text = 'ARCADEMASTER TOOLS'; $sub.ForeColor = $magenta; $sub.BackColor = $bg
$sub.Font = New-Object Drawing.Font('Segoe UI Semibold', (Px 38), [Drawing.GraphicsUnit]::Pixel)
$sub.SetBounds($pad + 4, [int]($H * 0.02), $B.Width - 2 * $pad, [int]($H * 0.035))

$rule = New-Object Windows.Forms.Panel; $rule.BackColor = $magenta; $rule.SetBounds($pad, [int]($H * 0.155), $B.Width - 2 * $pad, [Math]::Max(2, [int]($H / 360)))

$body = New-Object Windows.Forms.RichTextBox
$body.ReadOnly = $true; $body.BorderStyle = 'None'; $body.BackColor = $bg; $body.ForeColor = $text; $body.WordWrap = $true; $body.ScrollBars = 'None'; $body.TabStop = $false; $body.DetectUrls = $false
$body.Font = New-Object Drawing.Font('Consolas', (Px 34), [Drawing.GraphicsUnit]::Pixel)
$body.SetBounds($pad, [int]($H * 0.19), $B.Width - 2 * $pad, [int]($H * 0.66))
$sectionFont = New-Object Drawing.Font('Segoe UI Semibold', (Px 24), [Drawing.GraphicsUnit]::Pixel)

$foot = New-Object Windows.Forms.Label
$foot.ForeColor = $amber; $foot.BackColor = $bg; $foot.TextAlign = 'MiddleCenter'
$foot.Font = New-Object Drawing.Font('Segoe UI Semibold', (Px 28), [Drawing.GraphicsUnit]::Pixel)
$foot.SetBounds($pad, [int]($H * 0.88), $B.Width - 2 * $pad, [int]($H * 0.08))
$foot.Text = 'WORKING...'

$form.Controls.AddRange(@($sub, $head, $rule, $body, $foot))

# --- output feed (background process -> thread-safe queue -> UI timer) ---
$feed = New-Object AmFeed; $queue = $feed.Lines
$psi = New-Object Diagnostics.ProcessStartInfo
$psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Tool {1} -RetroFE "{2}" -ManifestDir "{3}"' -f (Join-Path $PSScriptRoot 'Invoke-CabinetTool.ps1'), $Tool, $RetroFE, $ManifestDir)
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
$oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
$psi.StandardOutputEncoding = $oem; $psi.StandardErrorEncoding = $oem
$psi.EnvironmentVariables['AM_TOOL_NOPAUSE'] = '1'
$proc = New-Object Diagnostics.Process; $proc.StartInfo = $psi; $feed.Attach($proc)

$state = @{ banner = $false; done = $false; closeAt = $null; started = Get-Date; lastButtons = [AmJoy]::Buttons() }
function Add-Line([string]$line) {
  if ($line -match '^\s*=+\s*$') { $state.banner = -not $state.banner; return }   # banner rules: === / TITLE / ===
  $body.SelectionStart = $body.TextLength; $body.SelectionLength = 0
  if ($state.banner -and $line.Trim()) {
    $body.SelectionFont = $sectionFont; $body.SelectionColor = $cyan; $body.AppendText($line.Trim() + "`n")
    $body.SelectionFont = $body.Font; return
  }
  $c = $text
  if ($line -like '!ERR *') { $line = $line.Substring(5); $c = $red }
  elseif ($line -match '(?i)\b(error|failed|missing)\b') { $c = $red }
  elseif ($line -match '(?i)\b(warn|warning|not found)\b') { $c = $amber }
  elseif ($line -match '(?i)\b(saved|ok|done|repaired|written|applied)\b') { $c = $green }
  elseif ($line -match '^\s{2,}') { $c = $dim }
  $body.SelectionColor = $c; $body.AppendText($line + "`n")
}
function Close-Screen { $timer.Stop(); $form.Close() }

$timer = New-Object Windows.Forms.Timer; $timer.Interval = 80
$timer.Add_Tick({
  $n = 0; $l = $null
  while ($n -lt 200 -and $queue.TryDequeue([ref]$l)) { Add-Line $l; $n++ }
  if ($n) { $body.SelectionStart = $body.TextLength; $body.ScrollToCaret() }
  $now = Get-Date
  if (-not $state.done) {
    if ($proc.HasExited) {
      $proc.WaitForExit()   # flush async readers
      $state.done = $true; $state.closeAt = $now.AddSeconds($AutoCloseSec)
      if ($proc.ExitCode -ne 0) { $queue.Enqueue("!ERR tool exited with code $($proc.ExitCode)") }
    } elseif (($now - $state.started).TotalSeconds -gt $TimeoutSec) {
      try { $proc.Kill() } catch { }; $queue.Enqueue("!ERR stopped after $TimeoutSec s")
    } else {
      $dots = '.' * (1 + [int](($now - $state.started).TotalMilliseconds / 400) % 3); $foot.Text = "WORKING$dots"
    }
    return
  }
  $left = [Math]::Max(0, [int][Math]::Ceiling(($state.closeAt - $now).TotalSeconds))
  $foot.Text = "DONE  -  PRESS ANY BUTTON OR TAP TO RETURN  ($left)"
  $btn = [AmJoy]::Buttons()
  if (($btn -band (-bnot $state.lastButtons)) -ne 0 -or $left -le 0) { Close-Screen; return }   # newly pressed button
  $state.lastButtons = $btn
})

# keys / taps close only once the tool has finished (the wheel setup needs the controls while it runs)
$form.Add_KeyDown({ if ($state.done) { Close-Screen } })
foreach ($c in @($form, $head, $sub, $body, $foot)) { $c.Add_MouseDown({ if ($state.done) { Close-Screen } }) }
$form.Add_Shown({
  $form.Activate(); [void][AmJoy]::SetForegroundWindow($form.Handle)
  [void]$proc.Start(); $proc.StandardInput.Close(); $proc.BeginOutputReadLine(); $proc.BeginErrorReadLine(); $timer.Start()
})
$form.Add_FormClosed({ if (-not $proc.HasExited) { try { $proc.Kill() } catch { } } })

[void]$form.ShowDialog()
$form.Dispose()
