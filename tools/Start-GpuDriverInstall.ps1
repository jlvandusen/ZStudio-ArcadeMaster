<#
.SYNOPSIS
  Installs the newer graphics driver (Update-GpuDriver.ps1 -Install) with the frontend out of the way, so the player SEES
  Windows' admin prompt - started detached by Tools > Graphics Driver, which then closes its panel.

  Why (James 2026-11-27, DESKTOP-RACE2: "I cannot see the admin prompt ... trigger the install and close our panel so the
  user can see the UAC"): Windows shows the admin prompt in front only when the program asking is the one in front. The
  install runs in a hidden script, so the prompt waited as a flashing shield on the taskbar, behind the full-screen
  frontend and the tool panel, and timed out after two minutes.

  1. the frontend's windows are minimised: the desktop, the taskbar and the prompt are visible
  2. Update-GpuDriver.ps1 -Install: download (or the copy from before), the maker's signature checked, the installer
     started - Windows asks for admin here; the installer runs silently, the screen may go black for a moment
  3. the driver status is refreshed (manifest\gpu-driver.json, the health check's 'gpu' line)
  4. the frontend comes back to the front
  Everything is logged to <manifest>\gpu-driver-install.log.
.EXAMPLE
  tools\Start-GpuDriverInstall.ps1 -ManifestDir D:\ArcadeMaster\manifest
#>
param([string]$ManifestDir = 'D:\ArcadeMaster\manifest')
$ErrorActionPreference = 'Continue'
$log = Join-Path $ManifestDir 'gpu-driver-install.log'
function Say([string]$m) { $l = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m; try { Add-Content $log $l -Encoding UTF8 } catch { } }
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class GpuWin {
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte sc, uint f, UIntPtr e);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc fn, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
}
'@
function Get-FrontendWindows {
  $pids = @(Get-Process retrofe -ErrorAction SilentlyContinue | ForEach-Object { [uint32]$_.Id })
  $list = New-Object System.Collections.Generic.List[IntPtr]
  [void][GpuWin]::EnumWindows({ param($h, $l) $p = [uint32]0; [void][GpuWin]::GetWindowThreadProcessId($h, [ref]$p); if ($pids -contains $p -and [GpuWin]::IsWindowVisible($h)) { $list.Add($h) }; $true }, [IntPtr]::Zero)
  $list
}

Say 'graphics driver install: the frontend steps aside so Windows'' admin prompt can be seen'
$front = @(Get-FrontendWindows)
foreach ($h in $front) { [void][GpuWin]::ShowWindow($h, 6) }   # SW_MINIMIZE
try {
  $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Update-GpuDriver.ps1') -Install 2>&1 | Out-String
  foreach ($l in ($o -split "`r?`n" | Where-Object { $_.Trim() })) { Say "  $l" }
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Update-GpuDriver.ps1') -Cache (Join-Path $ManifestDir 'gpu-driver.json') 2>&1 | Out-Null
  $gd = Get-Content (Join-Path $ManifestDir 'gpu-driver.json') -Raw | ConvertFrom-Json
  foreach ($c in @($gd.cards)) { Say "  now: $($c.card) $($c.installed) (newest $($c.latest))" }
}
catch { Say "  failed: $($_.Exception.Message)" }
finally {
  # the frontend back in front (an Alt tap lets this process hand over the foreground)
  foreach ($h in @(Get-FrontendWindows)) { [void][GpuWin]::ShowWindow($h, 9) }   # SW_RESTORE
  $main = Get-Process retrofe -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($main) { [GpuWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [GpuWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero); [void][GpuWin]::SetForegroundWindow($main.MainWindowHandle) }
  Say 'graphics driver install: done, frontend back'
}
