<#
.SYNOPSIS
  Encodes the generated neon grid frames (layouts\ArcadeMaster\_gridframes\f000..fNNN.png) into a
  seamless looping H.264 video for the layout background. Uses the GStreamer runtime already
  required by RetroFE (gst-launch-1.0 + x264enc), so no extra tools are needed.
#>
param(
  [string]$GstBin = 'D:\ArcadeMaster\_tools\gstreamer\gstreamer\1.0\msvc_x86_64\bin',
  [string]$FrameDir = (Join-Path $PSScriptRoot '..\layouts\ArcadeMaster\_gridframes'),
  [string]$Out = (Join-Path $PSScriptRoot '..\layouts\ArcadeMaster\video\grid_floor.mp4'),
  [int]$Fps = 30,
  [int]$Repeats = 8        # the loop is ~1.5 s; repeat it so RetroFE restarts the file less often
)
$ErrorActionPreference = 'Stop'
$FrameDir = (Resolve-Path $FrameDir).Path
New-Item -ItemType Directory -Force (Split-Path $Out) | Out-Null
$frames = @(Get-ChildItem $FrameDir -Filter 'f*.png' | Sort-Object Name)
if (-not $frames) { throw "no frames in $FrameDir - run New-LayoutArt.ps1 first" }

# multifilesrc cannot loop a sequence N times, so lay the frames out repeated in a temp dir
$tmp = Join-Path $env:TEMP ("gridseq_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $tmp | Out-Null
try {
  $i = 0
  for ($r = 0; $r -lt $Repeats; $r++) { foreach ($f in $frames) { Copy-Item $f.FullName (Join-Path $tmp ('s{0:D5}.png' -f $i)); $i++ } }
  $loc = (Join-Path $tmp 's%05d.png') -replace '\\', '/'
  $outFwd = ($Out -replace '\\', '/')
  & (Join-Path $GstBin 'gst-launch-1.0.exe') -q -e multifilesrc location="$loc" index=0 stop-index=($i - 1) caps="image/png,framerate=$Fps/1" `
    ! pngdec ! videoconvert ! "video/x-raw,format=I420" ! x264enc bitrate=1500 speed-preset=slow key-int-max=$($frames.Count) `
    ! "video/x-h264,profile=high" ! h264parse ! mp4mux faststart=true ! filesink location="$outFwd"
  if ($LASTEXITCODE -ne 0) { throw "gst-launch failed ($LASTEXITCODE)" }
  Write-Host ("{0}  {1:N1} MB  ({2} frames x {3})" -f $Out, ((Get-Item $Out).Length / 1MB), $frames.Count, $Repeats)
}
finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
