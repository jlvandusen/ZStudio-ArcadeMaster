<#
.SYNOPSIS
  Sets a game up in TeknoParrot, as TeknoParrotUI's "add game" does, with the cabinet's controls already bound.

  1. the controls: WheelMap -Generate builds the game's profile from TeknoParrot's GameProfiles\<Id>.xml with this
     cabinet's wheel / pedals / buttons bound (pedals: clutch LEFT, brake MIDDLE, gas RIGHT). If the generator has
     nothing for the game, TeknoParrot's own GameProfile is used with no controls bound (bind them in TeknoParrotUI).
  2. the game: <GamePath> set to -GamePath. Windows games point at their .exe; Linux-based boards (Lindbergh, Nu,
     some Raw Thrills) point at their Linux program file (.elf or no extension) - both are accepted.
  3. written to <TpDir>\UserProfiles\<Id>.xml. Never replaces an existing profile. Dry run unless -Apply.
  Afterwards run Tools > Rebuild Game Menus so the game shows up.
.EXAMPLE
  tools\Add-TPGame.ps1 -Id VirtuaRLimit -GamePath 'D:\Arcade PC\Taito Type X\Valve Limit R\Game.exe'
  tools\Add-TPGame.ps1 -Id VirtuaRLimit -GamePath 'D:\Arcade PC\Taito Type X\Valve Limit R\Game.exe' -Apply
#>
param(
  [Parameter(Mandatory)][string]$Id,
  [Parameter(Mandatory)][string]$GamePath,
  [string]$TpDir = 'D:\Emulators\TeknoParrot',
  [string]$Controller = 'G29',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$dst = Join-Path $TpDir "UserProfiles\$Id.xml"
$tmpl = Join-Path $TpDir "GameProfiles\$Id.xml"
if (Test-Path -LiteralPath $dst) { Write-Host "already set up: $dst (not replaced)"; exit 1 }
if (-not (Test-Path -LiteralPath $tmpl)) { Write-Host "TeknoParrot has no game called '$Id' ($tmpl missing)"; exit 1 }
if (-not (Test-Path -LiteralPath $GamePath -PathType Leaf)) { Write-Host "game file not found: $GamePath"; exit 1 }

# a program file: Windows .exe, or a Linux ELF (starts with 0x7F 'ELF')
$kind = if ($GamePath -match '(?i)\.exe$') { 'Windows program' } else {
  $fs = [IO.File]::OpenRead($GamePath); $b = New-Object byte[] 4; [void]$fs.Read($b, 0, 4); $fs.Close()
  if ($b[0] -eq 0x7F -and $b[1] -eq 0x45 -and $b[2] -eq 0x4C -and $b[3] -eq 0x46) { 'Linux program' } else { $null } }
if (-not $kind) { Write-Host "not a program file (neither .exe nor Linux): $GamePath"; exit 1 }

# controls from the wheel tool (it writes to its staging folder only)
$text = $null; $how = ''
try {
  & (Join-Path $PSScriptRoot 'wheelmap\WheelMap.ps1') -Generate -Name $Controller -Emulators teknoparrot -Games @($Id) *>&1 | Out-Null
  $man = Get-Content "D:\ArcadeMaster\_staging\inputmap\$Controller\manifest.json" -Raw | ConvertFrom-Json
  $st = @(@(if ($man.files) { $man.files } else { $man }) | Where-Object { $_.staged -match "\\UserProfiles\\$([regex]::Escape($Id))\.xml$" })[0].staged
  if ($st -and (Test-Path -LiteralPath $st)) { $text = [IO.File]::ReadAllText($st); $how = "controls bound for the $Controller by the wheel tool" }
} catch { Write-Host "wheel tool: $($_.Exception.Message)" }
if (-not $text) { $text = [IO.File]::ReadAllText($tmpl); $how = 'no controls bound (the wheel tool had nothing for this game) - bind them in TeknoParrotUI' }

$esc = [Security.SecurityElement]::Escape($GamePath)
if ($text -match '<GamePath\s*/>') { $text = [regex]::Replace($text, '<GamePath\s*/>', "<GamePath>$esc</GamePath>", 1) }
elseif ($text -match '<GamePath>') { $text = [regex]::Replace($text, '<GamePath>.*?</GamePath>', "<GamePath>$esc</GamePath>", 1) }
else { $text = $text -replace '(<GameProfile[^>]*>)', "`$1`r`n  <GamePath>$esc</GamePath>" }
[xml]$check = $text   # must still be valid XML
$binds = @($check.GameProfile.JoystickButtons.JoystickButtons | Where-Object { $_.BindNameDi }).Count

Write-Host "$Id ($($check.GameProfile.GameName)): $kind $GamePath"
Write-Host "  $how ($binds controls bound)"
Write-Host "  -> $dst"
if (-not $Apply) { Write-Host 'dry run - add -Apply to write it'; exit 0 }
[IO.File]::WriteAllText($dst, $text, (New-Object Text.UTF8Encoding $false))
Write-Host 'set up. Run Tools > Rebuild Game Menus so it shows in the menus.'
