<#
.SYNOPSIS
  Cabinet link helper (docs/16): similar cabinets browse in unison and start the same game.
  Talks to RetroFE on this PC (patch 0017: events on 127.0.0.1:47801, commands to 127.0.0.1:47802) and to the other
  cabinets through small state files on the NAS share (<Share>\<HOST>.json, read 4 times a second - no firewall rule,
  no admin). Started by Start-ArcadeMaster when the link is on; one copy per cabinet.

  The rule: THIS cabinet only follows while nobody is using it (no menu action for -IdleSec), and only a cabinet of
  the same type (racing with racing ...) where somebody IS choosing games. Then:
    - the other cabinet's selection -> this one goes to the same game (enters the same menu first, backs out if needed);
    - the other cabinet starts a game -> "<cabinet> is starting <game> - joining in 5 4 3 2 1" on this screen;
      any menu button here cancels; no button -> the same game starts here. A game this cabinet does not have is
      skipped with a line on the card.
  What this cabinet does because of the link is published as "remote", and nobody follows a "remote" action, so two
  cabinets can never chase each other.
.EXAMPLE
  tools\AmLink.ps1 -RetroFE D:\ArcadeMaster\frontend\DRIVE-coinops
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Share,
  [string]$HostName = $env:COMPUTERNAME,      # tests: another name
  [int]$IdleSec = 30,
  [int]$CountdownSec = 5,
  [int]$ShowLinkEverySec = 120,               # attract: every this many seconds the linked cabinets show the same game and say so (0 = off)
  [int]$ShowLinkSec = 14,                     # ... for this long
  [int]$RelayPort = 47803,                    # every frontend event is passed on to AmPanel here
  [int]$AttractEnterSec = 60,                 # idle this long on the main menu: go into the cabinet's game list (0 = off)
  [int]$EventPort = 47801,
  [int]$CommandPort = 47802,
  [int]$ParentPid = 0,                        # the launcher (Start-ArcadeMaster): the helper ends with it
  [int]$RunSeconds = 0                        # tests: stop after this long
)
$ErrorActionPreference = 'Stop'
if (-not $Share) { $Share = @('\\ds-mce\downloads\ArcadeMaster\link', 'Z:\ArcadeMaster\link') | Where-Object { Test-Path (Split-Path $_) } | Select-Object -First 1 }
if (-not $Share) { Write-Host 'cabinet link: the NAS share is not reachable - not started'; return }
New-Item -ItemType Directory -Force $Share | Out-Null
$created = $false; $mutex = New-Object Threading.Mutex($true, "ArcadeMasterAmLink-$HostName", [ref]$created)
if (-not $created) { Write-Host 'cabinet link: already running'; return }
$logFile = Join-Path $ManifestDir 'amlink.log'
function Say([string]$m) { try { if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) { Move-Item $logFile "$logFile.1" -Force }; Add-Content $logFile ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m) } catch { } }

# what kind of cabinet this is (racing / flight / standup ...): only the same kind is followed
$type = 'unknown'
try { $mf = Join-Path $ManifestDir 'cabinet-mode.json'; if (Test-Path $mf) { $type = (((Get-Content $mf -Raw | ConvertFrom-Json).effective) -split '\+')[0] } } catch { }
$top = 'Main'; try { $fc = Select-String -LiteralPath (Join-Path $RetroFE 'settings.conf') -Pattern '^\s*firstCollection\s*=\s*(\S+)' | Select-Object -Last 1; if ($fc) { $top = $fc.Matches[0].Groups[1].Value } } catch { }
# the game list attract mode belongs in: the cabinet's own mode collection, when the main menu has it
$attractCol = @{ racing = 'Racing'; simulation = 'Racing'; flight = 'Flight'; lightgun = 'Lightgun'; standup = 'Arcade'; pedestal = 'Arcade' }[$type]
# cabinets that play the same games count as one kind for the link: a 4-player pedestal and a 2-player stand-up are both
# stand-up arcades (James 2026-11-27: "for pedestal and 2p they would do the same thing since they are standup arcades");
# a racing rig and a driving-sim rig are both racing. The kind is what is published and compared from here on.
$kinds = @{ pedestal = 'arcade'; standup = 'arcade'; arcade = 'arcade'; simulation = 'racing' }; if ($kinds.ContainsKey($type)) { $type = $kinds[$type] }
$menuTxt = Join-Path $RetroFE 'collections\Main\menu.txt'; if ($attractCol -and (Test-Path $menuTxt) -and -not (@(Get-Content $menuTxt) -contains $attractCol)) { $attractCol = $null }; $attractSaid = $false; $helperStart = Get-Date   # RetroFE's idle clock does not start at 0 at boot: the helper counts from its own start too

