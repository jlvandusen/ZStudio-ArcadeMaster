<#
.SYNOPSIS
  Every cabinet / frontend setting for Tools > Cabinet Settings (the Windows switches stay in Set-CabinetSystem.ps1).
  Grouped, each with its current value. On/off settings flip; the others step through presets on every press
  (attract mode 0 / 20 / 60 / 120 s ...). Every write changes one key and backs the file up once next to itself
  (<file>.am-bak) - see lib\AmSettings.ps1.

    CABINET          cabinetType (cycles the types), the mode in use (cabinet-mode.json, shown only),
                     cabinetFollowHardware, cabinetShowAllModes
    SCREEN AND SOUND second screen (numScreens via Set-RetroFEScreens), preview videos (videoEnable),
                     video volume, menu sounds
    MENUS            game story panel, special-control reminders (manifest\ui.json -> Set-LayoutUi.ps1),
                     attract mode start / next game (attractModeTime / attractModeNextTime),
                     force feedback (ffb), performance log (perfLog)
    LIGHTS AND DECK  button lights (LEDBlinkyDirectory: off = the line is commented out, the path is kept),
                     lights off when the arcade closes (LEDBlinkyCloseOnExit), Stream Deck on/off (ui.json),
                     Stream Deck idle dim (tools\streamdeck\deck.json idleDimMinutes)
    RESET            restore defaults (every setting that has one; hardware-dependent ones are left alone)
.EXAMPLE
  Set-CabinetSettings.ps1 -List                                  # JSON: id, group, label, detail, kind, value, on
  Set-CabinetSettings.ps1 -Set attractModeTime=toggle            # next preset
  Set-CabinetSettings.ps1 -Set story=off,attractModeTime=60
  Set-CabinetSettings.ps1 -Defaults
