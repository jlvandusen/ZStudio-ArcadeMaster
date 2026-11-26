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
function Show-Card([string]$a, [string]$b, [string]$c) {
  if (-not $script:card) {
    $script:card = New-Object AmLinkCard; $s = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $script:card.Size = New-Object Drawing.Size(1100, 210); $script:card.Location = New-Object Drawing.Point(($s.X + ($s.Width - 1100) / 2), ($s.Y + $s.Height - 330))
  }
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
$rx = New-Object Net.Sockets.UdpClient (New-Object Net.IPEndPoint ([Net.IPAddress]::Loopback, $EventPort))
$tx = New-Object Net.Sockets.UdpClient
$lastCmd = ''; $lastCmdAt = [datetime]::MinValue
function Send-Cmd([string]$c, [double]$minGapSec = 0.6) {
  $now = Get-Date
  if ($c -eq $script:lastCmd -and ($now - $script:lastCmdAt).TotalSeconds -lt 1.6) { return }       # the menu is still moving there
  if (($now - $script:lastCmdAt).TotalSeconds -lt $minGapSec) { return }
  $b = [Text.Encoding]::UTF8.GetBytes($c); [void]$tx.Send($b, $b.Length, '127.0.0.1', $CommandPort)
  $script:lastCmd = $c; $script:lastCmdAt = $now
}
$me = [ordered]@{ host = $HostName; type = $type; beat = 0; alive = $false; idleMs = 9e11; menu = ''; playlist = ''; item = ''; col = ''; kind = ''; by = ''; selSeq = 0
                  launchSeq = 0; launchMenu = ''; launchItem = ''; launchCol = ''; launchBy = '' }
$lastHello = [datetime]::MinValue; $lastUser = [datetime]::MinValue; $missItem = ''; $dirty = $true; $lastWrite = [datetime]::MinValue
$myFile = Join-Path $Share "$HostName.json"
$peers = @{}; $lastPeerRead = [datetime]::MinValue
$noFollow = 'Tools', 'SETTINGS', 'Controller'      # menus that are not game lists: never followed into, nothing in them is joined
$count = $null      # the countdown / join in progress: @{ from; menu; item; col; until; phase = 'count' | 'go' | 'note'; started }
Say "cabinet link started: $HostName ($type), share $Share, idle $IdleSec s, countdown $CountdownSec s"
$startedAt = Get-Date; $lastParentCheck = Get-Date; $lastSelfCheck = Get-Date; $selfStamp = (Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc; $restartSelf = $false; $selfArgs = @($PSBoundParameters.GetEnumerator() | ForEach-Object { "-$($_.Key)"; if ($_.Value -isnot [switch]) { '"' + [string]$_.Value + '"' } })

try {
  while ($true) {
    $now = Get-Date
    if ($RunSeconds -and ($now - $startedAt).TotalSeconds -ge $RunSeconds) { break }
    if ($ParentPid -and ($now - $lastParentCheck).TotalSeconds -ge 5) { $lastParentCheck = $now; if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break } }
    # a newer AmLink.ps1 arrived (the 15-minute pull): start it and step aside, so a fix needs no reboot
    if (-not $count -and ($now - $lastSelfCheck).TotalSeconds -ge 30) { $lastSelfCheck = $now; try { if ((Get-Item -LiteralPath $PSCommandPath).LastWriteTimeUtc -ne $selfStamp) { $restartSelf = $true; break } } catch { } }

    # 1. what RetroFE says
    while ($rx.Available -gt 0) {
      $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any, 0)
      $p = [Text.Encoding]::UTF8.GetString($rx.Receive([ref]$ep)) -split "`t"
      switch ($p[0]) {
        'hello'  { $me.menu = $p[1]; $me.idleMs = [double]$p[2]; $lastHello = $now; if ([double]$p[2] -lt 2000) { $lastUser = $now } }
        'select' { $me.by = $p[1]; $me.menu = $p[2]; $me.playlist = $p[3]; $me.item = $p[4]; $me.col = $p[5]; $me.kind = $p[6]; $me.selSeq++; $dirty = $true; if ($p[1] -eq 'user') { $lastUser = $now } }
        'launch' { $me.launchBy = $p[1]; $me.launchMenu = $p[2]; $me.launchItem = $p[3]; $me.launchCol = $p[4]; $me.launchSeq++; $dirty = $true; if ($p[1] -eq 'user') { $lastUser = $now }; Say "this cabinet starts $($p[3]) ($($p[1]))" }
        'miss'   { $missItem = $p[1] }
      }
    }
    $alive = ($now - $lastHello).TotalSeconds -lt 3          # a menu is on screen (no hello while a game runs)
    if ($alive -ne $me.alive) { $me.alive = $alive; $dirty = $true }
    $userHere = ($now - $lastUser).TotalSeconds -lt $IdleSec

    # 2. tell the others (on every change, and once a second so they see this cabinet is there)
    if ($dirty -or ($now - $lastWrite).TotalSeconds -ge 1) {
      $me.beat++; $me.idleMs = [Math]::Min(9e11, ($now - $lastUser).TotalMilliseconds)
      try { [IO.File]::WriteAllText($myFile, ($me | ConvertTo-Json -Compress)) } catch { }
      $dirty = $false; $lastWrite = $now
    }

    # 3. what the others say (4 times a second)
    if (($now - $lastPeerRead).TotalMilliseconds -ge 250) {
      $lastPeerRead = $now
      foreach ($f in [IO.Directory]::GetFiles($Share, '*.json')) {
        if ([IO.Path]::GetFileNameWithoutExtension($f) -eq $HostName) { continue }
        try { $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { continue }       # caught half-written: next round
        if (-not $j -or -not $j.host) { continue }
        $old = $peers[$j.host]
        $launched = $old -and ([int]$j.launchSeq -ne [int]$old.data.launchSeq)             # never on the first look at a file
        $peers[$j.host] = @{ data = $j; seen = $(if (-not $old -or [int]$j.beat -ne [int]$old.data.beat) { $now } else { $old.seen }); launched = $launched }
        # Only GAMES are joined: never an entry of the first menu (EXIT) or of Tools / settings menus - on 2026-11-26
        # RACE1's EXIT presses started "joining EXIT" on RACE2. A newer start replaces one that is still counting or
        # joining (RACE1's Batman was ignored while RACE2 was still busy with an earlier one).
        $joinable = $j.launchMenu -and ($noFollow -notcontains [string]$j.launchMenu) -and ([string]$j.launchMenu -ne $top)
        if ($launched -and $joinable -and $j.launchBy -eq 'user' -and $j.type -eq $type -and $alive -and -not $userHere -and (-not $count -or $count.phase -eq 'note' -or $count.item -ne [string]$j.launchItem)) {
          $count = @{ from = $j.host; menu = [string]$j.launchMenu; item = [string]$j.launchItem; col = [string]$j.launchCol; title = (Get-Title ([string]$j.launchCol) ([string]$j.launchItem)); until = $now.AddSeconds($CountdownSec); phase = 'count'; started = $now }
          $missItem = ''; Say "$($j.host) started $($j.launchItem): countdown"
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
        elseif ($me.item -ne $count.item -or ($count.col -and $me.col -ne $count.col)) { Send-Cmd "goto`t$($count.item)`t$($count.col)" }
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
        if ($me.menu -ne $lead.menu) { if ($me.menu -eq $top) { if ($me.item -ne $lead.menu) { Send-Cmd "goto`t$($lead.menu)" } else { Send-Cmd 'open' 1.2 } } else { Send-Cmd 'back' 1.2 } }
        elseif ($me.item -ne $lead.item -or ($lead.col -and $me.col -ne $lead.col)) { Send-Cmd "goto`t$($lead.item)`t$($lead.col)" 0.25 }
      }
    }
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 50
  }
}
finally {
  try { $me.alive = $false; $me.beat++; [IO.File]::WriteAllText($myFile, ($me | ConvertTo-Json -Compress)) } catch { }
  if ($card) { $card.Close() }; $rx.Close(); $tx.Close(); $mutex.ReleaseMutex(); Say 'cabinet link stopped'
  if ($restartSelf) { Say 'a newer AmLink.ps1 is here - restarting the helper'; Start-Process powershell -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") + $selfArgs) -WindowStyle Hidden }
}
