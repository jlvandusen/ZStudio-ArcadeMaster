# AmTheme.ps1 - a theme change has to be confirmed on screen, or it is undone (dot-source after lib\AmSettings.ps1).
#   Save-AmThemePending     Tools > Themes / the Stream Deck, just before they switch: what to go back to
#   Restore-AmThemePending  no confirm in time, Escape, or the frontend died while asking: put it back
#   Reset-AmTheme           the manual fallback: ArcadeMaster layout, default style, no per-mode overrides
# manifest\theme-pending.json = { at, choice, mode, previous = { layout, cabinetThemeKey, cabinetTheme, skins } }
# "skins" is the raw text of manifest\skins.json before the change ($null = there was none).

function Get-AmPendingPath([string]$ManifestDir) { Join-Path $ManifestDir 'theme-pending.json' }
function Write-AmLauncherLog([string]$RetroFE, [string]$Message) {
  try { Add-Content -LiteralPath (Join-Path $RetroFE 'arcademaster-launcher.log') ("[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message) } catch { }
}

function Save-AmThemePending([string]$RetroFE, [string]$ManifestDir, [string]$Mode, [string]$Choice) {
  $pf = Get-AmPendingPath $ManifestDir; $sc = Join-Path $RetroFE 'settings.conf'; $skinFile = Join-Path $ManifestDir 'skins.json'
  # a second change before the first was confirmed: going back means going back to the last CONFIRMED look
  $prev = $null
  if (Test-Path -LiteralPath $pf) { try { $prev = (Get-Content -LiteralPath $pf -Raw | ConvertFrom-Json).previous } catch { } }
  if (-not $prev) {
    $prev = [ordered]@{
      layout          = Get-AmConf $sc 'layout'
      cabinetThemeKey = $(if ($Mode) { "cabinetTheme.$Mode" } else { $null })
      cabinetTheme    = $(if ($Mode) { Get-AmConf $sc "cabinetTheme.$Mode" } else { $null })
      skins           = $(if (Test-Path -LiteralPath $skinFile) { [IO.File]::ReadAllText($skinFile) } else { $null })
    }
  }
  $o = [ordered]@{ at = (Get-Date).ToString('s'); choice = $Choice; mode = $Mode; previous = $prev }
  [IO.File]::WriteAllText($pf, ($o | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
  Write-AmLauncherLog $RetroFE ("theme change to '{0}' waits for a confirm (previous: layout {1}{2}) - manifest\theme-pending.json" -f $Choice, $prev.layout, $(if ($prev.cabinetThemeKey) { ", $($prev.cabinetThemeKey) = $(if ($prev.cabinetTheme) { $prev.cabinetTheme } else { '(none)' })" }))
}

# re-deal the ArcadeMaster slots for the style now in skins.json, and the boot intro for the layout in use
function Update-AmThemeArt([string]$RetroFE, [string]$ManifestDir, [string]$Layout, [bool]$Skins) {
  if ($env:AM_THEME_NOART -eq '1') { return }   # tests: settings only
  $tools = Split-Path $PSScriptRoot; if ((Split-Path $PSScriptRoot -Leaf) -ne 'lib') { $tools = $PSScriptRoot }
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  if ($Skins -and (Test-Path (Join-Path $RetroFE 'layouts\ArcadeMaster'))) {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tools 'Set-LayoutThemes.ps1') -LayoutDir (Join-Path $RetroFE 'layouts\ArcadeMaster') -CollectionsDir (Join-Path $RetroFE 'collections') -ManifestDir $ManifestDir -Shuffle 2>&1 | Out-Null
  }
  if ($Layout -and (Test-Path (Join-Path $RetroFE "layouts\$Layout\layout.xml"))) {
    & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $tools 'New-CabinetIntro.ps1') -RetroFE $RetroFE -ManifestDir $ManifestDir -Layout $Layout 2>&1 | Out-Null
  }
}

# -> one line saying what was put back, or $null when nothing was waiting
function Restore-AmThemePending([string]$RetroFE, [string]$ManifestDir, [string]$Why, [switch]$NoArt) {
  $pf = Get-AmPendingPath $ManifestDir; if (-not (Test-Path -LiteralPath $pf)) { return $null }
  $sc = Join-Path $RetroFE 'settings.conf'; $skinFile = Join-Path $ManifestDir 'skins.json'
  $p = $null; try { $p = Get-Content -LiteralPath $pf -Raw | ConvertFrom-Json } catch { }
  $did = @(); $skinsChanged = $false
  if ($p -and $p.previous) {
    $prev = $p.previous
    $lay = "$($prev.layout)"
    if (-not $lay -or -not (Test-Path (Join-Path $RetroFE "layouts\$lay\layout.xml"))) { $lay = 'ArcadeMaster' }   # the old one is gone: the safe one
    if (Set-AmConf $sc 'layout' $lay) { $did += "layout = $lay" }
    if ($prev.cabinetThemeKey) {
      if ($prev.cabinetTheme) { if (Set-AmConf $sc $prev.cabinetThemeKey $prev.cabinetTheme) { $did += "$($prev.cabinetThemeKey) = $($prev.cabinetTheme)" } }
      elseif (Remove-AmConfKey $sc $prev.cabinetThemeKey) { $did += "$($prev.cabinetThemeKey) removed" }
    }
    $now = if (Test-Path -LiteralPath $skinFile) { [IO.File]::ReadAllText($skinFile) } else { $null }
    if ("$now" -cne "$($prev.skins)") {
      if ($null -ne $prev.skins -and "$($prev.skins)") { [IO.File]::WriteAllText($skinFile, "$($prev.skins)", (New-Object Text.UTF8Encoding $true)) }   # Tools > Themes writes it with a BOM too
      else { Remove-Item -LiteralPath $skinFile -Force -ErrorAction SilentlyContinue }
      $skinsChanged = $true; $did += 'style (skins.json) restored'
    }
  } else { $lay = $null; $did += 'pending file unreadable - nothing restored (Tools > Reset theme puts ArcadeMaster back)' }
  Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
  if (-not $NoArt -and $lay) { try { Update-AmThemeArt $RetroFE $ManifestDir $lay $skinsChanged } catch { } }
  $msg = "theme '$(if ($p) { $p.choice })' not kept ($Why) - back to: $(if ($did) { $did -join ', ' } else { 'nothing had changed' })"
  Write-AmLauncherLog $RetroFE $msg
  return $msg
}

function Reset-AmTheme([string]$RetroFE, [string]$ManifestDir, [switch]$NoArt) {
  $sc = Join-Path $RetroFE 'settings.conf'; $did = @()
  if (-not (Test-Path (Join-Path $RetroFE 'layouts\ArcadeMaster\layout.xml'))) { throw "layouts\ArcadeMaster is not installed in $RetroFE" }
  if (Set-AmConf $sc 'layout' 'ArcadeMaster') { $did += 'layout = ArcadeMaster' }
  $keys = @([regex]::Matches((Read-AmText $sc).text, '(?m)^[ \t]*(cabinetTheme\.[\w+]+)[ \t]*=') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
  foreach ($k in $keys) { if (Remove-AmConfKey $sc $k) { $did += "$k removed" } }
  $skinFile = Join-Path $ManifestDir 'skins.json'
  if (Test-Path -LiteralPath $skinFile) { Backup-AmFileOnce $skinFile; Remove-Item -LiteralPath $skinFile -Force; $did += 'style back to the original (skins.json removed, copy in skins.json.am-bak)' }
  $pf = Get-AmPendingPath $ManifestDir; if (Test-Path -LiteralPath $pf) { Remove-Item -LiteralPath $pf -Force; $did += 'waiting theme change cleared' }
  if (-not $NoArt) { try { Update-AmThemeArt $RetroFE $ManifestDir 'ArcadeMaster' $true } catch { } }
  $msg = "theme reset: $(if ($did) { $did -join ', ' } else { 'already ArcadeMaster with the original style' })"
  Write-AmLauncherLog $RetroFE $msg
  return $msg
}
