<#
.SYNOPSIS
  Hides the mouse pointer while a game runs, and puts it back after (James, 2026-11-26: "Also need to hide mouse while in
  these games"). -Hide swaps every Windows system cursor for a blank one (SetSystemCursor) - that hides the pointer in
  any game, also ones that draw Windows' own cursor; -Show reloads the user's cursor scheme (SystemParametersInfo
  SPI_SETCURSORS), so nothing is lost. The game start / end hooks (Record-GamePlay) call it; the boot calls -Show too, so
  a crash during a game can never leave the cursor invisible. Moves the pointer to the screen's bottom-right corner on
  -Hide as well (a game that draws its own pointer then has it out of the way).
.EXAMPLE
  tools\Set-GameCursor.ps1 -Hide
  tools\Set-GameCursor.ps1 -Show
#>
param([switch]$Hide, [switch]$Show)
if (-not ($Hide -or $Show)) { throw 'use -Hide or -Show' }
Add-Type -Namespace AmCur -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr CreateCursor(IntPtr hInst, int x, int y, int w, int h, byte[] andMask, byte[] xorMask);
[DllImport("user32.dll")] public static extern bool SetSystemCursor(IntPtr hcur, uint id);
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint action, uint param, IntPtr pv, uint flags);
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
'@
if ($Show) {
  [void][AmCur.Native]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0)   # SPI_SETCURSORS: reload the user's cursors
  Write-Host 'cursor: shown (system cursors reloaded)'
  return
}
# a 32x32 cursor: AND mask all 1 (keep the screen), XOR mask all 0 (draw nothing) = invisible
$and = [byte[]](,0xFF * 128); $xor = [byte[]](,0x00 * 128)
# the standard cursor ids (OCR_*): arrow, ibeam, wait, cross, up, size*, no, hand, appstarting, help
$ids = 32512, 32513, 32514, 32515, 32516, 32642, 32643, 32644, 32645, 32646, 32648, 32649, 32650, 32651
foreach ($id in $ids) { $c = [AmCur.Native]::CreateCursor([IntPtr]::Zero, 0, 0, 32, 32, $and, $xor); [void][AmCur.Native]::SetSystemCursor($c, $id) }
[void][AmCur.Native]::SetCursorPos([AmCur.Native]::GetSystemMetrics(0) - 1, [AmCur.Native]::GetSystemMetrics(1) - 1)
Write-Host 'cursor: hidden'
