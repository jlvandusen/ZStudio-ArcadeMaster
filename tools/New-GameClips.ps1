<#
.SYNOPSIS
  Menu videos from the games' own movies: for every entry in catalog\art-aliases.json "clips"
  ({ "<collection>/<item>": { "from": "<the game's movie>", "start": <seconds> } }) it makes a 45 s, 1280x720 H.264 MP4
  in <ClipsDir>\<collection>\<item>.mp4. New-RetroFECollections.ps1 links that clip in as the game's video at every
  rebuild; New-PreviewMedia.py then makes its light preview. The game's own files are only read.
  Skips a clip that is newer than its source; a source not on this cabinet is skipped. Reads Bink, CRI USM, WMV, AVI, MP4.
.EXAMPLE
  tools\New-GameClips.ps1
  tools\New-GameClips.ps1 -Force          # make every clip again
#>
param(
  [string]$Catalog,
  [string]$ClipsDir = 'D:\ArcadeMaster\media\clips',
  [string]$FFmpeg = 'D:\ArcadeMaster\_tools\ffmpeg\ffmpeg.exe',
  [int]$Seconds = 45,
  [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $Catalog) { $Catalog = Join-Path (Split-Path $PSScriptRoot) 'catalog\art-aliases.json' }
if (-not (Test-Path $FFmpeg)) { $c = Get-Command ffmpeg -ErrorAction SilentlyContinue; if ($c) { $FFmpeg = $c.Source } else { throw "ffmpeg not found ($FFmpeg)" } }
$clips = (Get-Content $Catalog -Raw | ConvertFrom-Json).clips
if (-not $clips) { Write-Host 'no clips in the catalog'; return }
$made = 0; $same = 0; $missing = 0; $failed = 0
# NVENC when the graphics card has it, else the CPU encoder
$enc = if ((& $FFmpeg -hide_banner -encoders 2>$null) -match 'h264_nvenc') { @('-c:v', 'h264_nvenc', '-preset', 'p5', '-b:v', '4M') } else { @('-c:v', 'libx264', '-preset', 'veryfast', '-crf', '22') }
foreach ($e in $clips.PSObject.Properties) {
  $col, $item = $e.Name -split '/', 2
  $src = [string]$e.Value.from; $start = [double]("0" + $e.Value.start)
  if (-not (Test-Path -LiteralPath $src)) { $missing++; continue }
  $dst = Join-Path $ClipsDir "$col\$item.mp4"
  if (-not $Force -and (Test-Path -LiteralPath $dst) -and (Get-Item -LiteralPath $dst).LastWriteTime -gt (Get-Item -LiteralPath $src).LastWriteTime) { $same++; continue }
  New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
  $part = "$dst.part.mp4"
  $ffArgs = @('-hide_banner', '-loglevel', 'error', '-y', '-ss', "$start", '-i', $src, '-t', "$Seconds", '-vf', 'scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2,fps=30', '-pix_fmt', 'yuv420p') + $enc + @('-c:a', 'aac', '-b:a', '128k', '-ac', '2', '-movflags', '+faststart', $part)
  # ffmpeg writes warnings to stderr; under 'Stop' Windows PowerShell 5.1 turns that into a fatal error - judge by the file
  $ErrorActionPreference = 'Continue'; & $FFmpeg @ffArgs 2>&1 | Select-Object -Last 3 | ForEach-Object { Write-Host "  $_" }; $ffExit = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
  if ($ffExit -or -not (Test-Path -LiteralPath $part) -or (Get-Item -LiteralPath $part).Length -lt 100KB) {
    # a movie whose sound ffmpeg cannot decode (After Burner Climax's ADX audio): try again without sound
    $noSound = @($ffArgs | Where-Object { $_ -notin '-c:a', 'aac', '-b:a', '128k', '-ac', '2' }); $noSound = $noSound[0..($noSound.Count - 2)] + @('-an', $part)
    Remove-Item -LiteralPath $part -ErrorAction SilentlyContinue
    $ErrorActionPreference = 'Continue'; & $FFmpeg @noSound 2>&1 | Select-Object -Last 2 | ForEach-Object { Write-Host "  $_" }; $ffExit = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
    if (-not $ffExit -and (Test-Path -LiteralPath $part) -and (Get-Item -LiteralPath $part).Length -ge 100KB) { Write-Host "  (made without sound: the movie's audio could not be read)" }
  }
  if ($ffExit -or -not (Test-Path -LiteralPath $part) -or (Get-Item -LiteralPath $part).Length -lt 100KB) { Write-Host "FAILED $($e.Name) from $src"; Remove-Item -LiteralPath $part -ErrorAction SilentlyContinue; $failed++; continue }
  Move-Item -LiteralPath $part $dst -Force
  Write-Host ("made {0} ({1:N1} MB) from {2}" -f $e.Name, ((Get-Item -LiteralPath $dst).Length / 1MB), (Split-Path $src -Leaf))
  $made++
}
Write-Host "clips: $made made, $same up to date, $missing source not on this cabinet, $failed failed -> $ClipsDir"
