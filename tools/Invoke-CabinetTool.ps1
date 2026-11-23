<#
.SYNOPSIS
  Runs one ArcadeMaster maintenance command for the in-frontend TOOLS menu. Normally hosted by
  Show-ToolScreen.ps1, which draws it full screen: besides readable text this script emits structured
  "@AM {json}" lines (devices, switches, steps, tiles, images) that the tool screen turns into visuals.
  Run on its own it still works in a console (the @AM lines are hidden unless AM_VISUAL=1).
  Afterwards it refreshes the Tools list art (state shown on each item) - RetroFE restarts (reboot = yes).
#>
param(
  [Parameter(Mandatory)][ValidateSet('WheelSetup', 'DetectControllers', 'RepairIds', 'RebuildMenus', 'ToggleFfb', 'ToggleSecondScreen', 'ShuffleBackgrounds', 'TogglePerfLog', 'CabinetType', 'SystemSettings', 'SystemHealth', 'Themes')]
  [string]$Tool,
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [int]$AutoCloseSec = 15,
  [string]$Choice                    # Themes: apply this theme without asking (Stream Deck, scripts)
)
$ErrorActionPreference = 'Continue'
$t = $PSScriptRoot
$visual = $env:AM_VISUAL -eq '1'
try { $Host.UI.RawUI.WindowTitle = "ArcadeMaster Tools - $Tool" } catch { }
function Emit([hashtable]$o) { if ($visual) { [Console]::Out.WriteLine('@AM ' + (ConvertTo-Json $o -Compress -Depth 6)) } }
function Banner([string]$s) { Write-Host ''; Write-Host ('=' * 70) -ForegroundColor Magenta; Write-Host "  $s" -ForegroundColor Cyan; Write-Host ('=' * 70) -ForegroundColor Magenta; Write-Host '' }
# runs a sibling script; its output streams through (for the tool screen) and is also returned for parsing
function Run([string]$script, [string[]]$a) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $t $script) @a 2>&1 | ForEach-Object { $s = "$_"; [Console]::Out.WriteLine($s); $s }
  $script:lastExit = $LASTEXITCODE
}
function Step([string]$id, [string]$label, [string]$status) { Emit @{ type = 'step'; id = $id; label = $label; status = $status } }
function Set-Setting([string]$key, [string]$value) {
  $sc = Join-Path $RetroFE 'settings.conf'; $lines = [System.Collections.Generic.List[string]](Get-Content $sc); $done = $false
  for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") { $lines[$i] = "$key = $value"; $done = $true } }
  if (-not $done) { $lines.Add("$key = $value") }; Set-Content $sc $lines -Encoding ascii
}
function Get-Setting([string]$key) { $m = Select-String -Path (Join-Path $RetroFE 'settings.conf') -Pattern "^\s*$([regex]::Escape($key))\s*=\s*(.*)$" | Select-Object -Last 1; if ($m) { $m.Matches[0].Groups[1].Value.Trim() } }
$cab = Join-Path $ManifestDir 'cabinet.json'; $hist = Join-Path $ManifestDir 'device-history.json'; $games = Join-Path $ManifestDir 'games.json'

