# Why a game can't start, and the fixes that are safe to make on their own. Used by Build-Manifest.ps1 on every
# catalog build, so a game whose folder moved comes back by itself the next time the menus are rebuilt.
#
# For every variant that can't start (ok = false) it sets:
#   problem  moved          the program file is somewhere else on this PC -> the variant now points there (ok = true,
#                           movedFrom = old path). Matched by file name AND folder name, never a guess by name alone.
#            incomplete     the game folder is there but its program file is not (a partial copy): copy the game in again
#            not-installed  neither the file nor its folder is on this PC
#            not-set-up     TeknoParrot has never been set up for this game (no UserProfiles\<game>.xml)
#            no-path        the profile has no game path
#   why      the same in plain words, shown on the System Health page
# Nothing outside the catalog is changed. TeknoParrot profiles that point at a moved game are left for
# Repair-TPProfiles.ps1 (it backs the profiles up first); the catalog says which ones.

function Get-AmExeIndex([string[]]$Roots) {
  # every .exe under the roots, by lower-case file name (robocopy /L lists a whole drive tree in seconds)
  $ix = @{}
  foreach ($r in $Roots | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    $lines = robocopy $r "$env:TEMP\am-none" *.exe /S /L /NJH /NJS /NDL /NC /NS /XJ /R:0 /W:0 2>$null
    foreach ($l in $lines) {
      $p = $l.Trim(); if ($p -notmatch '^[A-Za-z]:\\') { continue }
      $k = [IO.Path]::GetFileName($p).ToLower()
      if (-not $ix.ContainsKey($k)) { $ix[$k] = New-Object System.Collections.Generic.List[string] }
      if (-not $ix[$k].Contains($p)) { $ix[$k].Add($p) }
    }
  }
  $ix
}

function Get-AmDirIndex([string[]]$Roots) {
  # every folder up to 4 levels under the roots, by lower-case folder name
  $ix = @{}
  foreach ($r in $Roots | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    foreach ($l in (robocopy $r "$env:TEMP\am-none" /S /L /LEV:4 /NJH /NJS /NFL /NC /NS /XJ /R:0 /W:0 2>$null)) {
      $p = $l.Trim().TrimEnd('\'); if ($p -notmatch '^[A-Za-z]:\\') { continue }
      $k = [IO.Path]::GetFileName($p).ToLower(); if (-not $ix.ContainsKey($k)) { $ix[$k] = $p }
    }
  }
  $ix
}

function Get-AmGameRoots($games) {
  # the folders games live in: two levels above every program file that exists (D:\Arcade PC\Konami\X\x.exe ->
  # D:\Arcade PC), never a drive root or a Windows folder
  $roots = @{}
  foreach ($g in $games) {
    foreach ($v in $g.variants.Values) {
      foreach ($p in @($v.gamePath, $v.file, $v.movedFrom)) {
        if (-not $p -or $p -notmatch '(?i)\.exe$') { continue }
        $d = [IO.Path]::GetDirectoryName($p)
        for ($i = 0; $i -lt 2 -and $d; $i++) { $up = [IO.Path]::GetDirectoryName($d); if ($up -and $up.Length -gt 3) { $d = $up } else { break } }
        if ($d -and $d.Length -gt 3 -and $d -notmatch '(?i)\\(windows|program files[^\\]*|programdata)(\\|$)') { $roots[$d.ToLower()] = $d }
      }
    }
  }
  @($roots.Values)
}

function Invoke-AmGameDoctor($games) {
  $list = @($games)
  $index = $null; $script:amDirIndex = $null
  $stats = [ordered]@{ moved = 0; incomplete = 0; 'not-installed' = 0; 'not-set-up' = 0; 'no-path' = 0 }
  foreach ($g in $list) {
    foreach ($name in @($g.variants.Keys)) {
      $v = $g.variants[$name]
      if ($v.ok) { continue }
      $path = if ($v.gamePath) { $v.gamePath } else { $v.file }
      if (-not $path) { $v.problem = 'no-path'; $v.why = 'the profile has no game path - set the game up in its emulator'; $stats['no-path']++; continue }
      if ($path -match '(?i)\\UserProfiles\\[^\\]+\.xml$') {
        $v.problem = 'not-set-up'; $v.why = "TeknoParrot has never been set up for this game (no $([IO.Path]::GetFileName($path)))"; $stats['not-set-up']++; continue
      }
      $exe = [IO.Path]::GetFileName($path); $folder = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($path))
      if ($path -match '(?i)\.exe$') {
        if ($null -eq $index) { $index = Get-AmExeIndex (Get-AmGameRoots $list) }
        $hits = @($index[$exe.ToLower()] | Where-Object { $_ -and [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($_)) -eq $folder })
        if ($hits.Count -ge 1) {
          $new = $hits | Sort-Object { $_.Length } | Select-Object -First 1   # the shallowest copy (not a tools\32\ duplicate)
          $v.problem = 'moved'; $stats.moved++
          if ($v.profile) {
            # TeknoParrot starts the game from its own profile, so the catalog alone can't fix it: say where it is
            $v.foundAt = $new; $v.why = "found at $new, but its TeknoParrot profile still points at $path - run Repair-TPProfiles.ps1"
          } else {
            $v.movedFrom = $path; $v.file = $new; $v.ok = $true; $v.why = "found at $new (was $path)"
          }
          continue
        }
      }
      $dir = [IO.Path]::GetDirectoryName($path)
      if (-not (Test-Path -LiteralPath $dir)) {
        # the folder may have moved without its program file (a partial copy elsewhere): look for it by name
        if ($null -eq $script:amDirIndex) { $script:amDirIndex = Get-AmDirIndex (Get-AmGameRoots $list) }
        $same = @($script:amDirIndex[$folder.ToLower()]) | Where-Object { $_ } | Select-Object -First 1
        if ($same) { $dir = $same }
      }
      if (Test-Path -LiteralPath $dir) {
        $v.problem = 'incomplete'; $v.why = "the game folder is at $dir but $exe is missing - copy the game in again"; $stats.incomplete++
      } else {
        $v.problem = 'not-installed'; $v.why = "not on this cabinet ($path)"; $stats['not-installed']++
      }
    }
  }
  $stats
}