# ---- the countdown card: on top of RetroFE, never takes the keyboard / wheel away from it
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Windows.Forms;
public class AmLinkCard : Form {
  public string Line1 = "", Line2 = "", Line3 = "";
  public AmLinkCard() { FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual; BackColor = Color.FromArgb(10, 12, 20); DoubleBuffered = true; Opacity = 0.94; }
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override CreateParams CreateParams { get { CreateParams p = base.CreateParams; p.ExStyle |= 0x08000000 | 0x00000008 | 0x00000080; return p; } }   // NOACTIVATE | TOPMOST | TOOLWINDOW
  protected override void OnPaint(PaintEventArgs e) {
    Graphics g = e.Graphics; g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias;
    using (Pen pen = new Pen(Color.FromArgb(46, 200, 255), 4)) g.DrawRectangle(pen, 2, 2, Width - 5, Height - 5);
    StringFormat c = new StringFormat(); c.Alignment = StringAlignment.Center; c.LineAlignment = StringAlignment.Center;
    using (Font f1 = new Font("Segoe UI Semibold", 22f)) using (Font f2 = new Font("Segoe UI Black", 40f, FontStyle.Italic)) using (Font f3 = new Font("Segoe UI", 18f)) {
      g.DrawString(Line1, f1, new SolidBrush(Color.FromArgb(155, 231, 255)), new RectangleF(0, 14, Width, 44), c);
      g.DrawString(Line2, f2, Brushes.White, new RectangleF(10, 60, Width - 20, 84), c);
      g.DrawString(Line3, f3, new SolidBrush(Color.FromArgb(255, 176, 0)), new RectangleF(0, 150, Width, 40), c);
    }
  }
}
'@
$card = $null
function Show-Card([string]$a, [string]$b, [string]$c, [switch]$AtTop) {
  if (-not $script:card) {
    $script:card = New-Object AmLinkCard; $s = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $script:card.Size = New-Object Drawing.Size(1100, 210); $script:card.Location = New-Object Drawing.Point(($s.X + ($s.Width - 1100) / 2), ($s.Y + $s.Height - 330))
  }
  # the countdown sits low on the screen; the "linked" note sits at the top, clear of the game's controls card
  $s = [Windows.Forms.Screen]::PrimaryScreen.Bounds; $y = if ($AtTop) { $s.Y + 30 } else { $s.Y + $s.Height - 330 }; if ($script:card.Top -ne $y) { $script:card.Top = $y }
  $script:card.Line1 = $a; $script:card.Line2 = $b; $script:card.Line3 = $c
  if (-not $script:card.Visible) { $script:card.Show() }
  $script:card.Invalidate()
}
function Hide-Card { if ($script:card -and $script:card.Visible) { $script:card.Hide() } }

# names for the card: the title RetroFE shows (meta\hyperlist\<collection>.xml), and "RACE2" for DESKTOP-RACE2
$titleCache = @{}
function Get-Title([string]$col, [string]$item) {
  if (-not $script:titleCache.ContainsKey($col)) {
    $map = @{}; $x = Join-Path $RetroFE "meta\hyperlist\$col.xml"
    if ($col -and (Test-Path -LiteralPath $x)) { try { $doc = New-Object Xml.XmlDocument; $doc.LoadXml(([IO.File]::ReadAllText($x) -replace '&(?!(amp|lt|gt|quot|apos|#\d+|#x[0-9a-fA-F]+);)', '&amp;')); foreach ($g in $doc.SelectNodes('/menu/game')) { $map[$g.GetAttribute('name').ToLower()] = [string]$g.description } } catch { } }
    $script:titleCache[$col] = $map
  }
  $t = $script:titleCache[$col][$item.ToLower()]
  if (-not $t) { $t = $item -replace '^\d+[a-z]?\s+', '' }       # Tools entries: "0a Menu Buttons" -> "Menu Buttons"
  if ($t.Length -gt 44) { $t = $t.Substring(0, 43) + '...' }
  $t
}
function Get-Cab([string]$h) { $h -replace '^(DESKTOP|ARCADE)-', '' }

