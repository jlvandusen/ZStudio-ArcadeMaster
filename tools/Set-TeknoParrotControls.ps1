<#
.SYNOPSIS
  Binds a cabinet's TeknoParrot games to its own devices: tools\teknoparrot-controls.<COMPUTERNAME>.json says, per game
  profile and button name, which device (by a piece of its Windows device path) and which key / mouse button. Written
  into UserProfiles\<game>.xml of every TeknoParrot copy under the frontend's emulators folder (Teknoparrot,
  Teknoparrot_Subscribed ...) that has the profile, in TeknoParrot's own RawInput form. Each profile is backed up once
  as <game>.xml.am-bak. Never touches a protected live frontend.
.EXAMPLE
  tools\Set-TeknoParrotControls.ps1 -RetroFE D:\ArcadeMaster\frontend\CORE-am            # dry run
  tools\Set-TeknoParrotControls.ps1 -RetroFE D:\ArcadeMaster\frontend\CORE-am -Apply
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$Map,                        # default tools\teknoparrot-controls.<COMPUTERNAME>.json
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
if (-not $Map) { $Map = Join-Path $PSScriptRoot "teknoparrot-controls.$env:COMPUTERNAME.json" }
if (-not (Test-Path $Map)) { Write-Host "no $Map - nothing to bind on this cabinet"; return }
. (Join-Path $PSScriptRoot 'lib\AmPython.ps1'); $py = Find-AmPython
if ($py) {
  $prot = & $py -c "import sys; sys.path.insert(0, r'$PSScriptRoot\lib'); from am_guard import is_protected; print(is_protected(r'$RetroFE'))" 2>$null
  if ("$prot".Trim() -eq 'True') { throw "$RetroFE is a protected live frontend - refusing" }
}
$cfg = Get-Content $Map -Raw | ConvertFrom-Json

# the devices as Windows' raw input names them (TeknoParrot matches DevicePath exactly)
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class AmRawList {
  [StructLayout(LayoutKind.Sequential)] struct L { public IntPtr h; public uint t; }
  [DllImport("user32.dll")] static extern uint GetRawInputDeviceList([Out] L[] l, ref uint n, uint s);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint GetRawInputDeviceInfo(IntPtr h, uint c, System.Text.StringBuilder d, ref uint s);
  public static List<string> Names() {
    uint n = 0, s = (uint)Marshal.SizeOf(typeof(L)); GetRawInputDeviceList(null, ref n, s); var a = new L[n]; GetRawInputDeviceList(a, ref n, s);
    var o = new List<string>();
    foreach (var d in a) { uint z = 0; GetRawInputDeviceInfo(d.h, 0x20000007, null, ref z); var b = new System.Text.StringBuilder((int)z + 1); GetRawInputDeviceInfo(d.h, 0x20000007, b, ref z); o.Add(d.t + "|" + b.ToString()); }
    return o;
  }
}
'@
$raw = [AmRawList]::Names()
$dev = @{}
foreach ($p in $cfg._devices.PSObject.Properties) {
  $hit = $raw | Where-Object { $_ -like "*$($p.Value)#*" } | Select-Object -First 1
  if ($hit) { $t, $path = $hit -split '\|', 2; $dev[$p.Name] = @{ path = $path; type = $(if ($t -eq '0') { 'Mouse' } else { 'Keyboard' }) } }
  else { Write-Warning "$($p.Name) ($($p.Value)) is not connected - its buttons are left as they are" }
}

function Set-Binding($x, $jb, $d, [string]$dn, [string]$what) {
  $ri = $jb.SelectSingleNode('RawInputButton')
  if (-not $ri) { $ri = $x.CreateElement('RawInputButton'); [void]$jb.InsertAfter($ri, $jb.SelectSingleNode('ButtonName')) }
  $ri.RemoveAll()
  $isMouse = $d.type -eq 'Mouse'
  foreach ($kv in @(@('DevicePath', $d.path), @('DeviceType', $d.type),
                    @('MouseButton', $(if ($isMouse -and $what -ne 'gun') { $what } else { 'None' })),
                    @('KeyboardKey', $(if ($isMouse) { 'None' } else { $what })))) {
    $e = $x.CreateElement($kv[0]); $e.InnerText = $kv[1]; [void]$ri.AppendChild($e)
  }
  $label = "$dn $(if ($what -eq 'gun') { 'aim' } else { $what })"
  foreach ($tag in 'BindNameRi', 'BindName') { $e = $jb.SelectSingleNode($tag); if (-not $e) { $e = $x.CreateElement($tag); [void]$jb.AppendChild($e) }; $e.InnerText = $label }
  return $label
}
# not bound yet: no device, or TeknoParrot's empty binding
function Test-Unbound($jb) { if ("$($jb.BindNameRi)".Trim()) { return $false }; $ri = $jb.SelectSingleNode('RawInputButton'); if (-not $ri) { return $true }; return ("$($ri.DevicePath)" -in @('', 'null')) -and ("$($ri.KeyboardKey)" -in @('', 'None')) -and ("$($ri.MouseButton)" -in @('', 'None')) }

