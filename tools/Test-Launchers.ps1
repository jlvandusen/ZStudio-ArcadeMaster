<#
.SYNOPSIS
  Smoke test: does every list's launcher really start a game? For each collection whose launcher is AM_DL_*
  (tools/New-DirectLaunchers.py) - or any launcher with -AnyLauncher - the first game in its folder is started exactly
  as the frontend would start it (the list's own launcher, or a per-game one from collections\<list>\launchers\<game>.conf),
  left running for -Seconds, and judged:
    PASS        the emulator is still running and the game's window is up
    NO WINDOW   still running, but no game window appeared (a console-only start, a hidden error box ...)
    EXITED      it ended by itself before the time was up (missing BIOS, a bad path, a crash) - its exit code is kept
  then closed. The game hooks (play time) are not run. Results: <manifest>\launcher-test.json.
  A game window is a visible window covering at least 40 % of the main screen, on the main screen, of a program that
  is not the frontend, the shell or ArcadeMaster, and that was not open before the start: from the started program's
  process tree, or a new one outside it (Steam and TeknoParrot games run outside the launched chain). The seconds until
  it appeared are kept (Window s).
  -Shots: a screenshot of each game, -ShotDelay seconds after its window appeared, into <manifest>\launcher-test-shots.
  -ExitRules: the game is ended the way AmPanel's exit guard ends it (tools\exit-rules.json, the cabinet's own
  <manifest>\exit-rules.json first): Esc to the game (held for a 'hold' rule), wait the rule's grace, then Alt+F4,
  close or kill as the rule says, and after 3 s anything left is ended. Exit tells how it went: closed (by the rule),
  forced (it had to be ended), killed (the rule says kill). Without -ExitRules the whole process tree is ended at once.
  Puts games on the screen one after another: run it when nobody is using the cabinet (it refuses while the frontend
  or a game is open, unless -Force).
.EXAMPLE
  tools\Test-Launchers.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest -Lists 'Super Nintendo*','Wii U'
  tools\Test-Launchers.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE -ManifestDir D:\ArcadeMaster\manifest -AnyLauncher -Shots -ExitRules -DryRun
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [Parameter(Mandatory)][string]$ManifestDir,
  [string[]]$Lists = @('*'),
  [int]$Seconds = 12,
  [switch]$AnyLauncher,
  [switch]$Shots,
  [int]$ShotDelay = 4,
  [switch]$ExitRules,
  [switch]$DryRun,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $Force -and -not $DryRun -and (Get-Process retrofe -ErrorAction SilentlyContinue)) { throw 'the frontend is open - close it first (or -Force)' }
