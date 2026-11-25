<#
.SYNOPSIS
  Repairs broken <GamePath> entries in a TeknoParrot UserProfiles folder.
  Dry run by default; -Apply backs up UserProfiles first, then edits only the GamePath line.
  Resolution order for a broken path:
    1. same profile in each -HintDirs install, if its GamePath exists
    1b. where the catalog found the game (-Catalog games.json: "foundAt", written by lib\AmGameDoctor.ps1)
    2. remap rules (old relative/absent roots -> real roots), preferring SSD (D:) copies
    3. search for the exe file name under the candidate game folders
#>
param(
  [string]$TpDir = 'D:\Emulators\TeknoParrot',
  [string[]]$HintDirs = @('D:\Emulators\TeknoParrot - Copy', 'E:\DRIVE Collection\emulators\TeknoParrot'),
  [string]$BackupRoot = 'D:\ArcadeMaster\_backup',
  [string]$Catalog,                 # games.json: profile id -> where the catalog found the game's program file
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'lib\AmGameDoctor.ps1')   # Test-AmSameGamePath
$foundAt = @{}
if ($Catalog -and (Test-Path -LiteralPath $Catalog)) {
  foreach ($g in (Get-Content -LiteralPath $Catalog -Raw | ConvertFrom-Json).games) {
    foreach ($vp in $g.variants.PSObject.Properties) {
      $v = $vp.Value
      if ($v.emulator -eq 'teknoparrot' -and $v.profile -and $v.foundAt -and -not $foundAt.ContainsKey([string]$v.profile) -and (Test-Path -LiteralPath $v.foundAt -PathType Leaf)) { $foundAt[[string]$v.profile] = [string]$v.foundAt }
    }
  }
}

function Resolve-GamePath([string]$tp, [string]$p) {
  if ([IO.Path]::IsPathRooted($p)) { return $p }
  return [IO.Path]::GetFullPath((Join-Path $tp $p))
}
function Get-GamePath([string]$xmlFile) {
  $m = Select-String -LiteralPath $xmlFile -Pattern '<GamePath>(.*)</GamePath>' | Select-Object -First 1
  if ($m) { return [Net.WebUtility]::HtmlDecode($m.Matches[0].Groups[1].Value) }   # the file is XML: Let&apos;s Go -> Let's Go
}

# old root -> ordered candidate roots (first existing hit wins)
$remap = @(
  @{ From = 'D:\collections\TeknoParrot\roms\'; To = @('E:\DRIVE Collection\collections\TeknoParrot\roms\') },
  @{ From = 'D:\Raw Thrills\';                  To = @('E:\Raw Thrills\') },
  @{ From = 'E:\Arcade PC\';                    To = @('D:\Arcade PC\') }
)

$results = foreach ($f in Get-ChildItem (Join-Path $TpDir 'UserProfiles') -Filter *.xml) {
  $raw = Get-GamePath $f.FullName
  if (-not $raw) { continue }
  $full = Resolve-GamePath $TpDir $raw
  if (Test-Path -LiteralPath $full) { continue }

  $new = $null; $how = $null
  foreach ($h in $HintDirs) {
    $hp = Join-Path $h "UserProfiles\$($f.Name)"
    if (Test-Path -LiteralPath $hp) {
      $c = Resolve-GamePath $h (Get-GamePath $hp)
      if ($c -and (Test-Path -LiteralPath $c)) { $new = $c; $how = "hint:$(Split-Path $h -Leaf)"; break }
    }
  }
  if (-not $new -and $foundAt.ContainsKey($f.BaseName) -and (Test-AmSameGamePath $full $foundAt[$f.BaseName])) {
    $new = $foundAt[$f.BaseName]; $how = 'catalog'          # found by the catalog; the paths agree up to a folder that names the game
  }
  if (-not $new) {
    foreach ($r in $remap) {
      if ($full.StartsWith($r.From, [StringComparison]::OrdinalIgnoreCase)) {
        foreach ($to in $r.To) {
          $c = $to + $full.Substring($r.From.Length)
          if (Test-Path -LiteralPath $c) { $new = $c; $how = 'remap'; break }
        }
      }
      if ($new) { break }
    }
  }
  if (-not $new) {
    # search for the exe name under the nearest existing ancestor folder(s) of the original and remapped paths
    $leaf = Split-Path $full -Leaf
    $roots = @($full) + @($remap | Where-Object { $full.StartsWith($_.From, 'OrdinalIgnoreCase') } | ForEach-Object { $_.To[0] + $full.Substring($_.From.Length) })
    foreach ($r in $roots) {
      $d = Split-Path $r
      while ($d -and -not (Test-Path -LiteralPath $d)) { $d = Split-Path $d }
      if (-not $d -or $d.Length -le 3 -or $d -match '\\(Arcade PC|roms)$') { continue }   # don't search whole drives / whole libraries
      $hit = Get-ChildItem -LiteralPath $d -Recurse -Filter $leaf -File -ErrorAction SilentlyContinue | Select-Object -First 1
      if ($hit) { $new = $hit.FullName; $how = "search:$d"; break }
    }
  }
  [pscustomobject]@{ Profile = $f.Name; Old = $raw; New = $new; How = $how; File = $f.FullName }
}

$results | Format-Table Profile, How, New -AutoSize | Out-String -Width 300 | Write-Host
$unresolved = @($results | Where-Object { -not $_.New })
Write-Host ("broken={0} resolvable={1} unresolved={2}" -f @($results).Count, (@($results).Count - $unresolved.Count), $unresolved.Count)

if ($Apply) {
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $bk = Join-Path $BackupRoot "TP-UserProfiles-$((Split-Path $TpDir -Leaf) -replace '\W','_')-$stamp"
  Copy-Item (Join-Path $TpDir 'UserProfiles') $bk -Recurse
  Write-Host "backup -> $bk"
  foreach ($r in $results | Where-Object New) {
    $bytes = [IO.File]::ReadAllBytes($r.File)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [IO.File]::ReadAllText($r.File)
    $esc = [Security.SecurityElement]::Escape($r.New)
    $text = ([regex]'<GamePath>.*?</GamePath>').Replace($text, "<GamePath>$esc</GamePath>", 1)
    $enc = New-Object Text.UTF8Encoding($hasBom)
    [IO.File]::WriteAllText($r.File, $text, $enc)
    Write-Host "fixed $($r.Profile)"
  }
}
