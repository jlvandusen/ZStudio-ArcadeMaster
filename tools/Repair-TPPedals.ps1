<#
.SYNOPSIS
  Puts the brake back on the brake pedal in TeknoParrot profiles that bound it to the clutch.

  A Logitech G29 / G920 reports its pedals as: gas = Y axis, brake = RotationZ, clutch = Slider 0
  (pedals are always clutch LEFT, brake MIDDLE, gas RIGHT). Some profiles (Initial D 5/7/8/Zero, GRID, KODrive ...)
  had Brake on Slider 0, so pressing the brake did nothing and the clutch braked.

  Only profiles where Gas is on the same wheel's Y axis are touched (the Logitech pedal layout), and only the Brake
  and Clutch entries change: Brake Slider0 -> RotationZ, Clutch RotationZ -> Slider0. Everything else stays as it is.
  Dry run by default; -Apply backs up UserProfiles first (same as Repair-TPProfiles.ps1).
.EXAMPLE
  tools\Repair-TPPedals.ps1                    # list what is wrong
  tools\Repair-TPPedals.ps1 -Apply             # back up, then fix
#>
param(
  [string[]]$TpDir = @('D:\Emulators\TeknoParrot'),
  [string]$BackupRoot = 'D:\ArcadeMaster\_backup',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
# SharpDX JoystickOffset of each axis = the <Button> number TeknoParrot stores for it
$axis = @{ Y = 4; RotationZ = 20; Sliders0 = 24 }
$want = @{ Brake = @{ From = 'Sliders0'; To = 'RotationZ' }; Clutch = @{ From = 'RotationZ'; To = 'Sliders0' } }

function Get-Field([string]$block, [string]$name) { $m = [regex]::Match($block, "<$name>(.*?)</$name>"); if ($m.Success) { $m.Groups[1].Value } }

$fixes = foreach ($tp in $TpDir) {
  foreach ($f in Get-ChildItem (Join-Path $tp 'UserProfiles') -Filter *.xml -ErrorAction SilentlyContinue) {
    $text = [IO.File]::ReadAllText($f.FullName)
    $blocks = [regex]::Matches($text, '(?s)<JoystickButtons>\s*<ButtonName>[^<]*</ButtonName>.*?</JoystickButtons>')
    $gas = $blocks | Where-Object { (Get-Field $_.Value 'ButtonName') -eq 'Gas' } | Select-Object -First 1
    if (-not $gas -or (Get-Field $gas.Value 'Button') -ne "$($axis.Y)" -or (Get-Field $gas.Value 'IsAxis') -ne 'true') { continue }   # not the Logitech pedal layout
    $guid = Get-Field $gas.Value 'JoystickGuid'
    $changes = @()
    foreach ($b in $blocks) {
      $name = Get-Field $b.Value 'ButtonName'; if (-not $want.ContainsKey($name)) { continue }
      $w = $want[$name]
      if ((Get-Field $b.Value 'JoystickGuid') -ne $guid -or (Get-Field $b.Value 'Button') -ne "$($axis[$w.From])") { continue }
      $new = $b.Value -replace "<Button>$($axis[$w.From])</Button>", "<Button>$($axis[$w.To])</Button>"
      $new = $new -replace "(<BindName(Di)?>[^<]*?)\b$($w.From)\b", "`${1}$($w.To)"
      $changes += @{ Old = $b.Value; New = $new; Say = "$name $($w.From) -> $($w.To)" }
    }
    if ($changes) { [pscustomobject]@{ File = $f.FullName; Game = $f.BaseName; Changes = $changes } }
  }
}

if (-not $fixes) { Write-Host 'all TeknoParrot pedals are on the right axes'; return }
$fixes | ForEach-Object { Write-Host ("{0,-30} {1}" -f $_.Game, (($_.Changes | ForEach-Object { $_.Say }) -join ', ')) }
Write-Host ("{0} profile(s) with the brake or clutch on the wrong pedal" -f @($fixes).Count)
if (-not $Apply) { Write-Host 'dry run - add -Apply to fix (UserProfiles is backed up first)'; return }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
foreach ($tp in @($fixes | ForEach-Object { Split-Path (Split-Path $_.File) } | Select-Object -Unique)) {
  $bk = Join-Path $BackupRoot "TP-UserProfiles-$((Split-Path $tp -Leaf) -replace '\W','_')-pedals-$stamp"
  Copy-Item (Join-Path $tp 'UserProfiles') $bk -Recurse
  Write-Host "backup -> $bk"
}
foreach ($x in $fixes) {
  $bytes = [IO.File]::ReadAllBytes($x.File)
  $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  $text = [IO.File]::ReadAllText($x.File)
  foreach ($c in $x.Changes) { $text = $text.Replace($c.Old, $c.New) }
  [xml]$null = $text   # still valid XML, or stop before writing
  [IO.File]::WriteAllText($x.File, $text, (New-Object Text.UTF8Encoding($hasBom)))
  Write-Host "fixed $($x.Game)"
}
