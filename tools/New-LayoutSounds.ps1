<#
.SYNOPSIS
  Synthesises the ArcadeMaster UI sounds (16-bit mono PCM WAV) - original, no samples used.
    highlight.wav  short bright tick (menu scroll)
    select.wav     rising two-tone chirp (enter)
    load.wav       filtered-noise whoosh + rising sweep (game launch)
#>
param([string]$OutDir = (Join-Path $PSScriptRoot '..\layouts\ArcadeMaster\sounds'))
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $OutDir | Out-Null
$rate = 44100

function Write-Wav([string]$path, [double[]]$s) {
  $peak = ($s | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum; if ($peak -lt 1e-9) { $peak = 1 }
  $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
  $data = $s.Count * 2
  $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $data)); $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
  $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]1); $w.Write([int]$rate); $w.Write([int]($rate * 2)); $w.Write([int16]2); $w.Write([int16]16)
  $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]$data)
  foreach ($v in $s) { $w.Write([int16][Math]::Round($v / $peak * 0.8 * 32767)) }
  [IO.File]::WriteAllBytes($path, $ms.ToArray()); $w.Dispose()
  Write-Host ("{0,-14} {1:N0} ms" -f (Split-Path $path -Leaf), ($s.Count * 1000 / $rate))
}
function Env([int]$i, [int]$n, [double]$attack = 0.01) { $t = $i / $n; [Math]::Min(1, $t / $attack) * [Math]::Pow(1 - $t, 2) }

# highlight: 45 ms tick, 2.4 kHz with a fast pitch drop
$n = [int]($rate * 0.045); $s = New-Object double[] $n; $ph = 0
for ($i = 0; $i -lt $n; $i++) { $f = 2400 - 900 * $i / $n; $ph += 2 * [Math]::PI * $f / $rate; $s[$i] = [Math]::Sin($ph) * (Env $i $n 0.02) }
Write-Wav (Join-Path $OutDir 'highlight.wav') $s

# select: two rising square-ish tones (C6 -> G6)
$n = [int]($rate * 0.22); $s = New-Object double[] $n; $ph = 0
for ($i = 0; $i -lt $n; $i++) {
  $f = if ($i -lt $n / 2) { 1046.5 } else { 1568 }; $ph += 2 * [Math]::PI * $f / $rate
  $s[$i] = ([Math]::Sin($ph) + 0.3 * [Math]::Sin(3 * $ph) + 0.15 * [Math]::Sin(5 * $ph)) * (Env $i $n 0.03)
}
Write-Wav (Join-Path $OutDir 'select.wav') $s

# load: 0.9 s whoosh (low-passed noise swelling) under a rising sweep
$n = [int]($rate * 0.9); $s = New-Object double[] $n; $rnd = New-Object Random 5; $lp = 0; $ph = 0
for ($i = 0; $i -lt $n; $i++) {
  $t = $i / $n; $alpha = 0.02 + 0.25 * $t; $lp += $alpha * ($rnd.NextDouble() * 2 - 1 - $lp)
  $f = 180 + 1400 * $t * $t; $ph += 2 * [Math]::PI * $f / $rate
  $env = [Math]::Sin([Math]::PI * [Math]::Min(1, $t * 1.15))
  $s[$i] = ($lp * 2.2 + 0.35 * [Math]::Sin($ph)) * $env
}
Write-Wav (Join-Path $OutDir 'load.wav') $s