#>
param(
  [switch]$List,
  [string[]]$Set,
  [switch]$Defaults,
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [switch]$NoProcess          # never start or stop the Stream Deck helper (scripts / tests)
)
$ErrorActionPreference = 'Stop'
$t = $PSScriptRoot
. (Join-Path $t 'lib\AmSettings.ps1'); . (Join-Path $t 'lib\CabinetTypes.ps1')
$sc = Join-Path $RetroFE 'settings.conf'
$deckCfg = Join-Path $t 'streamdeck\deck.json'; $deckPy = Join-Path $t 'streamdeck\amdeck.py'
$cab = $null; $cf = Join-Path $ManifestDir 'cabinet.json'; if (Test-Path $cf) { $cab = Get-Content $cf -Raw | ConvertFrom-Json }
function Conf([string]$k) { Get-AmConf $sc $k }
function SetConf([string]$k, [string]$v) { [void](Set-AmConf $sc $k $v) }
function IsYes($v) { "$v" -match '^(yes|true|1|on)$' }
function SetUi([string]$k, $v) {
  $u = Read-AmUi $ManifestDir; $u[$k] = $v; [void](Write-AmUi $ManifestDir $u)
  $o = & (Join-Path $t 'Set-LayoutUi.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir 6>&1 3>&1 | Out-String
  if ($o -match 'WARNING|left as it is|not valid') { return ' - ' + (($o -split "`r?`n" | Where-Object { $_ -match 'left as it is|not valid|cannot' } | Select-Object -First 1).Trim()) }
  return ''
}
function Get-DeckProcs { @(Get-CimInstance Win32_Process -Filter "Name like 'python%'" -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)" -match 'amdeck\.py' }) }
$ledDefault = Join-Path $RetroFE 'LEDBlinky'
function Seconds($v) { if ([int]$v -eq 0) { 'OFF' } else { "$v s" } }

# kind: switch (get -> bool, set gets a bool) | cycle (presets; get -> value) | info (shown only) | action
# default: what Restore defaults puts back ($null = left alone: it depends on the hardware)
$S = [ordered]@{}
$S.cabinetType = @{ group = 'CABINET'; label = 'CABINET TYPE'; detail = 'What this cabinet is - boot intro, menus and theme per mode follow it'; kind = 'cycle'
  presets = @(Get-AmCabinetChoices); default = 'auto'
  get = { $v = Conf 'cabinetType'; if ($v) { $v.ToLower() } else { 'auto' } }
  show = { param($v) $r = Resolve-AmCabinetType $v $cab '' ''; $short = (@($r.parts) | ForEach-Object { $script:AmCabinetTypes[$_].short }) -join ' + '; if ($v -eq 'auto') { "AUTO: $short" } else { $short } }
  set = { param($v) SetConf 'cabinetType' $v; 'boot intro, menus and theme follow at the next start' } }
$S.cabinetMode = @{ group = 'CABINET'; label = 'MODE IN USE'; kind = 'info'
  detail = $(try { $cm = Get-Content (Join-Path $ManifestDir 'cabinet-mode.json') -Raw | ConvertFrom-Json; "$($cm.reason)" } catch { 'decided at every start (Set-CabinetMode)' })
  get = { try { "$((Get-Content (Join-Path $ManifestDir 'cabinet-mode.json') -Raw | ConvertFrom-Json).effective)" } catch { '?' } }
  show = { param($v) "$v".ToUpper() }
  set = { param($v) 'set at every start from the cabinet type and the controls plugged in' } }
$S.cabinetLink = @{ group = 'CABINET'; label = 'CABINET LINK'; detail = 'While nobody is here, follow a similar cabinet: same game selected, and join its game after a 5 s countdown'; kind = 'switch'; default = $false
  get = { IsYes (Conf 'linkEvents') }
  set = { param($on) SetConf 'linkEvents' $(if ($on) { 'yes' } else { 'no' }); 'from the next start of the frontend' } }
$S.followHardware = @{ group = 'CABINET'; label = 'FOLLOW THE HARDWARE'; detail = 'Wheel unplugged and a flight stick in? The cabinet becomes a flight cab'; kind = 'switch'; default = $true
  get = { "$(Conf 'cabinetFollowHardware')" -notmatch '^(no|false|0)$' }
  set = { param($on) SetConf 'cabinetFollowHardware' $(if ($on) { 'yes' } else { 'no' }); 'applies at the next start' } }
$S.showAllModes = @{ group = 'CABINET'; label = 'SHOW EVERY MODE'; detail = 'Main menu lists Racing / Flight / Light gun even when their controls are not plugged in'; kind = 'switch'; default = $false
  get = { IsYes (Conf 'cabinetShowAllModes') }
  set = { param($on) SetConf 'cabinetShowAllModes' $(if ($on) { 'yes' } else { 'no' }); 'applies at the next start' } }

$nDisp = if ($cab) { @($cab.capabilities.displays).Count } else { 0 }
$S.secondScreen = @{ group = 'SCREEN AND SOUND'; label = 'SECOND SCREEN'; detail = "Marquee, game header and touch buttons on the second display ($nDisp display$(if ($nDisp -ne 1) { 's' }) connected)"; kind = 'switch'
  get = { [int]("0" + (Conf 'numScreens')) -ge 2 }
  set = { param($on)
    $a = @{ RetroFE = $RetroFE; Cabinet = $cf }; if (-not $on) { $a.Single = $true }
    & (Join-Path $t 'Set-RetroFEScreens.ps1') @a 6>&1 | Out-Null
    $now = [int]("0" + (Conf 'numScreens'))
    if ($on -and $now -lt 2) { 'only one display is connected' } else { "numScreens = $now" } } }
$S.videoEnable = @{ group = 'SCREEN AND SOUND'; label = 'PREVIEW VIDEOS'; detail = 'Game videos play in the menus (off helps a slow PC)'; kind = 'switch'; default = $true
  get = { (Conf 'videoEnable') -notmatch '^(no|false|0)$' }
  set = { param($on) SetConf 'videoEnable' $(if ($on) { 'yes' } else { 'no' }); '' } }
$S.videoVolume = @{ group = 'SCREEN AND SOUND'; label = 'VIDEO VOLUME'; detail = 'Sound of the preview video in the game list'; kind = 'cycle'; presets = @(100, 50, 25, 0); default = 100
  get = { [int](Read-AmUi $ManifestDir).videoVolume }
  show = { param($v) if ([int]$v -eq 0) { 'MUTED' } else { "$v %" } }
  set = { param($v) 'layout updated' + (SetUi 'videoVolume' ([int]$v)) } }
$S.menuSounds = @{ group = 'SCREEN AND SOUND'; label = 'MENU SOUNDS'; detail = 'Clicks and swooshes when you move and select in the menus'; kind = 'switch'; default = $true
  get = { [bool](Read-AmUi $ManifestDir).menuSounds }
  set = { param($on) 'layout updated' + (SetUi 'menuSounds' $on) } }

$S.story = @{ group = 'MENUS'; label = 'GAME STORY PANEL'; detail = 'After 8 s on a game, its story scrolls over the video'; kind = 'switch'; default = $true
  get = { [bool](Read-AmUi $ManifestDir).story }
  set = { param($on) 'layout updated' + (SetUi 'story' $on) } }
# how the game lists look (tools\Set-GameListView.ps1): the default, or one of the views built from the theme mock-ups
$S.gameListView = @{ group = 'MENUS'; label = 'GAME LIST VIEW'; detail = 'DEFAULT: one game at a time. WALL: fifteen picture tiles, the chosen game playing in the middle. PITWALL: the preview fills the screen, the list is a tower on the left'; kind = 'cycle'; presets = @('default', 'wall', 'pitwall'); default = 'default'
  get = { "$(& (Join-Path $t 'Set-GameListView.ps1') -RetroFE $RetroFE -Current)".Trim() }
  show = { param($v) "$v".ToUpper() }
  set = { param($v) $o = & (Join-Path $t 'Set-GameListView.ps1') -RetroFE $RetroFE -View $v 6>&1 | Out-String; (($o.Trim() -split "`r?`n") | Select-Object -Last 1) } }
$S.controlHints = @{ group = 'MENUS'; label = 'SPECIAL-CONTROL REMINDERS'; detail = 'Banner for trackball, spinner, gun, wheel and 4-way games'; kind = 'switch'; default = $true
  get = { [bool](Read-AmUi $ManifestDir).controlHints }
  set = { param($on) 'layout updated' + (SetUi 'controlHints' $on) } }
$S.attractModeTime = @{ group = 'MENUS'; label = 'ATTRACT MODE'; detail = 'Idle time before the menus start browsing by themselves'; kind = 'cycle'; presets = @(0, 20, 60, 120); default = 20
  get = { $v = Conf 'attractModeTime'; if ($v -match '^\d+$') { [int]$v } else { 0 } }
  show = { param($v) Seconds $v }
  set = { param($v) SetConf 'attractModeTime' "$v"; '' } }
$S.attractModeNextTime = @{ group = 'MENUS'; label = 'ATTRACT MODE NEXT GAME'; detail = 'How long attract mode stays on each game'; kind = 'cycle'; presets = @(10, 20, 60, 120); default = 20
  get = { $v = Conf 'attractModeNextTime'; if ($v -match '^\d+$') { [int]$v } else { 0 } }
  show = { param($v) Seconds $v }
  set = { param($v) SetConf 'attractModeNextTime' "$v"; '' } }
$hasFfb = $cab -and @($cab.devices | Where-Object { $_.ffb }).Count
if ($hasFfb -or (IsYes (Conf 'ffb'))) {
  $S.ffb = @{ group = 'MENUS'; label = 'FORCE FEEDBACK IN MENUS'; detail = 'Centre spring, detent ticks and a thunk on select - released when a game starts'; kind = 'switch'
    get = { IsYes (Conf 'ffb') }
    set = { param($on) SetConf 'ffb' $(if ($on) { 'yes' } else { 'no' }); if ($on -and -not (Conf 'ffbDevice')) { SetConf 'ffbDevice' 'G29'; 'ffbDevice = G29' } else { '' } } }
  # bass shakers from the game sound (tools\tactile\Set-ShakerAudio.ps1, state in manifest\tactile.json)
  $tj = Join-Path $ManifestDir 'tactile.json'
  $sa = Join-Path $t 'tactile\Set-ShakerAudio.ps1'
  $S.shakers = @{ group = 'MENUS'; label = 'BASS SHAKERS'; detail = 'Game sound to the shaker amp as well as the speakers (needs the shakers'' USB sound card)'; kind = 'switch'
    get = { (Test-Path $tj) -and [bool]((Get-Content $tj -Raw | ConvertFrom-Json).on) }
    set = { param($on)
      $st = if (Test-Path $tj) { Get-Content $tj -Raw | ConvertFrom-Json } else { $null }
      $str = if ($st -and $st.strength) { [int]$st.strength } else { 70 }
      $o = if ($on) { & powershell -NoProfile -ExecutionPolicy Bypass -File $sa -Apply -Strength $str -ManifestDir $ManifestDir 2>&1 } else { & powershell -NoProfile -ExecutionPolicy Bypass -File $sa -Off -ManifestDir $ManifestDir 2>&1 }
      (($o | Select-Object -Last 1) -replace '^.*?:\s*', '') } }
  $S.shakerStrength = @{ group = 'MENUS'; label = 'BASS SHAKER STRENGTH'; detail = 'How hard the shakers kick (shaker amp gain set in VoiceMeeter)'; kind = 'cycle'; presets = @(100, 70, 50, 30); default = 70
    get = { if (Test-Path $tj) { $s = Get-Content $tj -Raw | ConvertFrom-Json; if ($s.strength) { [int]$s.strength } else { 70 } } else { 70 } }
    show = { param($v) "$v %" }
    set = { param($v)
      $st = if (Test-Path $tj) { Get-Content $tj -Raw | ConvertFrom-Json } else { [pscustomobject]@{ on = $false } }
      $st | Add-Member -Force -NotePropertyName strength -NotePropertyValue ([int]$v)
      if ($st.on) { $o = & powershell -NoProfile -ExecutionPolicy Bypass -File $sa -Apply -Strength ([int]$v) -ManifestDir $ManifestDir 2>&1; (($o | Select-Object -Last 1) -replace '^.*?:\s*', '') }
      else { New-Item -ItemType Directory -Force $ManifestDir | Out-Null; $st | ConvertTo-Json | Set-Content $tj -Encoding utf8; "kept for when the shakers are switched on" } } }
}
$S.perfLog = @{ group = 'MENUS'; label = 'PERFORMANCE LOG'; detail = 'Frame times, p99 and hitches written to log.txt every 10 s'; kind = 'switch'; default = $false
  get = { [int]("0" + (Conf 'perfLog')) -gt 0 }
  set = { param($on) SetConf 'perfLog' $(if ($on) { '10' } else { '0' }); '' } }

$S.buttonLights = @{ group = 'LIGHTS AND DECK'; label = 'BUTTON LIGHTS (LEDBLINKY)'; detail = 'LEDBlinky lights the buttons each game uses'; kind = 'switch'
  get = { [bool](Conf 'LEDBlinkyDirectory') }
  set = { param($on)
    if (-not $on) { if (Set-AmConfCommented $sc 'LEDBlinkyDirectory' $true) { 'LEDBlinkyDirectory switched off (the path stays in settings.conf)' } else { 'already off' }; return }
    $kept = Get-AmConfCommented $sc 'LEDBlinkyDirectory'
    if ($kept) { [void](Set-AmConfCommented $sc 'LEDBlinkyDirectory' $false); "LEDBlinkyDirectory = $kept" + $(if (-not (Test-Path (Join-Path $kept 'LEDBlinky.exe'))) { ' - LEDBlinky.exe is not there' } else { '' }) }
    elseif (Test-Path (Join-Path $ledDefault 'LEDBlinky.exe')) { SetConf 'LEDBlinkyDirectory' $ledDefault; "LEDBlinkyDirectory = $ledDefault" }
    else { 'no LEDBlinky found - install it into the frontend''s LEDBlinky folder first' } } }
$S.lightsEngine = @{ group = 'LIGHTS AND DECK'; label = 'BUTTON LIGHTS ENGINE'; detail = 'LEDBlinky, or ArcadeMaster''s own AmPanel: faster, buttons glow while held, game lamps on the buttons, attract animations'; kind = 'cycle'
  presets = @('LEDBlinky', 'ArcadeMaster'); default = 'LEDBlinky'
  get = { $c = Conf 'LEDBlinkyDirectory'; if ($c -and $c.TrimEnd('\') -ieq (Join-Path (Split-Path $ManifestDir) 'ampanel-shim')) { 'ArcadeMaster' } else { 'LEDBlinky' } }
  set = { param($v) (& (Join-Path $PSScriptRoot 'Set-ButtonLights.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir -Engine $v 6>&1 | Out-String).Trim() } }
$amCfg = Join-Path (Split-Path $ManifestDir) 'AmPanel.json'
$S.lightsAttract = @{ group = 'LIGHTS AND DECK'; label = 'ATTRACT LIGHTS'; detail = 'What the buttons do while the arcade is idle (ArcadeMaster engine): a rainbow chase, the game''s colours breathing, or dancing to the music'; kind = 'cycle'
  presets = @('chase', 'breathe', 'audio'); default = 'chase'
  get = { $v = $null; if (Test-Path $amCfg) { $v = (Get-Content $amCfg -Raw | ConvertFrom-Json).AttractAnimation }; if ($v) { "$v".ToLower() } else { 'chase' } }
  show = { param($v) switch ("$v") { 'breathe' { 'BREATHE' } 'audio' { 'TO THE MUSIC' } default { 'CHASE' } } }
  set = { param($v)
    $cfg = [ordered]@{}; if (Test-Path $amCfg) { foreach ($p in (Get-Content $amCfg -Raw | ConvertFrom-Json).PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
    $cfg['AttractAnimation'] = "$v"; $cfg | ConvertTo-Json | Set-Content $amCfg -Encoding ascii
    # the running AmPanel takes it now (else at its next start)
    try { $c = New-Object IO.Pipes.NamedPipeClientStream('.', 'ArcadeMaster.Panel', [IO.Pipes.PipeDirection]::InOut); $c.Connect(500); $w = New-Object IO.StreamWriter($c); $w.AutoFlush = $true; $w.WriteLine("{`"cmd`":`"attract`",`"kind`":`"$v`",`"noreply`":true}"); $c.Dispose(); 'AmPanel updated' } catch { 'saved - AmPanel takes it at its next start' } } }
$S.speech = @{ group = 'LIGHTS AND DECK'; label = 'ANNOUNCE THE GAME'; detail = 'A voice says "Now playing ..." with the game''s real name when it starts'; kind = 'switch'; default = $false
  get = { $v = $null; if (Test-Path $amCfg) { $v = (Get-Content $amCfg -Raw | ConvertFrom-Json).Speech }; "$v" -eq 'start' }
  set = { param($on)
    $v = if ($on) { 'start' } else { 'off' }
    $cfg = [ordered]@{}; if (Test-Path $amCfg) { foreach ($p in (Get-Content $amCfg -Raw | ConvertFrom-Json).PSObject.Properties) { $cfg[$p.Name] = $p.Value } }
    $cfg['Speech'] = $v; $cfg | ConvertTo-Json | Set-Content $amCfg -Encoding ascii
    try { $c = New-Object IO.Pipes.NamedPipeClientStream('.', 'ArcadeMaster.Panel', [IO.Pipes.PipeDirection]::InOut); $c.Connect(500); $w = New-Object IO.StreamWriter($c); $w.AutoFlush = $true; $w.WriteLine("{`"cmd`":`"attract`",`"speech`":`"$v`",`"noreply`":true}"); $c.Dispose(); 'AmPanel updated' } catch { 'saved - AmPanel takes it at its next start' } } }
# the Pixelcade LED marquee (tools\Set-Marquee.ps1): on = AmPanel finds Pixelcade and drives it (automatic at every boot);
# off = AmPanel leaves it alone. Only matters with the ArcadeMaster engine - with LEDBlinky, LEDBlinky drives it.
$S.marquee = @{ group = 'LIGHTS AND DECK'; label = 'LED MARQUEE (PIXELCADE)'; detail = 'The Pixelcade marquee shows the selected game; found automatically when one is connected'; kind = 'switch'; default = $true
  get = { $v = $null; if (Test-Path $amCfg) { $v = (Get-Content $amCfg -Raw | ConvertFrom-Json).Marquee }; "$v" -ne 'off' }
  set = { param($on) (& (Join-Path $PSScriptRoot 'Set-Marquee.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir -On:([bool]$on) -Off:(-not $on) 6>&1 | Out-String).Trim() } }
$S.ledCloseOnExit = @{ group = 'LIGHTS AND DECK'; label = 'LIGHTS OFF WHEN THE ARCADE CLOSES'; detail = 'LEDBlinky is closed together with the frontend'; kind = 'switch'; default = $false
  get = { IsYes (Conf 'LEDBlinkyCloseOnExit') }
  set = { param($on) SetConf 'LEDBlinkyCloseOnExit' $(if ($on) { 'yes' } else { 'no' }); '' } }
$S.streamDeck = @{ group = 'LIGHTS AND DECK'; label = 'STREAM DECK'; detail = 'The Stream Deck shows themes, switches and in-game keys'; kind = 'switch'; default = $true
  get = { [bool](Read-AmUi $ManifestDir).streamDeck }
  set = { param($on)
    [void](SetUi 'streamDeck' $on)
    if ($NoProcess) { return 'saved (helper not started / stopped: -NoProcess)' }
    if (-not $on) { $ps = Get-DeckProcs; foreach ($p in $ps) { try { Stop-Process -Id $p.ProcessId -Force } catch { } }; return $(if ($ps) { 'deck helper stopped' } else { 'off - not started at boot' }) }
    if (Get-DeckProcs) { return 'deck helper already running' }
    . (Join-Path $t 'lib\AmPython.ps1'); $pyw = Find-AmPython -Windowed
    if (-not $pyw -or -not (Test-Path $deckPy)) { return 'on - starts at the next boot (no Python found now)' }
    Start-Process $pyw -ArgumentList @("`"$deckPy`"", '--retrofe', "`"$RetroFE`"", '--manifest', "`"$ManifestDir`"") -WindowStyle Hidden; 'deck helper started' } }
if (Test-Path $deckCfg) {
  $S.deckIdleDim = @{ group = 'LIGHTS AND DECK'; label = 'STREAM DECK IDLE DIM'; detail = 'Dim the deck after this long without a key press (deck.json idleDimMinutes)'; kind = 'cycle'; presets = @(0, 5, 10, 30); default = 10
    get = { $v = Get-AmJsonNumber $deckCfg 'idleDimMinutes'; if ($null -eq $v) { 10 } else { [int]$v } }
    show = { param($v) if ([int]$v -eq 0) { 'NEVER' } else { "$v min" } }
    set = { param($v) [void](Set-AmJsonNumber $deckCfg 'idleDimMinutes' ([int]$v)); 'the deck reloads it within a second' } }
}
$S.restoreDefaults = @{ group = 'RESET'; label = 'RESTORE DEFAULTS'; kind = 'action'
  detail = 'Attract 20 s, sounds, story, reminders, videos and deck on - type AUTO. Screens and lights stay'
  set = { param($v)
    $done = @()
    foreach ($id in @($S.Keys)) {
      $d = $S[$id]; if (-not $d.ContainsKey('default') -or $null -eq $d.default) { continue }
      $cur = & $d.get; if ("$cur" -eq "$($d.default)") { continue }
      [void](& $d.set $d.default); $done += $d.label.ToLower()
    }
    if ($done) { "back to defaults: $($done -join ', ')" } else { 'everything was already at its default' } } }

# AM_SETTINGS_ONLY=id1,id2: list only those (tests)
function Get-Display([string]$id, $v) { $d = $S[$id]; if ($d.kind -eq 'switch') { if ($v) { 'ON' } else { 'OFF' } } elseif ($d.show) { "$(& $d.show $v)" } else { "$v" } }
function Get-State {
  @(foreach ($id in $S.Keys) {
      $d = $S[$id]; $v = $null; if ($d.get) { try { $v = & $d.get } catch { } }
      [ordered]@{ id = $id; group = $d.group; label = $d.label; detail = $d.detail; kind = $d.kind; value = $(if ($d.kind -eq 'action') { 'RESET' } else { Get-Display $id $v }); raw = "$v"; on = $(if ($d.kind -eq 'switch') { [bool]$v } else { $false }); confirm = ($d.kind -eq 'action') }
    })
}

if ($Defaults) { $Set = @($Set) + 'restoreDefaults=run' }
foreach ($pair in $Set) {
  foreach ($p in ($pair -split ',')) {
    if (-not $p.Trim()) { continue }
    $k, $v = $p -split '=', 2; $k = $k.Trim(); $v = "$v".Trim()
    if (-not $S.Contains($k)) { Write-Warning "unknown setting '$k' ($($S.Keys -join ', '))"; continue }
    $d = $S[$k]; $msg = ''
    try {
      switch ($d.kind) {
        'switch' { $want = if ($v -match '^(toggle|)$') { -not [bool](& $d.get) } else { IsYes $v }; $msg = & $d.set $want }
        'cycle' {
          $cur = & $d.get; $pre = @($d.presets)
          if ($v -match '^(toggle|next|)$') {
            $i = [array]::IndexOf(@($pre | ForEach-Object { "$_" }), "$cur")
            if ($i -lt 0) { $num = $pre | Where-Object { "$_" -match '^\d+$' -and "$cur" -match '^\d+$' -and [int]$_ -gt [int]$cur } | Select-Object -First 1; $new = if ($null -ne $num) { $num } else { $pre[0] } }
            else { $new = $pre[($i + 1) % $pre.Count] }
          } else { $new = if ("$($pre[0])" -match '^\d+$') { [int]$v } else { $v.ToLower() } }
          $msg = & $d.set $new
        }
        default { $msg = & $d.set $v }
      }
    } catch { $msg = "failed: $($_.Exception.Message)" }
    $now = $null; if ($d.get) { try { $now = & $d.get } catch { } }
    $shown = if ($d.kind -eq 'action') { 'DONE' } else { Get-Display $k $now }
    Write-Host ("{0,-16} -> {1}{2}" -f $k, $shown, $(if ("$msg".Trim()) { "  ($("$msg".Trim()))" } else { '' }))
  }
}
if ($List -or -not $Set) { ConvertTo-Json @(Get-State) -Depth 4 }