function Emit-Devices {
  if (-not (Test-Path $cab)) { return }
  $c = Get-Content $cab -Raw | ConvertFrom-Json; $k = $c.capabilities
  $devs = @(foreach ($d in $c.devices) { @{ name = $d.name; role = $d.role; ffb = [bool]$d.ffb; axes = @($d.axes).Count; buttons = [int]$d.buttons; hats = [int]$d.hats } })
  if ($k.touchScreens -gt 0) { $devs += @{ name = "Touch screen x$($k.touchScreens)"; role = 'touch'; ffb = $false; axes = 0; buttons = 0; hats = 0 } }
  if ($k.keyboard) { $devs += @{ name = 'Keyboard / encoder'; role = 'keyboard'; ffb = $false; axes = 0; buttons = 0; hats = 0 } }
  Emit @{ type = 'devices'; devices = $devs }
  Emit @{ type = 'tiles'; tiles = @(
      @{ label = 'PLAYERS'; value = "$($k.players)"; icon = 'gamepad' },
      @{ label = 'MODES'; value = ((@($k.modes) | ForEach-Object { $_.ToUpper() }) -join ' + '); icon = 'wheel' },
      @{ label = 'DISPLAYS'; value = "$(@($k.displays).Count)"; icon = 'display' },
      @{ label = 'RESTRICTOR'; value = $(if ($k.restrictor) { 'YES' } else { 'NO' }); icon = 'joystick' }) }
}
function Emit-IdCheck([string[]]$out, [bool]$applied) {
  $changed = 0; $m = $out | Select-String '(\d+) profile files would change' | Select-Object -First 1; if ($m) { $changed = [int]$m.Matches[0].Groups[1].Value }
  $left = 0; $in = $false; foreach ($l in $out) { if ($l -match '^left alone') { $in = $true; continue }; if ($in -and $l -match '^\s+(\d+) x') { $left += [int]$Matches[1] } }
  Emit @{ type = 'stats'; stats = @(
      @{ label = $(if ($applied) { 'PROFILES REPAIRED' } else { 'PROFILES NEEDING REPAIR' }); value = "$changed"; tone = $(if ($changed -eq 0 -or $applied) { 'good' } else { 'warn' }) },
      @{ label = 'BINDINGS FOR UNPLUGGED DEVICES'; value = "$left"; tone = $(if ($left) { 'dim' } else { 'good' }) }) }
}
function Emit-Collections {
  $tiles = @()
  foreach ($n in 'Racing', 'Flight', 'Arcade', 'Lightgun') {
    $d = Join-Path $RetroFE "collections\$n"; if (-not (Test-Path $d)) { continue }
    $cnt = 0; Get-ChildItem $d -Filter *.sub -File | ForEach-Object { $cnt += @(Get-Content $_.FullName | Where-Object { $_.Trim() }).Count }
    $tiles += @{ label = $n.ToUpper(); suffix = ' GAMES'; value = "$cnt"; icon = @{ Racing = 'wheel'; Flight = 'joystick'; Arcade = 'gamepad'; Lightgun = 'gun' }[$n] }
  }
  if ($tiles) { Emit @{ type = 'tiles'; tiles = $tiles } }
}
function Emit-Backgrounds {
  $dir = Join-Path $RetroFE 'layouts\ArcadeMaster\collections\Main\system_artwork'
  $files = @(Get-ChildItem $dir -Filter 'am_bg*' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
  Emit @{ type = 'images'; title = 'MAIN MENU BACKDROPS - NEW ORDER'; files = $files }
}

switch ($Tool) {
  'WheelSetup' {
    Banner 'WHEEL SETUP - follow the prompts (turn, press, release)'
    Emit @{ type = 'wizard'; state = 'start' }
    Run 'wheelmap\WheelMap.ps1' @('-Capture', '-Name', 'G29') | Out-Null
    Emit @{ type = 'wizard'; state = 'end'; ok = ($script:lastExit -eq 0) }
    Run 'Get-CabinetDevices.ps1' @('-Out', $cab, '-History', $hist) | Out-Null
    Emit-Devices
  }
  'DetectControllers' {
    Banner 'CONTROLLERS DETECTED'
    Run 'Get-CabinetDevices.ps1' @('-Out', $cab, '-History', $hist) | Out-Null
    Run 'Set-DolphinControllers.ps1' @('-ManifestDir', $ManifestDir) | Out-Null
    Emit-Devices
    Banner 'CONTROLLER ID CHECK (dry run - use Repair Controller IDs to apply)'
    $o = Run 'Update-ControllerIds.ps1' @('-RetroFE', $RetroFE, '-Cabinet', $cab, '-History', $hist)
    Emit-IdCheck $o $false
  }
  'RepairIds' {
    Banner 'REPAIR CONTROLLER IDS'
    Run 'Get-CabinetDevices.ps1' @('-Out', $cab, '-History', $hist) | Out-Null
    Emit-Devices
    $o = Run 'Update-ControllerIds.ps1' @('-RetroFE', $RetroFE, '-Cabinet', $cab, '-History', $hist, '-Apply')
    Emit-IdCheck $o $true
  }
  'RebuildMenus' {
    Banner 'REBUILD GAME MENUS'
    $plan = [ordered]@{
      devices     = @('Detect controllers', 'Get-CabinetDevices.ps1', @('-Out', $cab, '-History', $hist))
      catalog     = @('Scan game library', 'Build-Manifest.ps1', @('-RetroFE', $RetroFE, '-Out', $games))
      controls    = @('Match games to controls', 'Add-GameControls.ps1', @('-Manifest', $games, '-Cabinet', $cab))
      collections = @('Build Racing / Flight / Arcade menus', 'New-RetroFECollections.ps1', @('-Manifest', $games, '-RetroFE', $RetroFE, '-Cabinet', $cab, '-RebuildDatabase'))
      # the menu builder lists every mode that has games; the cabinet mode then hides the ones whose controls are not
      # plugged in (as at boot) - without this, Flight showed on a wheel-only cabinet until the next boot
      mode        = @('Show only what this cabinet can play', 'Set-CabinetMode.ps1', @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir))
      backdrops   = @('Deal new game backdrops', 'Set-LayoutThemes.ps1', @('-LayoutDir', (Join-Path $RetroFE 'layouts\ArcadeMaster'), '-CollectionsDir', (Join-Path $RetroFE 'collections'), '-ManifestDir', $ManifestDir, '-Shuffle'))
    }
    foreach ($id in $plan.Keys) { Step $id $plan[$id][0] 'pending' }
    foreach ($id in $plan.Keys) {
      Step $id $plan[$id][0] 'run'
      Run $plan[$id][1] $plan[$id][2] | Out-Null
      Step $id $plan[$id][0] $(if ($script:lastExit -eq 0) { 'ok' } else { 'fail' })
    }
    # how many games can start, and where the reasons for the others are (Build-Manifest writes games-cant-start.txt)
    if (Test-Path $games) {
      $gl = @((Get-Content $games -Raw | ConvertFrom-Json).games)
      $myModes = @(if (Test-Path $cab) { (Get-Content $cab -Raw | ConvertFrom-Json).capabilities.modes }); if ($myModes) { $gl = @($gl | Where-Object { $myModes -contains $_.category }) }
      $cantN = @($gl | Where-Object { -not @($_.variants.PSObject.Properties | Where-Object { $_.Value.ok }).Count }).Count
      Step 'games' ("{0} of {1} games can start{2}" -f ($gl.Count - $cantN), $gl.Count, $(if ($cantN) { " - why the other $cantN can't: manifest\games-cant-start.txt" } else { '' })) 'ok'   # information, not a failure of the rebuild
    }
    # joystick-panel cabinets (pedestal / stand-up, no wheel): a button-layout card for every game (tools/New-PanelControlsArt.py)
    $capNow = if (Test-Path $cab) { (Get-Content $cab -Raw | ConvertFrom-Json).capabilities } else { $null }
    $py = (Get-Command python.exe -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch '\\WindowsApps\\' } | Select-Object -First 1).Source
    if ($capNow -and $capNow.controlPanel -and -not $capNow.wheel -and $py) {
      Step 'panelcards' 'Button layout cards' 'run'
      & $py (Join-Path $t 'New-PanelControlsArt.py') --retrofe $RetroFE --manifest $ManifestDir 2>&1 | ForEach-Object { [Console]::Out.WriteLine("$_") }
      Step 'panelcards' 'Button layout cards' $(if ($LASTEXITCODE -eq 0) { 'ok' } else { 'fail' })
    }
    Emit-Collections
  }
  'ToggleFfb' {
    $on = (Get-Setting 'ffb') -match '^(yes|true|1)$'
    Set-Setting 'ffb' $(if ($on) { 'no' } else { 'yes' })
    if (-not $on -and -not (Get-Setting 'ffbDevice')) { Set-Setting 'ffbDevice' 'G29' }
    Banner ("FORCE FEEDBACK IN THE MENUS: " + $(if ($on) { 'OFF' } else { 'ON' }))
    Emit @{ type = 'toggle'; label = 'FORCE FEEDBACK'; icon = 'ffb'; on = (-not $on); detail = $(if ($on) { 'The wheel stays loose in the menus' } else { 'Centre spring, detent ticks and a thunk on select - released when a game starts' }) }
  }
  'ToggleSecondScreen' {
    $two = (Get-Setting 'numScreens') -eq '2'
    Run 'Get-CabinetDevices.ps1' @('-Out', $cab, '-History', $hist) | Out-Null
    if ($two) { Run 'Set-RetroFEScreens.ps1' @('-RetroFE', $RetroFE, '-Cabinet', $cab, '-Single') | Out-Null } else { Run 'Set-RetroFEScreens.ps1' @('-RetroFE', $RetroFE, '-Cabinet', $cab) | Out-Null }
    $now = (Get-Setting 'numScreens') -eq '2'
    Banner ("SECOND SCREEN: numScreens = " + (Get-Setting 'numScreens'))
    $disp = @(); if (Test-Path $cab) { $disp = @((Get-Content $cab -Raw | ConvertFrom-Json).capabilities.displays | ForEach-Object { @{ w = $_.width; h = $_.height; primary = [bool]$_.primary } }) }
    Emit @{ type = 'toggle'; label = 'SECOND SCREEN'; icon = 'screen2'; on = $now; detail = $(if ($now) { 'Marquee banner, game header and touch buttons on the second display' } elseif ($disp.Count -lt 2) { 'Only one display is connected' } else { 'Everything on the main display' }) }
    Emit @{ type = 'displays'; displays = $disp; used = $(if ($now) { 2 } else { 1 }) }
  }
  'ShuffleBackgrounds' {
    Run 'Set-LayoutThemes.ps1' @('-LayoutDir', (Join-Path $RetroFE 'layouts\ArcadeMaster'), '-CollectionsDir', (Join-Path $RetroFE 'collections'), '-ManifestDir', $ManifestDir, '-Shuffle', '-BackgroundsOnly') | Out-Null
    Banner 'BACKGROUNDS SHUFFLED'
    Emit-Backgrounds
  }
  'CabinetType' {
    . (Join-Path $t 'lib\CabinetTypes.ps1')
    $cabObj = if (Test-Path $cab) { Get-Content $cab -Raw | ConvertFrom-Json } else { $null }
    $current = Get-Setting 'cabinetType'; if (-not $current) { $current = 'auto' }
    $ids = @(Get-AmCabinetChoices)
    $opts = @(foreach ($id in $ids) {
      $r = Resolve-AmCabinetType $id $cabObj '' ''
      @{ id = $id; label = $(if ($id -eq 'auto') { 'AUTO' } else { $r.title }); sub = $(if ($id -eq 'auto') { "detected: $($r.title)" } else { $r.tagline }); icons = @($r.icons); color = $r.color; color2 = $r.color2 }
    })
    $sel = [Math]::Max(0, [array]::IndexOf($ids, $current.ToLower()))
    Banner "CABINET TYPE - now: $current"
    $chosen = $null
    if ($visual -and $env:AM_WIZ_KEYFILE) {
      Emit @{ type = 'choice'; title = 'WHAT IS THIS CABINET?'; prompt = 'Shown in the boot intro after the studio logo'; options = $opts; selected = $sel }
      $deadline = (Get-Date).AddSeconds(180)
      while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $env:AM_WIZ_KEYFILE) {
          $k = (Get-Content -LiteralPath $env:AM_WIZ_KEYFILE -Raw).Trim(); Remove-Item -LiteralPath $env:AM_WIZ_KEYFILE -Force -ErrorAction SilentlyContinue
          if ($k -like 'CHOICE:*') { $chosen = $k.Substring(7); break }
        }
        Start-Sleep -Milliseconds 100
      }
    }
    if ($chosen -and $ids -contains $chosen) {
      Set-Setting 'cabinetType' $chosen
      Write-Host "cabinetType = $chosen"
    } else { Write-Host 'no change' }
    $out = Join-Path $RetroFE 'layouts\ArcadeMaster\images\intro'
    Run 'New-CabinetIntro.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir) | Out-Null
    Emit @{ type = 'intro'; dir = $out; setting = (Get-Setting 'cabinetType') }
  }  'SystemSettings' {
    $sys = Join-Path $t 'Set-CabinetSystem.ps1'
    $stateOf = { $j = (& powershell -NoProfile -ExecutionPolicy Bypass -File $sys -List -RetroFE $RetroFE -ManifestDir $ManifestDir | Out-String); @($j | ConvertFrom-Json | ForEach-Object { $_ }) }
    Banner 'CABINET SYSTEM SETTINGS'
    if (-not ($visual -and $env:AM_WIZ_KEYFILE)) { & $stateOf | ForEach-Object { Write-Host ("  {0,-24} {1}" -f $_.label, $(if ($_.on) { 'ON' } else { 'off' })) }; break }
    $items = & $stateOf
    Emit @{ type = 'settings'; items = @($items | ForEach-Object { @{ id = $_.id; label = $_.label; detail = $_.detail; on = [bool]$_.on } }); message = 'Pick a switch and press a button to flip it' }
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 100
      if (-not (Test-Path -LiteralPath $env:AM_WIZ_KEYFILE)) { continue }
      $k = (Get-Content -LiteralPath $env:AM_WIZ_KEYFILE -Raw).Trim(); Remove-Item -LiteralPath $env:AM_WIZ_KEYFILE -Force -ErrorAction SilentlyContinue
      if ($k -eq 'CHOICE:done') { break }
      if ($k -notlike 'TOGGLE:*') { continue }
      $id = $k.Substring(7); $deadline = (Get-Date).AddSeconds(300)
      $cur = $items | Where-Object { $_.id -eq $id } | Select-Object -First 1
      if ($id -eq 'autoLogin' -and -not $cur.on) { Emit @{ type = 'yield'; message = 'Finish the Windows sign-in box, then the arcade comes back' } }
      $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $sys -Set "$id=toggle" -RetroFE $RetroFE -ManifestDir $ManifestDir | Out-String).Trim()
      Write-Host $out
      $items = & $stateOf
      $msg = ($out -split "`r?`n" | Where-Object { $_ -match '->' } | Select-Object -Last 1) -replace '^\S+\s+->\s+', ''
      Emit @{ type = 'settings'; items = @($items | ForEach-Object { @{ id = $_.id; label = $_.label; detail = $_.detail; on = [bool]$_.on } }); message = "$($cur.label): $msg"; resume = $true }
    }
  }  'SystemHealth' {
    Banner 'SYSTEM HEALTH'
    Run 'Repair-ArcadeHealth.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir) | Out-Null
  }
  'Themes' {
    $reg = Join-Path $ManifestDir 'themes.json'
    $list = @(); if (Test-Path $reg) { $list = @((Get-Content $reg -Raw | ConvertFrom-Json).themes | ForEach-Object { $_ }) }
    $list = @($list | Where-Object { Test-Path (Join-Path $RetroFE "layouts\$($_.name)\layout.xml") })
    $cur = Get-Setting 'layout'; $mode = $null; $mf = Join-Path $ManifestDir 'cabinet-mode.json'; if (Test-Path $mf) { $mode = ((Get-Content $mf -Raw | ConvertFrom-Json).effective -split '\+')[0] }
    Banner "THEMES - now: $cur$(if ($mode) { " (cabinet mode: $mode)" })"
    if (-not $Choice -and (-not ($visual -and $env:AM_WIZ_KEYFILE) -or -not $list)) { $list | ForEach-Object { Write-Host ("  {0,-20} coverage {1}%" -f $_.name, $_.score) }; break }
    $chosen = $null
    if ($Choice) { $chosen = $Choice } else {
    $opts = @($list | Sort-Object { $_.name -ne $cur }, { -[int]$_.score } | ForEach-Object { @{ id = $_.name; label = $(if ($_.name -like 'CO-*') { ($_.name -replace '^CO-', '') + ' (imported)' } else { $_.name }); sub = $(if ($_.name -eq $cur) { "IN USE - artwork $($_.score)%" } else { "artwork coverage $($_.score)%$(if ($_.name -like 'CO-*') { ' - imported' })" }); preview = $_.preview; icons = @(); color = $(if ($_.name -eq $cur) { '3ddc84' } else { '2ec8ff' }); color2 = '2ec8ff' } })
    Emit @{ type = 'choice'; title = "PICK A THEME$(if ($mode) { " FOR $($mode.ToUpper()) MODE" })"; prompt = 'Applied after the frontend restarts'; options = $opts; selected = 0 }
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline) { if (Test-Path -LiteralPath $env:AM_WIZ_KEYFILE) { $k = (Get-Content -LiteralPath $env:AM_WIZ_KEYFILE -Raw).Trim(); Remove-Item -LiteralPath $env:AM_WIZ_KEYFILE -Force -ErrorAction SilentlyContinue; if ($k -like 'CHOICE:*') { $chosen = $k.Substring(7); break } }; Start-Sleep -Milliseconds 100 }
    }
    if ($chosen -and ($list | Where-Object { $_.name -eq $chosen })) {
      Set-Setting 'layout' $chosen
      if ($mode) { Set-Setting "cabinetTheme.$mode" $chosen }   # this mode keeps the theme across boots (Set-CabinetMode)
      Run 'New-CabinetIntro.ps1' @('-RetroFE', $RetroFE, '-ManifestDir', $ManifestDir, '-Layout', $chosen) | Out-Null
      $pv = ($list | Where-Object { $_.name -eq $chosen }).preview
      Emit @{ type = 'images'; title = "THEME: $($chosen -replace '^CO-','')$(if ($mode) { " - kept for $mode mode" })"; files = @($pv | Where-Object { $_ }) }
      Write-Host "layout = $chosen"
    } else { Write-Host 'no change' }
  }  'TogglePerfLog' {
    $on = [int]("0" + (Get-Setting 'perfLog')) -gt 0
    Set-Setting 'perfLog' $(if ($on) { '0' } else { '10' })
    Banner ("PERFORMANCE LOG: " + $(if ($on) { 'OFF' } else { 'ON (every 10 s, see log.txt [Perf] lines)' }))
    Emit @{ type = 'toggle'; label = 'PERFORMANCE LOG'; icon = 'perf'; on = (-not $on); detail = $(if ($on) { 'No frame-time logging' } else { 'Frame times, p99 and hitches written to log.txt every 10 s' }) }
  }
}

# refresh the Tools list art so each item shows its new state when RetroFE comes back
$art = Join-Path $t 'New-ToolsArt.ps1'
if (Test-Path $art) { & powershell -NoProfile -ExecutionPolicy Bypass -File $art -RetroFE $RetroFE -ManifestDir $ManifestDir -NoFanart | Out-Null }

if ($env:AM_TOOL_NOPAUSE -eq '1') { return }
Write-Host ''; Write-Host "Press any key to return to the arcade (closes by itself in $AutoCloseSec s)..." -ForegroundColor Yellow
$deadline = (Get-Date).AddSeconds($AutoCloseSec)
while ((Get-Date) -lt $deadline) { try { if ([Console]::KeyAvailable) { [void][Console]::ReadKey($true); break } } catch { break }; Start-Sleep -Milliseconds 100 }