$cols = Join-Path $RetroFE 'collections'; $lw = Join-Path $RetroFE 'launchers.windows'
function Read-Conf([string]$p) { $h = @{}; foreach ($l in Get-Content -LiteralPath $p) { if ($l -match '^\s*([A-Za-z.]+)\s*=\s*(.*)$') { $h[$Matches[1]] = $Matches[2].Trim() } }; $h }
function Stop-Tree([int]$id) { & taskkill.exe /T /F /PID $id 2>$null | Out-Null }
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing @'
using System;using System.Collections.Generic;using System.Runtime.InteropServices;using System.Text;
public class LT{
 delegate bool P(IntPtr h,IntPtr l);
 [DllImport("user32.dll")]static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")]static extern bool SetProcessDpiAwarenessContext(IntPtr c);
 // physical pixels for screens, window rectangles and captures alike: DPI-unaware, a 4K screen at 200 % reads as
 // 1920x1080 and a capture takes only its top-left quarter (pedestal, 2026-11-28)
 public static void DpiAware(){try{if(SetProcessDpiAwarenessContext(new IntPtr(-4)))return;}catch{}try{SetProcessDPIAware();}catch{}}
 [DllImport("user32.dll")]static extern bool EnumWindows(P p,IntPtr l);
 [DllImport("user32.dll")]public static extern int GetWindowThreadProcessId(IntPtr h,out int p);
 [DllImport("user32.dll")]static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]static extern bool IsIconic(IntPtr h);
 [DllImport("user32.dll")]static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")]public static extern bool PostMessage(IntPtr h,int m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")]public static extern void keybd_event(byte vk,byte sc,uint f,UIntPtr e);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetClassName(IntPtr h,StringBuilder s,int n);
 public struct RECT{public int L,T,R,B;}
 public static bool HasWindow(HashSet<int> pids){bool f=false;EnumWindows((h,l)=>{int p;GetWindowThreadProcessId(h,out p);if(pids.Contains(p)&&IsWindowVisible(h)){f=true;return false;}return true;},IntPtr.Zero);return f;}
 // every visible, not minimised window covering at least frac of the main screen and lying on it
 public static List<IntPtr> BigWindows(double frac){var o=new List<IntPtr>();var m=System.Windows.Forms.Screen.PrimaryScreen.Bounds;
  EnumWindows((h,l)=>{if(!IsWindowVisible(h)||IsIconic(h))return true;RECT r;if(!GetWindowRect(h,out r))return true;int w=r.R-r.L,ht=r.B-r.T;
   if(w<m.Width*frac||ht<m.Height*frac)return true;int cx=r.L+w/2,cy=r.T+ht/2;if(cx<m.Left||cx>m.Right||cy<m.Top||cy>m.Bottom)return true;o.Add(h);return true;},IntPtr.Zero);return o;}
 public static List<IntPtr> TreeWindows(HashSet<int> pids){var o=new List<IntPtr>();EnumWindows((h,l)=>{int p;GetWindowThreadProcessId(h,out p);if(pids.Contains(p)&&IsWindowVisible(h))o.Add(h);return true;},IntPtr.Zero);return o;}
 public static string ClassOf(IntPtr h){var s=new StringBuilder(128);GetClassName(h,s,128);return s.ToString();}
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]static extern int GetWindowText(IntPtr h,StringBuilder s,int n);
 // the titles of a program tree's visible windows ("Daytona USA"), and whether one is a Direct3D full-screen window
 public static string Titles(HashSet<int> pids,out bool d3d){var o=new List<string>();bool f=false;EnumWindows((h,l)=>{int p;GetWindowThreadProcessId(h,out p);if(pids.Contains(p)&&IsWindowVisible(h)){
  var c=ClassOf(h);if(c=="D3DProxyWindow"){f=true;return true;}var s=new StringBuilder(200);GetWindowText(h,s,200);var t=s.ToString();if(t.Length>0&&!o.Contains(t))o.Add(t);}return true;},IntPtr.Zero);d3d=f;return string.Join(" / ",o);}
 public static void Shot(string path){var m=System.Windows.Forms.Screen.PrimaryScreen.Bounds;using(var b=new System.Drawing.Bitmap(m.Width,m.Height)){using(var g=System.Drawing.Graphics.FromImage(b))g.CopyFromScreen(m.Left,m.Top,0,0,b.Size);
  using(var s=new System.Drawing.Bitmap(b,m.Width/2,m.Height/2))s.Save(path,System.Drawing.Imaging.ImageFormat.Png);}}
 public static void Focus(IntPtr h){keybd_event(0x12,0,0,UIntPtr.Zero);keybd_event(0x12,0,2,UIntPtr.Zero);SetForegroundWindow(h);}
}
'@
[LT]::DpiAware()   # before anything reads a screen or a window rectangle
function Get-Tree([int]$root) {
  $all = Get-CimInstance Win32_Process | Select-Object ProcessId, ParentProcessId
  $set = New-Object 'System.Collections.Generic.HashSet[int]'; [void]$set.Add($root); $grew = $true
  while ($grew) { $grew = $false; foreach ($p in $all) { if ($set.Contains([int]$p.ParentProcessId) -and $set.Add([int]$p.ProcessId)) { $grew = $true } } }
  ,$set
}
# programs that are never the game (the same idea as AmPanel's list)
$never = 'retrofe', 'explorer', 'AmPanel', 'ArcadeMaster', 'LEDBlinky', 'TeknoParrotUi', 'emulatorLauncher', 'cmd', 'conhost', 'powershell', 'pwsh',
  'WindowsTerminal', 'OpenConsole', 'RustDesk', 'Code', 'Claude', 'ShellExperienceHost', 'SearchHost', 'StartMenuExperienceHost', 'TextInputHost', 'dwm',
  'Taskmgr', 'SnippingTool', 'GameBar', 'msedge', 'chrome'