# ---- RetroFE on this PC
# AmPanel (search, theme buttons) listens to the same events and only one program can have the port. The helper takes it:
# if AmPanel got there first it is asked to let go ("release" on its relay port), and every event is passed on to it.
$rx = $null
foreach ($try in 1..8) {
  try { $rx = New-Object Net.Sockets.UdpClient (New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback, $EventPort)); break }
  catch { $rx = $null; try { $u = New-Object Net.Sockets.UdpClient; $rb = [Text.Encoding]::UTF8.GetBytes('release'); [void]$u.Send($rb, $rb.Length, '127.0.0.1', $RelayPort); $u.Close() } catch { }; Start-Sleep -Milliseconds 600 }
}
if (-not $rx) { Say "cabinet link: port $EventPort is taken by another program - not started"; $mutex.ReleaseMutex(); return }
$tx = New-Object Net.Sockets.UdpClient
$lastCmd = ''; $lastCmdAt = [datetime]::MinValue
function Send-Cmd([string]$c, [double]$minGapSec = 0.6) {
  $now = Get-Date
  if ($c -eq $script:lastCmd -and ($now - $script:lastCmdAt).TotalSeconds -lt 1.6) { return }       # the menu is still moving there
  if (($now - $script:lastCmdAt).TotalSeconds -lt $minGapSec) { return }
  $b = [Text.Encoding]::UTF8.GetBytes($c); [void]$tx.Send($b, $b.Length, '127.0.0.1', $CommandPort)
  $script:lastCmd = $c; $script:lastCmdAt = $now
}
# Does this cabinet have the game at all? A list by that name, or a game by that name in any list (the search index,
# <manifest>\search-index.json, read once). Names are compared without version / update tags: the pedestal's "Donkey
# Kong Country - Tropical Freeze (USA) (v16)" is "Donkey Kong Country - Tropical Freeze (USA)" on the 2P stand-up.
# Returns the name to look for here, or '' when the game is not on this cabinet. No index: the name as it came.
$haveNames = $null; $haveLists = @{}; $listHere = @{}
function Test-HereList([string]$l) {
  if (-not $script:listHere.ContainsKey($l)) { $script:listHere[$l] = Test-Path -LiteralPath (Join-Path $RetroFE "collections\$l") }
  return $script:listHere[$l]
}
# Punctuation is ignored too: the pedestal's "Mario & Sonic at the Rio 2016 - Olympic Games (USA) (v16)" is "Mario &
# Sonic at the Rio 2016 Olympic Games (USA)" on the 2P stand-up (2026-11-28: the stand-up never went to it).
function Get-LooseName([string]$n) { (($n.ToLower() -replace '\((v\s?[\d.]+|rev\s?[\w.]+|dlc|update|unl)\)', '') -replace '&', ' and ' -replace '[^\p{L}\p{N}]+', ' ').Trim() }
function Find-HereGame([string]$item, [string]$col) {
  if ($col -and (Test-Path -LiteralPath (Join-Path $RetroFE "collections\$col"))) { return $item }
  if ($null -eq $script:haveNames) {
    $script:haveNames = @{}
    $ix = Join-Path (Split-Path (Split-Path $RetroFE)) 'manifest\search-index.json'
    if (-not (Test-Path -LiteralPath $ix)) { $ix = 'D:\ArcadeMaster\manifest\search-index.json' }
    if (Test-Path -LiteralPath $ix) {
      $t0 = [IO.File]::ReadAllText($ix)
      foreach ($m in [regex]::Matches($t0, '"n":"((?:[^"\\]|\\.)*)"')) {
        $n = [regex]::Unescape($m.Groups[1].Value); $k = Get-LooseName $n
        # every list the name is in, but only lists this cabinet really has (the index also names lists that are not
        # installed: "Atari Classics" sent the 2P stand-up to a list it does not have and it hung opening 1944, 2026-11-28)
        $cm = [regex]::Match($t0.Substring($m.Index, [Math]::Min(600, $t0.Length - $m.Index)), '"c":"((?:[^"\\]|\\.)*)"')
        $cl = if ($cm.Success) { [regex]::Unescape($cm.Groups[1].Value) } else { '' }
        $real = $cl -and (Test-HereList $cl)
        if (-not $script:haveNames.ContainsKey($k) -or ($real -and -not $script:haveLists.ContainsKey($k))) { $script:haveNames[$k] = $n }
        if ($real -and -not $script:haveLists.ContainsKey($k)) { $script:haveLists[$k] = $cl }
      }
    } else { $script:haveNames['*'] = '*' }
  }
  if ($script:haveNames.ContainsKey('*')) { return $item }
  $k = Get-LooseName $item
  if ($script:haveNames.ContainsKey($k)) { return $script:haveNames[$k] }
  return ''
}
# The other cabinet's menu may not be on this one (the pedestal's main menu has TeknoParrot; on the 2P stand-up the same
# games are in Arcade - James 2026-11-27: the stand-up said JOINING for Pokken and never got there). Then the main-menu
# entry here whose lists hold the game (its .sub files, by the loose name) is used, with the list it is in.
function Find-HereMenu([string]$item) {
  $mt = Join-Path $RetroFE 'collections\Main\menu.txt'
  if (-not (Test-Path -LiteralPath $mt)) { return $null }
  $k = Get-LooseName $item
  foreach ($m in Get-Content -LiteralPath $mt) {
    $m = $m.Trim(); if (-not $m -or $noFollow -contains $m) { continue }
    $d = Join-Path $RetroFE "collections\$m"
    foreach ($sub in @(Get-ChildItem -LiteralPath $d -Filter '*.sub' -File -ErrorAction SilentlyContinue)) {
      foreach ($l in [IO.File]::ReadAllLines($sub.FullName)) { if ((Get-LooseName $l) -eq $k) { return @{ menu = $m; col = $sub.BaseName; item = $l.Trim() } } }
    }
  }
  return $null
}
function Test-MainMenuHas([string]$menu) {
  $mt = Join-Path $RetroFE 'collections\Main\menu.txt'
  if (-not (Test-Path -LiteralPath $mt)) { return $true }
  return @(Get-Content -LiteralPath $mt | Where-Object { $_.Trim() -eq $menu }).Count -gt 0
}
# The same game in a differently named list: the 2P stand-up starts Pokken from "Arcade PC", the pedestal has it in
# "TeknoParrot"; Phantasy Star IV sits in "Megadrive - Genesis" here (James's link test, 2026-11-27 14:11: "first pick
# followed, later ones not"). Returns @{ item; list } for this cabinet from the search index, or $null.
function Find-HereList([string]$item) {
  if (-not $item) { return $null }
  [void](Find-HereGame $item '')                      # fills the index
  $k = Get-LooseName $item
  if ($script:haveLists.ContainsKey($k)) { return @{ item = $script:haveNames[$k]; list = $script:haveLists[$k] } }
  return $null
}
# Go to the same game here. The other cabinet names the game AND the list it took it from (TeknoParrot,
# AM_TP_Emulators_TeknoParrot ...); the same game can sit in a differently named list on this cabinet (RACE2 stopped
# following RACE1 after one game, 2026-11-27). So: twice with the list name, then by the game's name alone; after six
# tries the game is not here and this cabinet stays where it is until the other one moves on.
$gotoKey = ''; $gotoTries = 0; $altFor = ''; $altTries = 0
function Send-Goto([string]$item, [string]$col, [double]$gap = 0.6) {
  $k = "$item|$col"; if ($k -ne $script:gotoKey) { $script:gotoKey = $k; $script:gotoTries = 0 }
  if ($script:gotoTries -ge 6) { return }
  $before = $script:lastCmdAt
  if ($col -and $script:gotoTries -lt 2) { Send-Cmd "goto`t$item`t$col" $gap } else { Send-Cmd "goto`t$item`t" $gap; if ($script:lastCmdAt -eq $before) { Send-Cmd "goto`t$item" $gap } }
  if ($script:lastCmdAt -ne $before) { $script:gotoTries++ }
}
$me = [ordered]@{ host = $HostName; type = $type; beat = 0; alive = $false; idleMs = 9e11; menu = ''; playlist = ''; item = ''; col = ''; kind = ''; by = ''; selSeq = 0; title = ''
                  launchSeq = 0; launchMenu = ''; launchItem = ''; launchCol = ''; launchBy = ''; launchAt = '' }