$tps = @(Get-ChildItem (Join-Path $RetroFE 'emulators') -Directory | Where-Object { $_.Name -match '^(?i)teknoparrot' -and $_.Name -notmatch 'am-prev' -and (Test-Path (Join-Path $_.FullName 'UserProfiles')) })
# every RawInput gun game: its guns' aim and triggers, start and coin, where nothing is bound yet (James 2026-11-27:
# half the TeknoParrot gun games had no gun bound). Player n = gun n; start / coin = the panel's own keys.
if ($cfg._autoGuns) {
  $auto = @{ start = @('D1', 'D2', 'D3', 'D4'); coin = @('D5', 'D6', 'D7', 'D8') }
  foreach ($tp in $tps) {
    foreach ($f in Get-ChildItem (Join-Path $tp.FullName 'UserProfiles') -Filter *.xml) {
      if ($cfg.PSObject.Properties[$f.BaseName]) { continue }   # the per-game list handles it
      try { [xml]$x = Get-Content $f.FullName -Raw } catch { continue }
      $api = ($x.GameProfile.ConfigValues.FieldInformation | Where-Object FieldName -eq 'Input API').FieldValue
      $bs = @($x.GameProfile.JoystickButtons.JoystickButtons)
      if ($api -ne 'RawInput' -or -not ($bs | Where-Object { $_.InputMapping -match 'LightGun' -and $_.ButtonName -match '(?i)gun' })) { continue }   # a real gun game
      $n = 0
      foreach ($jb in $bs) {
        if (-not (Test-Unbound $jb)) { continue }
        $m = "$($jb.InputMapping)"; $dn = $null; $what = $null
        $bn = "$($jb.ButtonName)"
        # aim only on a control that says it is a gun (Winning Eleven 08 uses the light-gun slots for its pad's sticks);
        # the main trigger only, never a "sub" trigger
        if ($m -match '^P([1-4])ButtonStart$') { $pl = $Matches[1]; if ($bn -match '(?i)start|credit') { $dn = 'panel'; $what = $auto.start[[int]$pl - 1] } }
        elseif ($m -match '^Coin([1-4])$') { $pl = $Matches[1]; if ($bn -match '(?i)coin|credit') { $dn = 'panel'; $what = $auto.coin[[int]$pl - 1] } }   # GoGoStrike's Setup sits on Coin1
        elseif ($m -match '^P([12])LightGun$') { $pl = $Matches[1]; if ($bn -match '(?i)gun') { $dn = "gun$pl"; $what = 'gun' } }
        elseif ($m -match '^P([12])Button') { $pl = $Matches[1]; if ($bn -match '(?i)trigger' -and $bn -notmatch '(?i)sub') { $dn = "gun$pl"; $what = $(if ($bn -match '(?i)right') { 'RightButton' } else { 'LeftButton' }) } }   # Drakons: left / right trigger
        if (-not $dn -or -not $dev.ContainsKey($dn)) { continue }
        $label = Set-Binding $x $jb $dev[$dn] $dn $what; $n++
        Write-Host ("  {0,-22} {1,-26} = {2}" -f $f.BaseName, $jb.ButtonName, $label)
      }
      if ($Apply -and $n) { if (-not (Test-Path "$($f.FullName).am-bak")) { Copy-Item $f.FullName "$($f.FullName).am-bak" }; $x.Save($f.FullName); Write-Host "$($f.BaseName): $n filled -> $($f.FullName)" }
      elseif ($n) { Write-Host "$($f.BaseName): $n would be filled (dry run) -> $($f.FullName)" }
    }
  }
}

foreach ($game in $cfg.PSObject.Properties | Where-Object { $_.Name -notlike '_*' }) {
  foreach ($tp in $tps) {
    $f = Join-Path $tp.FullName "UserProfiles\$($game.Name).xml"
    if (-not (Test-Path $f)) { continue }
    [xml]$x = Get-Content $f -Raw
    $n = 0
    foreach ($b in $game.Value.PSObject.Properties) {
      $dn, $what = $b.Value
      if (-not $dev.ContainsKey($dn)) { continue }
      $d = $dev[$dn]
      $jb = $x.GameProfile.JoystickButtons.JoystickButtons | Where-Object { $_.ButtonName -eq $b.Name } | Select-Object -First 1
      if (-not $jb) { Write-Warning "$($game.Name): no button '$($b.Name)'"; continue }
      $label = Set-Binding $x $jb $d $dn $what
      $n++
      Write-Host ("  {0,-8} {1,-22} = {2}" -f $game.Name, $b.Name, $label)
    }
    if ($Apply -and $n) {
      if (-not (Test-Path "$f.am-bak")) { Copy-Item $f "$f.am-bak" }
      $x.Save($f)   # keeps the file's own declaration and encoding (TeknoParrot reads it with .NET's XmlSerializer)
      Write-Host "$($game.Name): $n button(s) written -> $f"
    } elseif ($n) { Write-Host "$($game.Name): $n button(s) (dry run - add -Apply) -> $f" }
  }
}