function Get-PName([int]$id) { try { (Get-Process -Id $id -ErrorAction Stop).ProcessName } catch { $null } }
# the game's window: a big window of the started tree, or a new big one outside it
function Find-GameWindow($tree, $before, [bool]$allowFront) {
  foreach ($h in [LT]::BigWindows(0.4)) {
    if ($before.Contains($h)) { continue }
    $wp = 0; [void][LT]::GetWindowThreadProcessId($h, [ref]$wp); $n = Get-PName $wp
    if (-not $n -or $never -contains $n) { continue }
    return @{ hwnd = $h; pid = $wp; name = $n }
  }
  # a game in exclusive full screen can keep its small windowed size as its window rectangle (the Model 2 emulator):
  # then the started program holding the front of the screen counts as its window - but only once the wait is over
  # with no big window: an emulator's own start window (Model 2's logo) holds the front before the game is up
  if (-not $allowFront) { return $null }
  $fg = [LT]::GetForegroundWindow(); $fp = 0; [void][LT]::GetWindowThreadProcessId($fg, [ref]$fp)
  if ($fg -ne [IntPtr]::Zero -and $tree.Contains($fp) -and -not $before.Contains($fg)) { $n = Get-PName $fp; if ($n -and $never -notcontains $n) { return @{ hwnd = $fg; pid = $fp; name = $n; front = $true } } }
  $null
}
# exit rules, as AmPanel's exit guard reads them: the cabinet's own file first
$rules = @()
if ($ExitRules) {
  foreach ($f in @((Join-Path $ManifestDir 'exit-rules.json'), (Join-Path $PSScriptRoot 'exit-rules.json'))) {
    if (Test-Path -LiteralPath $f) { $rules += @((Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).rules) }
  }
}
function Get-ExitRule([string]$launcher, [string]$exe, [string]$cls) {
  $sys = $rules | Where-Object { $_.emulator -and $_.emulator -ieq $launcher } | Select-Object -First 1
  $emu = $rules | Where-Object { ($_.exe -and $_.exe -ieq $exe) -or ($_.class -and $_.class -ceq $cls) } | Select-Object -First 1
  $r = @{ close = 'close'; grace = 1500; hold = 0 }
  foreach ($x in @($sys, $emu)) { if ($x) { if ($x.close) { $r.close = [string]$x.close }; if ($null -ne $x.grace) { $r.grace = [int]$x.grace }; if ($x.hold) { $r.hold = [Math]::Max($r.hold, [int]$x.hold) } } }
  if ($sys -and -not $emu) { $r.close = if ($sys.close) { [string]$sys.close } else { 'close' } }
  $r
}
function Stop-Game($p, $win, [string]$launcher) {
  if (-not $ExitRules -or -not $win) { if (-not $p.HasExited) { Stop-Tree $p.Id }; return 'tree ended' }
  $rule = Get-ExitRule $launcher $win.name ([LT]::ClassOf($win.hwnd))
  [LT]::Focus($win.hwnd); Start-Sleep -Milliseconds 150
  [LT]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds ([Math]::Max(60, $rule.hold + 200)); [LT]::keybd_event(0x1B, 0, 2, [UIntPtr]::Zero)
  Start-Sleep -Milliseconds $rule.grace
  if (-not (Get-PName $win.pid)) { return "closed itself on Esc ($($rule.close))" }
  $tree = Get-Tree $p.Id; [void]$tree.Add($win.pid)
  switch ($rule.close) {
    'altf4' { [LT]::Focus($win.hwnd); Start-Sleep -Milliseconds 50; [LT]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [LT]::keybd_event(0x73, 0, 0, [UIntPtr]::Zero); [LT]::keybd_event(0x73, 0, 2, [UIntPtr]::Zero); [LT]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero) }
    'kill' { }
    default { foreach ($h in [LT]::TreeWindows($tree)) { [void][LT]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) } }
  }
  if ($rule.close -ne 'kill') { for ($i = 0; $i -lt 30; $i++) { if (-not @($tree | Where-Object { Get-PName $_ }).Count) { return "closed ($($rule.close))" }; Start-Sleep -Milliseconds 100 } }
  $left = @($tree | Where-Object { Get-PName $_ })
  foreach ($id in $left) { Stop-Tree $id }
  if ($rule.close -eq 'kill') { 'killed (rule)' } else { "forced ($($rule.close) did not end it)" }
}
$firstMenu = 'Main'; $fc = Select-String -LiteralPath (Join-Path $RetroFE 'settings.conf') -Pattern '^\s*firstCollection\s*=\s*(.+)$' -ErrorAction SilentlyContinue | Select-Object -Last 1; if ($fc) { $firstMenu = $fc.Matches[0].Groups[1].Value.Trim() }
$shotDir = Join-Path $ManifestDir 'launcher-test-shots'
if ($Shots -and -not $DryRun) { New-Item -ItemType Directory -Force $shotDir | Out-Null }
$results = @()
foreach ($dir in Get-ChildItem $cols -Directory | Sort-Object Name) {
  if (-not ($Lists | Where-Object { $dir.Name -like $_ })) { continue }
  $sc = Join-Path $dir.FullName 'settings.conf'; if (-not (Test-Path -LiteralPath $sc)) { continue }
  $s = Read-Conf $sc
  $launcher = [string]$s['launcher']; if (-not $launcher) { continue }
  $launcher = $launcher.Replace('%ITEM_COLLECTION_NAME%', $dir.Name)
  if ($launcher -notmatch '^AM_DL_' -and -not $AnyLauncher) { continue }
  if ($launcher -match '^AM_TOOLS$') { continue }                       # the Tools menu runs maintenance, not games
  if ($dir.Name -ieq $firstMenu) { continue }                         # the main menu (Exit, Tools ...), not a system
  $lp = $s['list.path']; if (-not $lp) { $lp = Join-Path $dir.FullName 'roms' }
  if (-not [IO.Path]::IsPathRooted($lp)) { $lp = Join-Path $RetroFE $lp }
  $exts = @(($s['list.extensions'] -split ',') | ForEach-Object { '.' + $_.Trim().ToLower() } | Where-Object { $_ -ne '.' })
  $game = Get-ChildItem -LiteralPath $lp -File -ErrorAction SilentlyContinue | Where-Object { $exts -contains $_.Extension.ToLower() } | Sort-Object Name | Select-Object -First 1
  if (-not $game) { $results += [pscustomobject]@{ List = $dir.Name; Game = ''; Result = 'NO GAMES'; 'Window s' = ''; Exit = ''; Detail = $lp }; continue }
  $name = [IO.Path]::GetFileNameWithoutExtension($game.Name)
  $per = Join-Path $dir.FullName "launchers\$name.conf"
  $lname = if (Test-Path -LiteralPath $per) { (Get-Content -LiteralPath $per -TotalCount 1).Trim() } else { $launcher }
  $lconf = Join-Path $lw "$lname.conf"
  if (-not (Test-Path -LiteralPath $lconf)) { $results += [pscustomobject]@{ List = $dir.Name; Game = $game.Name; Result = 'NO LAUNCHER'; 'Window s' = ''; Exit = ''; Detail = $lconf }; continue }
  $L = Read-Conf $lconf
  $vars = @{ '%ITEM_FILEPATH%' = $game.FullName; '%ITEM_NAME%' = $name; '%ITEM_FILENAME%' = $game.Name; '%ITEM_DIRECTORY%' = $game.DirectoryName; '%ITEM_COLLECTION_NAME%' = $dir.Name }
  $a = [string]$L['arguments']; foreach ($k in $vars.Keys) { $a = $a.Replace($k, $vars[$k]) }
  $exe = $L['executable']; if (-not [IO.Path]::IsPathRooted($exe)) { $exe = Join-Path $RetroFE $exe }
  $cwd = if ($L['currentDirectory']) { $L['currentDirectory'] } else { Split-Path $exe }
  if (-not [IO.Path]::IsPathRooted($cwd)) { $cwd = Join-Path $RetroFE $cwd }
  if ($DryRun) { $results += [pscustomobject]@{ List = $dir.Name; Game = $game.Name; Result = 'DRY RUN'; 'Window s' = ''; Exit = ''; Detail = "$exe $a" }; continue }
  Write-Host ("{0,-40} {1}" -f $dir.Name, $game.Name)
  $before = New-Object 'System.Collections.Generic.HashSet[IntPtr]'; foreach ($h in [LT]::BigWindows(0.4)) { [void]$before.Add($h) }
  $t0 = Get-Date; $res = 'PASS'; $detail = ''; $winAt = ''; $exitHow = ''; $win = $null; $shot = $false; $focused = $false
  try {
    $p = Start-Process $exe -ArgumentList $a -WorkingDirectory $cwd -PassThru
    while (((Get-Date) - $t0).TotalSeconds -lt $Seconds -or ($win -and $Shots -and -not $shot)) {
      Start-Sleep -Milliseconds 700
      if ($p.HasExited -and -not $win) { break }
      if (-not $win) {
        $tr = Get-Tree $p.Id
        # the frontend's hand-off gives a new game the focus; do the same once (the Model 2 emulator waits on its logo
        # window until it is the active window)
        if (-not $focused) { $tw = @([LT]::TreeWindows($tr)); if ($tw.Count) { [LT]::Focus($tw[0]); $focused = $true } }
        $win = Find-GameWindow $tr $before $false
        if ($win) { $winAt = [Math]::Round(((Get-Date) - $t0).TotalSeconds, 1); $detail = $win.name }
      }
      elseif ($Shots -and -not $shot -and ((Get-Date) - $t0).TotalSeconds -ge $winAt + $ShotDelay) {
        $f = Join-Path $shotDir (($dir.Name -replace '[^\w\- ]', '_') + '.png'); [LT]::Shot($f); $shot = $true; $detail += " | $f"
      }
      if (((Get-Date) - $t0).TotalSeconds -gt $Seconds + $ShotDelay + 30) { break }   # never wait forever for a screenshot
    }
    if (-not $win -and -not $p.HasExited) {
      # no big window in the whole wait: the started program holding the front (exclusive full screen) counts
      $win = Find-GameWindow (Get-Tree $p.Id) $before $true
      if ($win) {
        $winAt = "$([Math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) (in front)"; $detail = "$($win.name) (in front, full screen)"
        if ($Shots) { $f = Join-Path $shotDir (($dir.Name -replace '[^\w\- ]', '_') + '.png'); [LT]::Shot($f); $detail += " | $f" }
      }
    }
    # what the game's windows are called (a loaded game usually names itself: "Daytona USA") - the best proof it is up
    if ($win -and -not $p.HasExited) {
      $tr = Get-Tree $p.Id; [void]$tr.Add($win.pid); $d3d = $false; $titles = [LT]::Titles($tr, [ref]$d3d)
      if ($titles) { $detail = "$detail | windows: $titles" }
      if ($d3d -and $Shots) { $detail = "$detail | Direct3D full screen: the screenshot may show the desktop instead" }
    }
    if ($p.HasExited -and -not $win) { $res = 'EXITED'; $detail = "exit $($p.ExitCode) after $([int]((Get-Date) - $t0).TotalSeconds) s" }
    elseif (-not $win) { $res = 'NO WINDOW'; $detail = if ([LT]::HasWindow((Get-Tree $p.Id))) { 'only small windows (no big one on the main screen)' } else { 'no window at all' } }
    $exitHow = Stop-Game $p $win $lname
    if (-not $p.HasExited) { Stop-Tree $p.Id }
  }
  catch { $res = 'EXITED'; $detail = $_.Exception.Message }
  Start-Sleep 2
  $results += [pscustomobject]@{ List = $dir.Name; Game = $game.Name; Result = $res; 'Window s' = $winAt; Exit = $exitHow; Detail = $detail }
}
$results | Format-Table -AutoSize | Out-String -Width 260 | Write-Host
$out = Join-Path $ManifestDir 'launcher-test.json'
@{ when = (Get-Date).ToString('s'); seconds = $Seconds; exitRules = [bool]$ExitRules; results = $results } | ConvertTo-Json -Depth 4 | Set-Content $out -Encoding UTF8
Write-Host ("launcher test: {0} PASS, {1} other - {2}" -f @($results | Where-Object Result -eq 'PASS').Count, @($results | Where-Object Result -ne 'PASS').Count, $out)
