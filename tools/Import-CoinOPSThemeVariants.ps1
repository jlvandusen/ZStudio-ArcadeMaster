<#
.SYNOPSIS
  Turns a CoinOPS build's ".bat" theme switchers (the "- Themes" folder: "LEGENDS Poster Theme.bat" ...) into real
  ArcadeMaster themes. A CoinOPS switcher rewrites ONE layout in place (copies e.g. CoinOPSPoster.xml over
  layouts\Arcades\layout.xml and a 2ndMONITORS\<variant> second-screen layout over it). This script instead makes one
  layout folder per style, layouts\<Prefix><Build>-<Style>, a copy of the base layout with that style's layout.xml and
  second-screen layout, and registers it with Import-RetroFETheme. Tools > Themes and the Stream Deck can then switch
  styles like any other theme, and nothing is rewritten in place.
  The extra files a switcher copies outside the layout (mame.ini aspect, controls.conf rotation, settingsN.conf) are
  recorded in <ManifestDir>\theme-variants.json per theme (key 'sideEffects') but NOT applied: they change emulator and
  control behaviour for every game and need their own switch.
  Read-only on the source; existing variant folders are skipped unless -Force.
.EXAMPLE
  tools\Import-CoinOPSThemeVariants.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest
  tools\Import-CoinOPSThemeVariants.ps1 -RetroFE ... -ManifestDir ... -SecondScreen Fanart -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][string]$RetroFE,                 # the RetroFE root that holds layouts\ and the "- Themes" folders
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$ThemesDir,                                    # default: <RetroFE>\- Themes
  [ValidateSet('Default', 'Fanart', 'Aspect Correct', 'Fit to Screen')][string]$SecondScreen = 'Fanart',
  [string]$Prefix = 'CO-',
  [switch]$Force,
  [switch]$NoRegister
)
$ErrorActionPreference = 'Stop'
if (-not $ThemesDir) { $ThemesDir = Join-Path $RetroFE '- Themes' }
$marqueeDir = Join-Path $RetroFE '- Themes (2nd Screen Marquee)'
if (-not (Test-Path -LiteralPath $ThemesDir)) { throw "no theme switchers at $ThemesDir" }
$layouts = Join-Path $RetroFE 'layouts'

# parse one switcher: which layout it rewrites, which xml becomes layout.xml, which 2nd-screen variant, side effects
function Read-Switcher([string]$bat) {
  $r = [ordered]@{ base = $null; xml = $null; screen2 = $null; sideEffects = @() }
  foreach ($ln in Get-Content -LiteralPath $bat) {
    $l = $ln.Trim()
    if ($l -match '^copy\s+\.\.\\layouts\\([^\\]+)\\([^\\\s]+\.xml)\s+\S*\\layouts\\\1\\layout\.xml') { $r.base = $Matches[1]; $r.xml = $Matches[2]; continue }
    if ($l -match '^xcopy\s+\.\.\\layouts\\([^\\]+)\\2ndMONITORS\\(\S+)\s') { if (-not $r.base) { $r.base = $Matches[1] }; $r.screen2 = $Matches[2]; continue }
    if ($l -match '^(x?copy)\s+(\S+)\s+(\S+)') { $r.sideEffects += ($Matches[2] + ' -> ' + $Matches[3]) }
  }
  return $r
}

$made = @(); $variants = [ordered]@{}
$vf = Join-Path $ManifestDir 'theme-variants.json'
if (Test-Path $vf) { (Get-Content $vf -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $variants[$_.Name] = $_.Value } }

foreach ($bat in Get-ChildItem -LiteralPath $ThemesDir -Filter '*.bat' | Sort-Object Name) {
  $style = ($bat.BaseName -replace '\s+Theme$', '').Trim()
  $sw = Read-Switcher $bat.FullName
  if (-not $sw.base -or -not $sw.xml) { Write-Host "skip  $($bat.Name): no layout.xml swap found"; continue }
  # second-screen choice: the matching "(<SecondScreen>)" switcher in the 2nd Screen Marquee folder, if any
  if ($SecondScreen -ne 'Default') {
    $alt = Join-Path $marqueeDir ("{0} ({1}).bat" -f $bat.BaseName, $SecondScreen)
    if (Test-Path -LiteralPath $alt) { $s2 = (Read-Switcher $alt).screen2; if ($s2) { $sw.screen2 = $s2 } }
  }
  $src = Join-Path $layouts $sw.base
  # short names (the deck shows ~10 characters): CO-Poster, CO-Top-Spin, CO-Cabinet-Wall ...
  $short = (Get-Culture).TextInfo.ToTitleCase((($style -replace '^(LEGENDS|CoinOPS|CORE)\s+', '') -replace '&', '+').ToLower())
  $name = $Prefix + (($short -replace '[^A-Za-z0-9+]+', '-').Trim('-'))
  $dst = Join-Path $layouts $name
  if ((Test-Path -LiteralPath $dst) -and -not $Force) { Write-Host "exists $name"; $made += $name; continue }
  if (-not (Test-Path -LiteralPath (Join-Path $src $sw.xml))) { Write-Host "skip  $($bat.Name): $($sw.xml) missing in $src"; continue }
  if ($PSCmdlet.ShouldProcess($dst, "make theme from $($bat.Name)")) {
    if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
    $null = robocopy $src $dst /E /XD 2ndMONITORS /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -ge 8) { throw "robocopy $src -> $dst failed ($LASTEXITCODE)" }
    Copy-Item -LiteralPath (Join-Path $src $sw.xml) (Join-Path $dst 'layout.xml') -Force
    if ($sw.screen2) {
      $s2dir = Join-Path $src "2ndMONITORS\$($sw.screen2)"
      if (Test-Path -LiteralPath $s2dir) { Copy-Item (Join-Path $s2dir '*') $dst -Recurse -Force }
    }
    $variants[$name] = [ordered]@{ source = $bat.FullName; base = $sw.base; layoutXml = $sw.xml; secondScreen = $sw.screen2; sideEffects = $sw.sideEffects; made = (Get-Date).ToString('s') }
    Write-Host ("made  {0,-38} {1} + {2}" -f $name, $sw.xml, $(if ($sw.screen2) { $sw.screen2 } else { 'base 2nd screen' }))
    $made += $name
  }
}
if (-not $WhatIfPreference) {
  New-Item -ItemType Directory -Force $ManifestDir | Out-Null
  $variants | ConvertTo-Json -Depth 5 | Set-Content $vf -Encoding UTF8
  Write-Host "variants: $vf ($($variants.Count))"
  if ($made -and -not $NoRegister) {
    & (Join-Path $PSScriptRoot 'Import-RetroFETheme.ps1') -Source $RetroFE -Layout $made -RetroFE $RetroFE -ManifestDir $ManifestDir
  }
}
