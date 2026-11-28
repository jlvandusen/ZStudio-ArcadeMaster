<#
.SYNOPSIS
  Installs the system helpers (Install-SystemTasks.ps1: GPU reset, USB heal ...) with the frontend out of the way, so
  the player SEES Windows' admin prompt. Started detached by Tools > System Helpers, which then closes its panel - the
  same way as Start-GpuDriverInstall.ps1 (Windows shows the prompt in front only for the program in front; behind the
  full-screen frontend it waits unseen as a flashing shield and times out).
  1. the frontend's windows are minimised  2. Install-SystemTasks.ps1 (one admin prompt)  3. USB heal runs once
  4. the Tools art is refreshed  5. the frontend comes back. Log: <manifest>\system-tasks-install.log.
#>
param([string]$ManifestDir = 'R:\ArcadeMaster\manifest', [string]$RetroFE)
$ErrorActionPreference = 'Continue'
$log = Join-Path $ManifestDir 'system-tasks-install.log'
function Say([string]$m) { $l = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m; try { Add-Content $log $l -Encoding UTF8 } catch { } }
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class SysWin {
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
  [void][SysWin]::EnumWindows({ param($h, $l) $p = [uint32]0; [void][SysWin]::GetWindowThreadProcessId($h, [ref]$p); if ($pids -contains $p -and [SysWin]::IsWindowVisible($h)) { $list.Add($h) }; $true }, [IntPtr]::Zero)
  $list
}
Say 'system helpers install: the frontend steps aside so Windows'' admin prompt can be seen'
foreach ($h in @(Get-FrontendWindows)) { [void][SysWin]::ShowWindow($h, 6) }   # SW_MINIMIZE
try {
  $o = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Install-SystemTasks.ps1') -ManifestDir $ManifestDir 2>&1 | Out-String
  foreach ($l in ($o -split "`r?`n" | Where-Object { $_.Trim() })) { Say "  $l" }
  if (Get-ScheduledTask -TaskName 'ArcadeMaster USB Heal' -ErrorAction SilentlyContinue) { & schtasks.exe /run /tn 'ArcadeMaster USB Heal' | Out-Null; Say '  USB heal started once' }
  if ($RetroFE) { & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'New-ToolsArt.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir 2>&1 | Out-Null }
}
catch { Say "  failed: $($_.Exception.Message)" }
finally {
  foreach ($h in @(Get-FrontendWindows)) { [void][SysWin]::ShowWindow($h, 9) }   # SW_RESTORE
  $main = Get-Process retrofe -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
  if ($main) { [SysWin]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [SysWin]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero); [void][SysWin]::SetForegroundWindow($main.MainWindowHandle) }
  Say 'system helpers install: done, frontend back'
}
