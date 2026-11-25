<#
.SYNOPSIS
  Writes the per-game MAME input mappings of tools\mame-controls.json into a frontend's MAME (cfg\<game>.cfg).
  Only the listed ports are replaced; everything else in the file (other inputs, counters, mixer) is kept. Each
  cfg is backed up once as <game>.cfg.am-bak before the first change. Refuses a protected live frontend.
.EXAMPLE
  tools\Set-MameControls.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am            # dry run: what would change
  tools\Set-MameControls.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -Apply
  tools\Set-MameControls.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -Restore   # put the .am-bak files back
#>
param(
  [Parameter(Mandatory)][string]$RetroFE,
  [string]$Mame,                       # default <RetroFE>\emulators\mame
  [string[]]$Games,                    # default: every game in the json
  [switch]$Apply,
  [switch]$Restore
)
$ErrorActionPreference = 'Stop'
if (-not $Mame) { $Mame = Join-Path $RetroFE 'emulators\mame' }
$cfgDir = Join-Path $Mame 'cfg'
if (-not (Test-Path $cfgDir)) { throw "no MAME cfg folder at $cfgDir" }
. (Join-Path $PSScriptRoot 'lib\AmPython.ps1'); $py = Find-AmPython
if ($py) {
  $prot = & $py -c "import sys; sys.path.insert(0, r'$PSScriptRoot\lib'); from am_guard import is_protected; print(is_protected(r'$cfgDir'))" 2>$null
  if ("$prot".Trim() -eq 'True') { throw "$cfgDir is inside a protected live frontend (ProtectedPaths) - refusing" }
}
$data = Get-Content (Join-Path $PSScriptRoot 'mame-controls.json') -Raw | ConvertFrom-Json
$seqs = @{}; foreach ($p in $data._seq.PSObject.Properties) { $seqs[$p.Name] = $p.Value }
$all = @($data.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { $_.Name })
if (-not $Games) { $Games = $all }
$u8 = New-Object Text.UTF8Encoding $false
foreach ($g in $Games) {
  $f = Join-Path $cfgDir "$g.cfg"; $bak = "$f.am-bak"
  if ($Restore) {
    if (Test-Path $bak) { if ($Apply) { Copy-Item $bak $f -Force }; Write-Host "$g : restored from $bak$(if (-not $Apply) { ' (dry run)' })" }
    elseif (Test-Path $f) { if ($Apply) { Remove-Item $f -Force }; Write-Host "$g : had no cfg before - removed$(if (-not $Apply) { ' (dry run)' })" }
    continue
  }
  $spec = $data.$g; if (-not $spec) { Write-Warning "$g is not in mame-controls.json"; continue }
  if (Test-Path $f) { [xml]$x = Get-Content $f -Raw } else {
    [xml]$x = "<?xml version=`"1.0`"?>`n<mameconfig version=`"10`"><system name=`"$g`"></system></mameconfig>"
  }
  $sys = $x.SelectSingleNode("/mameconfig/system[@name='$g']"); if (-not $sys) { throw "$f has no <system name='$g'>" }
  $inp = $sys.SelectSingleNode('input'); if (-not $inp) { $inp = $x.CreateElement('input'); [void]$sys.PrependChild($inp) }
  $changes = 0
  foreach ($p in $spec.ports) {
    $seq = if ($seqs.ContainsKey($p.seq)) { $seqs[$p.seq] } else { $p.seq }
    foreach ($old in @($inp.SelectNodes("port[@type='$($p.type)']"))) { [void]$inp.RemoveChild($old) }
    $port = $x.CreateElement('port')
    foreach ($a in @(@('tag', $p.tag), @('type', $p.type), @('mask', [string]$p.mask), @('defvalue', [string]$p.defvalue))) { $port.SetAttribute($a[0], $a[1]) }
    $ns = $x.CreateElement('newseq'); $ns.SetAttribute('type', 'standard'); $ns.InnerText = $seq
    [void]$port.AppendChild($ns); [void]$inp.AppendChild($port); $changes++
    Write-Host ("  {0,-10} {1,-24} {2}" -f $g, $p.type, $seq)
  }
  if ($Apply) {
    if ((Test-Path $f) -and -not (Test-Path $bak)) { Copy-Item $f $bak }
    $sw = New-Object IO.StringWriter; $xw = New-Object Xml.XmlTextWriter($sw); $xw.Formatting = 'Indented'; $x.WriteTo($xw); $xw.Flush()
    [IO.File]::WriteAllText($f, $sw.ToString(), $u8)
    Write-Host "$g : $changes input(s) written -> $f"
  } else { Write-Host "$g : $changes input(s) (dry run - add -Apply)" }
}
