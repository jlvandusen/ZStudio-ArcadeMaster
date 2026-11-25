<#
.SYNOPSIS
  Applies manifest\ui.json (Tools > Cabinet Settings) to the ArcadeMaster layout of one frontend:
    story         the game story panel (glass panel + scrolling text over the video)     layout.xml
    controlHints  the special-control reminder (trackball / spinner / gun / wheel / 4-way) layout.xml
    menuSounds    select / highlight / load sounds                                         layout.xml, Main, Tools
    videoVolume   100 / 50 / 25 / 0: the preview video's volume ("volume" attribute)      layout.xml

  How: RetroFE reads no runtime flags, so the layout itself changes. The repo's layouts mark each optional part with
  <!--am-ui:NAME--> ... <!--/am-ui:NAME-->. Switching a part off wraps what is between the markers in a comment
  (<!--am-ui-off ... am-ui-off-->); switching it on unwraps it. Nothing else in the file changes, the edit can be
  repeated any number of times, and a frontend copy made before the markers existed gets them added around the very
  same elements (exact text match with the repo copy) - a layout someone edited by hand is left alone with a warning.
  Each file is backed up once next to itself (layout.xml.am-bak). Runs after every change and at boot (an updated
  layout copied over from the repo gets the cabinet's choices back).
.EXAMPLE
  Set-LayoutUi.ps1 -RetroFE R:\ArcadeMaster\frontend\LEGENDS-am -ManifestDir R:\ArcadeMaster\manifest
#>
param(
  [string]$RetroFE = 'D:\ArcadeMaster\frontend\DRIVE-coinops',
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$Layout = 'ArcadeMaster'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\AmSettings.ps1')
$ui = Read-AmUi $ManifestDir
$want = @{ story = [bool]$ui.story; controlHints = [bool]$ui.controlHints; menuSounds = [bool]$ui.menuSounds }
$vol = [Math]::Max(0, [Math]::Min(100, [int]$ui.videoVolume))
$srcRoot = Join-Path (Split-Path $PSScriptRoot) "layouts\$Layout"
$dstRoot = Join-Path $RetroFE "layouts\$Layout"
$blockPat = '(?s)<!--am-ui:(\w+)-->(.*?)<!--/am-ui:\1-->'
function Unwrap([string]$s) { if ($s.StartsWith('<!--am-ui-off') -and $s.EndsWith('am-ui-off-->')) { return $s.Substring(13, $s.Length - 25) }; return $s }

$changed = 0
foreach ($rel in 'layout.xml', 'collections\Main\layout\layout.xml', 'collections\Tools\layout\layout.xml') {
  $dst = Join-Path $dstRoot $rel; if (-not (Test-Path -LiteralPath $dst)) { continue }
  $r = Read-AmText $dst; $text = $r.text

  # 1. markers the frontend copy does not have yet: put them around the same elements the repo copy marks
  $src = Join-Path $srcRoot $rel
  if ((Test-Path -LiteralPath $src) -and ((Resolve-Path -LiteralPath $src).Path -ne (Resolve-Path -LiteralPath $dst).Path)) {
    foreach ($m in [regex]::Matches((Read-AmText $src).text, $blockPat)) {
      $name = $m.Groups[1].Value; if ($text.Contains("<!--am-ui:$name-->")) { continue }
      $inner = (Unwrap $m.Groups[2].Value).Trim(); $found = $null
      foreach ($v in @($inner, ($inner -replace "`r`n", "`n"), ($inner -replace "(?<!`r)`n", "`r`n")) | Select-Object -Unique) {
        $at = $text.IndexOf($v, [StringComparison]::Ordinal)
        if ($at -ge 0 -and $text.IndexOf($v, $at + 1, [StringComparison]::Ordinal) -lt 0) { $found = $v; break }
      }
      if ($found) { $text = $text.Replace($found, "<!--am-ui:$name-->$found<!--/am-ui:$name-->") }
      else { Write-Warning "$rel differs from the repo copy around '$name' - that part is left as it is" }
    }
  }

  # 2. each marked part on or off
  $sb = New-Object Text.StringBuilder; $last = 0
  foreach ($m in [regex]::Matches($text, $blockPat)) {
    [void]$sb.Append($text, $last, $m.Index - $last); $last = $m.Index + $m.Length
    $name = $m.Groups[1].Value; $raw = Unwrap $m.Groups[2].Value
    if (-not $want.ContainsKey($name) -or $raw.Contains('--')) {
      if ($raw.Contains('--')) { Write-Warning "$rel '$name' contains a comment - cannot switch it" }
      [void]$sb.Append($m.Value); continue
    }
    $body = if ($want[$name]) { $raw } else { "<!--am-ui-off$($raw)am-ui-off-->" }
    [void]$sb.Append("<!--am-ui:$name-->$body<!--/am-ui:$name-->")
  }
  [void]$sb.Append($text, $last, $text.Length - $last); $text = $sb.ToString()

  # 3. preview video volume (game list only): no attribute = RetroFE's full volume
  if ($rel -eq 'layout.xml') {
    $text = [regex]::Replace($text, '<reloadableVideo\b[^>]*\btype="am_video"[^>]*>', {
        param($m) $tag = $m.Value -replace '\s+volume="[^"]*"', ''
        if ($vol -lt 100) { $tag = $tag -replace '^<reloadableVideo', ('<reloadableVideo volume="{0}"' -f ($vol / 100).ToString([Globalization.CultureInfo]::InvariantCulture)) }
        $tag }.GetNewClosure())
  }

  if ($text -cne $r.text) {
    # never write a file RetroFE could not read
    try { $x = New-Object Xml.XmlDocument; $x.LoadXml($text) } catch { Write-Warning "$rel would not be valid XML ($($_.Exception.Message)) - not changed"; continue }
    Backup-AmFileOnce $dst; Write-AmText $dst $text $r.bom; $changed++
    Write-Host "updated $rel"
  }
}
Write-Host ("layout options: story {0}, control reminders {1}, menu sounds {2}, video volume {3}% - {4} file(s) changed" -f $(if ($want.story) { 'on' } else { 'off' }), $(if ($want.controlHints) { 'on' } else { 'off' }), $(if ($want.menuSounds) { 'on' } else { 'off' }), $vol, $changed)