$lastHello = [datetime]::MinValue; $lastUser = [datetime]::MinValue; $missItem = ''; $dirty = $true; $lastWrite = [datetime]::MinValue
$myFile = Join-Path $Share "$HostName.json"
$peers = @{}; $lastPeerRead = [datetime]::MinValue
# games that are never joined (catalog\cabinet-link.json "noJoin"): one that does not work yet may be tried alone, but must
# not pull the other cabinet into it (James 2026-11-28: SWDC crashed on RACE1 and RACE2 joined it and got stuck twice)
$noJoin = @(); try { $noJoin = @((Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'catalog\cabinet-link.json') -Raw | ConvertFrom-Json).noJoin | Where-Object { $_ }) } catch { }
$noFollow = 'Tools', 'SETTINGS', 'Controller'      # menus that are not game lists: never followed into, nothing in them is joined
$linkShown = $false   # the "cabinets are linked" card is up (attract)
$missSaid = ''; $noteUntil = $null   # the "not on this cabinet" note: said once per game, taken down after a few seconds: @{ from; menu; item; col; until; phase = 'count' | 'go' | 'note'; started }
# attractModeTime as RetroFE sees it: settings.conf, then settings1-15.conf on top (the cabinet type's defaults are in
# settings8.conf, docs/21 phase 3)
$amFiles = @(Join-Path $RetroFE 'settings.conf') + @(1..15 | ForEach-Object { Join-Path $RetroFE "settings$_.conf" } | Where-Object { Test-Path -LiteralPath $_ })
$rejoinSec = $IdleSec; try { $am = Select-String -LiteralPath $amFiles -Pattern '^\s*attractModeTime\s*=\s*(\d+)' | Select-Object -Last 1; if ($am -and [int]$am.Matches[0].Groups[1].Value -gt $rejoinSec) { $rejoinSec = [int]$am.Matches[0].Groups[1].Value } } catch { }
Say "cabinet link started: $HostName ($type), share $Share, follows again after $rejoinSec s without a press here (attract mode), countdown $CountdownSec s"
$startedAt = Get-Date; $lastParentCheck = Get-Date; $lastSelfCheck = Get-Date; $selfStamp = (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc; $restartSelf = $false; $selfArgs = @($PSBoundParameters.GetEnumerator() | ForEach-Object { "-$($_.Key)"; if ($_.Value -isnot [switch]) { '"' + [string]$_.Value + '"' } })

try {
  while ($true) {
    $now = Get-Date
    if ($RunSeconds -and ($now - $startedAt).TotalSeconds -ge $RunSeconds) { break }
    if ($ParentPid -and ($now - $lastParentCheck).TotalSeconds -ge 5) { $lastParentCheck = $now; if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break } }
    # a newer AmLink.ps1 arrived (the 15-minute pull): start it and step aside, so a fix needs no reboot
    # (a half-saved or broken file must not take the link down: RACE1, 2026-11-27, the helper restarted into a broken edit
    # and stayed off - so the new file is parsed first)
    if (-not $count -and ($now - $lastSelfCheck).TotalSeconds -ge 30) { $lastSelfCheck = $now; try { $st = (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc; if ($st -ne $selfStamp) { $pe = $null; [void][Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$null, [ref]$pe); if ($pe -and $pe.Count) { $selfStamp = $st; Say "a newer AmLink.ps1 is here but it has $($pe.Count) syntax error(s) - keeping the running helper" } else { $restartSelf = $true; break } } } catch { } }

    # 1. what RetroFE says
    while ($rx.Available -gt 0) {
      $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any, 0)
      $raw = $rx.Receive([ref]$ep); try { [void]$tx.Send($raw, $raw.Length, '127.0.0.1', $RelayPort) } catch { }   # pass it on to AmPanel
      $p = [Text.Encoding]::UTF8.GetString($raw) -split "`t"
      switch ($p[0]) {
        'hello'  { $me.menu = $p[1]; $me.idleMs = [double]$p[2]; $lastHello = $now; if ([double]$p[2] -lt 2000) { $lastUser = $now } }
        'select' { $me.by = $p[1]; $me.menu = $p[2]; $me.playlist = $p[3]; $me.item = $p[4]; $me.col = $p[5]; $me.kind = $p[6]; $me.title = (Get-Title ([string]$p[5]) ([string]$p[4])); $me.selSeq++; $dirty = $true; if ($p[1] -eq 'user') { $lastUser = $now } }
        'launch' { $me.launchBy = $p[1]; $me.launchMenu = $p[2]; $me.launchItem = $p[3]; $me.launchCol = $p[4]; $me.launchSeq++; $me.launchAt = (Get-Date).ToString('o'); $dirty = $true; if ($p[1] -eq 'user') { $lastUser = $now }; Say "this cabinet starts $($p[3]) ($($p[1]))" }
        'miss'   { $missItem = $p[1] }
      }
    }
    $alive = ($now - $lastHello).TotalSeconds -lt 3          # a menu is on screen (no hello while a game runs)
    if ($alive -ne $me.alive) { $me.alive = $alive; $dirty = $true }
    # Somebody used THIS cabinet's own controls: it stops following and only joins in again once it is back in attract
    # mode, i.e. idle for the frontend's attractModeTime (James 2026-11-27: "if someone else moves it on the other cab it
    # should break sync till it's in attract mode"). -IdleSec is the floor when attract mode is off or shorter.
    $userHere = ($now - $lastUser).TotalSeconds -lt $rejoinSec

    # 2. tell the others (on every change, and once a second so they see this cabinet is there)
    # While a game runs here (the menu has said nothing for 8 s) the NAS is left almost alone: one look and one sign of
    # life every 5 s, not four looks and a write every second. A linked Model 2 race stalls for good when one rig
    # hiccups (RACE1 + RACE2, Daytona USA, 2026-11-28), and nothing here is needed until the game ends: the first word
    # from the menu puts the normal pace back at once.
    $quiet = ($now - $lastHello).TotalSeconds -gt 8
    if ($dirty -or ($now - $lastWrite).TotalSeconds -ge $(if ($quiet) { 5 } else { 1 })) {
      $me.beat++; $me.idleMs = [Math]::Min(9e11, ($now - $lastUser).TotalMilliseconds)
      try { [IO.File]::WriteAllText($myFile, ($me | ConvertTo-Json -Compress)) } catch { }
      $dirty = $false; $lastWrite = $now
    }

    # 3. what the others say (4 times a second)
    if (($now - $lastPeerRead).TotalMilliseconds -ge $(if ($quiet) { 5000 } else { 250 })) {
      $lastPeerRead = $now
      foreach ($f in [IO.Directory]::GetFiles($Share, '*.json')) {
        if ([IO.Path]::GetFileNameWithoutExtension($f) -eq $HostName) { continue }
        try { $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { continue }       # caught half-written: next round
        if (-not $j -or -not $j.host) { continue }
        $old = $peers[$j.host]
        # never on the first look at a file. A new start is a new launch number, another game, or a new start time: a
        # restarted helper begins its numbers again and lands on one seen before (2026-11-27: the pedestal's Big Red One
        # came as launch 1 again and the 2P stand-up did nothing; the stand-up's Pokken came as launch 1 twice and the
        # pedestal did nothing). launchAt, the time of the start, tells even the same game started again apart.
        $launched = $old -and ([int]$j.launchSeq -ne [int]$old.data.launchSeq -or [string]$j.launchItem -ne [string]$old.data.launchItem -or [string]$j.launchCol -ne [string]$old.data.launchCol -or [string]$j.launchAt -ne [string]$old.data.launchAt)
        $peers[$j.host] = @{ data = $j; seen = $(if (-not $old -or [int]$j.beat -ne [int]$old.data.beat) { $now } else { $old.seen }); launched = $launched }
        # Only GAMES are joined: never an entry of the first menu (EXIT) or of Tools / settings menus - on 2026-11-26
        # RACE1's EXIT presses started "joining EXIT" on RACE2. A newer start replaces one that is still counting or
        # joining (RACE1's Batman was ignored while RACE2 was still busy with an earlier one).
        $joinable = $j.launchMenu -and ($noFollow -notcontains [string]$j.launchMenu) -and ([string]$j.launchMenu -ne $top)
        if ($launched -and $joinable -and $j.launchBy -eq 'user' -and $j.type -eq $type -and ($noJoin -contains [string]$j.launchItem)) { Say "$($j.host) started $($j.launchItem): on the no-join list - staying here"; if ($alive -and -not $userHere) { Show-Card "$(Get-Cab ([string]$j.host)) is playing" (Get-Title ([string]$j.launchCol) ([string]$j.launchItem)) 'not joined: this game is being set up' -AtTop; $noteUntil = $now.AddSeconds(4) } }
        if ($launched -and $joinable -and $j.launchBy -eq 'user' -and $j.type -eq $type -and ($noJoin -notcontains [string]$j.launchItem) -and $alive -and -not $userHere -and (-not $count -or $count.phase -eq 'note' -or $count.item -ne [string]$j.launchItem)) {
          $count = @{ from = $j.host; menu = [string]$j.launchMenu; item = [string]$j.launchItem; col = [string]$j.launchCol; title = (Get-Title ([string]$j.launchCol) ([string]$j.launchItem)); until = $now.AddSeconds($CountdownSec); phase = 'count'; started = $now }
          $missItem = ''
          # a system this cabinet does not have at all is not followed: no countdown, no search through the menus
          # (James 2026-11-27: the pedestal started Call of Duty 2 - Big Red One on the Xbox, the 2P stand-up has no
          # Xbox and moved through its menus for 15 s)
          $here = Find-HereGame $count.item $count.col
          if ($here -and $here -ne $count.item) { Say "$($count.item) is $here on this cabinet"; $count.item = $here }
          if ($here -and -not (Test-MainMenuHas $count.menu)) {
            $hm = Find-HereMenu $count.item
            if ($hm) { Say "$($count.menu) is not a menu here: joining through $($hm.menu) ($($hm.col))"; $count.menu = $hm.menu; $count.col = $hm.col; $count.item = $hm.item }
          }
          if (-not $here) {
            Say "$($j.host) started $($j.launchItem) ($($count.col)): not on this cabinet - staying here"
            Show-Card "$(Get-Cab $count.from) is playing $($count.title)" 'NOT ON THIS CABINET' ''; $count.phase = 'note'; $count.until = $now.AddSeconds(4)
          } else { Say "$($j.host) started $($j.launchItem): countdown" }
        }
      }
    }

    # 4. the countdown / joining
    if ($count) {
      if ($count.phase -eq 'count') {
        if ($userHere -or -not $alive) { Say 'countdown cancelled here'; Show-Card "$(Get-Cab $count.from) is playing $($count.title)" 'STAYING HERE' ''; $count.phase = 'note'; $count.until = $now.AddSeconds(2) }
        elseif ($now -ge $count.until) { $count.phase = 'go'; $count.until = $now.AddSeconds(15) }
        else { Show-Card "$(Get-Cab $count.from) is starting" $count.title ("JOINING IN {0}   -   any button to stay" -f [Math]::Ceiling(($count.until - $now).TotalSeconds)) }
      }
      elseif ($count.phase -eq 'go') {
        Show-Card "$(Get-Cab $count.from) is starting" $count.title 'JOINING ...'
        if ($missItem -eq $count.item) { Say "$($count.item) is not on this cabinet"; Show-Card "$(Get-Cab $count.from) is playing" $count.title 'not on this cabinet'; $count.phase = 'note'; $count.until = $now.AddSeconds(3) }
        elseif (-not $alive -or $now -ge $count.until) { Hide-Card; $count = $null }                    # the game is up (no hello), or it took too long
        elseif ($me.menu -ne $count.menu) { if ($me.menu -eq $top) { if ($me.item -ne $count.menu) { Send-Cmd "goto`t$($count.menu)" } else { Send-Cmd 'open' 1.2 } } else { Send-Cmd 'back' 1.2 } }
        elseif ($me.item -ne $count.item) { Send-Goto $count.item $count.col }
        else {
          # the same game is selected here: open it ONCE and finish (a game that quits at once must not be started again)
          $b = [Text.Encoding]::UTF8.GetBytes('open'); [void]$tx.Send($b, $b.Length, '127.0.0.1', $CommandPort); $lastCmd = 'open'; $lastCmdAt = $now
          Say "joined: opened $($count.item) here"; $count.phase = 'note'; $count.until = $now.AddSeconds(2)
        }
      }
      elseif ($now -ge $count.until) { Hide-Card; $count = $null }
    }
    # 5. browsing in unison: follow the cabinet of the same kind where somebody is choosing
    elseif ($alive -and -not $userHere) {
      $lead = $null
      foreach ($pe in $peers.Values) {
        $d = $pe.data
        if ($d.type -ne $type -or -not $d.alive -or ($now - $pe.seen).TotalSeconds -gt 5 -or [double]$d.idleMs -gt 15000) { continue }
        if (-not $lead -or [double]$d.idleMs -lt [double]$lead.idleMs) { $lead = $d }
      }
      if ($lead -and $lead.item -and ($noFollow -notcontains [string]$lead.menu)) {       # somebody in Tools is doing maintenance: stay put
        # the other cabinet is in a list this one does not have, or the game was not found in the list of that name:
        # open the list the game is in HERE and go to it there
        $alt = $null
        if (($me.menu -ne $lead.menu -and -not (Test-Path -LiteralPath (Join-Path $RetroFE "collections\$($lead.menu)"))) -or ($me.menu -eq $lead.menu -and $me.item -ne $lead.item -and $gotoTries -ge 6) -or ($altFor -eq "$($lead.item)|$($lead.host)")) {
          $alt = Find-HereList ([string]$lead.item)
          if ($alt -and ($noFollow -contains $alt.list)) { $alt = $null }
        }
        if ($alt) {
          if ($altFor -ne "$($lead.item)|$($lead.host)") { $altTries = 0 }; $altFor = "$($lead.item)|$($lead.host)"
          if ($me.item -eq $alt.item) { }                                         # there
          elseif ($me.menu -ne $alt.list -and $altTries -lt 4) { $bc = $lastCmdAt; Send-Cmd "show`t$($alt.list)" 1.5; if ($lastCmdAt -ne $bc) { $altTries++; if ($altTries -eq 1) { Say "$($lead.host) picked $($lead.item) in '$($lead.menu)': here it is in '$($alt.list)'" } } }
          elseif ($me.menu -eq $alt.list) { Send-Cmd "goto`t$($alt.item)" 0.4 }
        }
        elseif ($me.menu -ne $lead.menu) { $altFor = ''; $altTries = 0; if ($me.menu -eq $top) { if ($me.item -ne $lead.menu) { Send-Cmd "goto`t$($lead.menu)" } else { Send-Cmd 'open' 1.2 } } else { Send-Cmd 'back' 1.2 } }
        elseif ($me.item -ne $lead.item) {
          Send-Goto $lead.item $lead.col 0.25
          # every way of going there was tried: the other cabinet's game is not on this one. Say so once, briefly
          # (two real cabinets, 2026-11-27: RACE2 just stood still when RACE1 picked a game it does not have).
          if ($gotoTries -ge 6 -and $missSaid -ne "$($lead.item)|$($lead.host)") { $missSaid = "$($lead.item)|$($lead.host)"; $noteUntil = $now.AddSeconds(3.5); Show-Card "$(Get-Cab ([string]$lead.host)) picked" $(if ($lead.title) { [string]$lead.title } else { Get-Title ([string]$lead.col) ([string]$lead.item) }) 'not on this cabinet' -AtTop; Say "$($lead.host) picked $($lead.item): not on this cabinet" }
        }
      }
      # 5b. nobody anywhere (attract mode): each cabinet rolls its own games, but for $ShowLinkSec seconds every
      #     $ShowLinkEverySec they show the SAME game and a card says they are linked (James 2026-11-27: "in attract they
      #     can go their separate ways but sometimes sync so it shows it. Then advertise that they can talk to each
      #     other"). The window comes from the clock, so every cabinet is in it at the same moment; the cabinet whose
      #     name sorts first shows its game, the others go to it.
      elseif ($ShowLinkEverySec -gt 0 -and ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % $ShowLinkEverySec) -lt $ShowLinkSec -and $me.menu -ne $top -and ($noFollow -notcontains [string]$me.menu) -and
              @($peers.Values | Where-Object { $_.data.type -eq $type -and $_.data.alive -and ($now - $_.seen).TotalSeconds -le 5 -and $_.data.menu -and $_.data.menu -ne $top -and ($noFollow -notcontains [string]$_.data.menu) }).Count) {
        $mates = @($peers.Values | Where-Object { $_.data.type -eq $type -and $_.data.alive -and ($now - $_.seen).TotalSeconds -le 5 -and $_.data.menu -and $_.data.menu -ne $top -and ($noFollow -notcontains [string]$_.data.menu) } | ForEach-Object { $_.data })
        $first = @(@($HostName) + @($mates | ForEach-Object { [string]$_.host }) | Sort-Object)[0]
        # the same game in a differently named list goes too: the pedestal's "Wii U" is "Nintendo Wii U" on the 2P stand-up
        # (2026-11-28: James, "2p didn't follow pedestal" - the stand-up showed the card and stayed on its own game)
        if ($first -ne $HostName) {
          $ld = $mates | Where-Object { $_.host -eq $first } | Select-Object -First 1
          if ($ld -and $ld.item) {
            $want = [string]$ld.item; $wantList = [string]$ld.menu; $wantCol = [string]$ld.col
            if ($me.menu -ne $wantList) {
              $sa = Find-HereList $want
              if ($sa -and ($noFollow -notcontains $sa.list)) { $want = $sa.item; $wantList = $sa.list; $wantCol = '' } else { $want = '' }
            }
            if ($want -and $me.item -ne $want) {
              if ($altFor -ne "sync|$want") { $altFor = "sync|$want"; $altTries = 0 }
              if ($me.menu -eq $wantList) { Send-Goto $want $wantCol 0.5 }
              elseif ($altTries -lt 3) { $bc = $lastCmdAt; Send-Cmd "show`t$wantList" 1.5; if ($lastCmdAt -ne $bc) { $altTries++ } }
            }
          }
        }
        Show-Card 'CABINET LINK' ("{0}  +  {1}" -f (Get-Cab $HostName), ((@($mates | ForEach-Object { Get-Cab ([string]$_.host) }) | Sort-Object) -join '  +  ')) 'pick a game here and the other cabinet follows  -  start it and it joins' -AtTop
        if (-not $linkShown) { $linkShown = $true; Say "attract: showing the link with $((@($mates | ForEach-Object { $_.host })) -join ', ')" }
      }      # 6. attract on a game list, not on the main menu (James 2026-11-26: the race cab "always misses attract mode" - on
      #    the main menu attract only rolls Racing / Tools / Exit). Nobody here and nobody to follow, sitting on the main
      #    menu: go into this cabinet's own game list (racing -> Racing ...), where attract rolls the games and their videos.
      elseif ($AttractEnterSec -gt 0 -and $me.menu -eq $top -and [double]$me.idleMs -ge $AttractEnterSec * 1000 -and ($now - $helperStart).TotalSeconds -ge $AttractEnterSec -and ($now - $lastUser).TotalSeconds -ge $AttractEnterSec -and $attractCol) {
        if ($me.item -ne $attractCol) { Send-Cmd "goto`t$attractCol" 2 } else { Send-Cmd 'open' 2; if (-not $attractSaid) { Say "idle on the main menu: into $attractCol for attract mode"; $attractSaid = $true } }
      }
      else { $attractSaid = $false }
    }
    if ($linkShown -and -not $count -and ($userHere -or -not $alive -or $ShowLinkEverySec -le 0 -or ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % $ShowLinkEverySec) -ge $ShowLinkSec)) { Hide-Card; $linkShown = $false }
    if ($noteUntil -and $now -ge $noteUntil) { if (-not $count -and -not $linkShown) { Hide-Card }; $noteUntil = $null }
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 50
  }
}
finally {
  try { $me.alive = $false; $me.beat++; [IO.File]::WriteAllText($myFile, ($me | ConvertTo-Json -Compress)) } catch { }
  if ($card) { $card.Close() }; $rx.Close(); $tx.Close(); $mutex.ReleaseMutex(); Say 'cabinet link stopped'
  if ($restartSelf) { Say 'a newer AmLink.ps1 is here - restarting the helper'; Start-Process powershell -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $selfArgs) -WindowStyle Hidden }
}
