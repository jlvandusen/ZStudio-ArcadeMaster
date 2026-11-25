# Why a game can't start, and the fixes that are safe to make on their own. Used by Build-Manifest.ps1 on every
# catalog build, so a game whose folder moved comes back by itself the next time the menus are rebuilt.
#
# Program files: Windows games start from an .exe; Linux-based boards (Sega Lindbergh / Nu, some Raw Thrills, Taito
# Type X3 ...) start from a Linux program file, .elf or no extension at all (abc, Jennifer, car). Both count.
#
# For every variant that can't start (ok = false) it sets:
#   problem  moved          the program file is somewhere else on this PC (same file name AND same folder name, never a
#                           guess by name alone). PC games: the variant now points there (ok = true, movedFrom).
#                           TeknoParrot games: foundAt - the health check repairs the profile (Repair-TPProfiles).
#            incomplete     the game's folder is here with its data but without its program file
#            not-installed  neither the file nor its folder is on this PC
#            not-set-up     TeknoParrot has never been set up for this game (no UserProfiles\<game>.xml). When a folder
#                           named after the game is found it says so: "ready to set up" (it has a program file, with the
#                           Add-TPGame.ps1 line to run) or "data only" (the program files are missing)
#            no-path        the profile has no game path
#   why      the same in plain words (games-cant-start.txt, the System Health page)
# Nothing outside the catalog is changed here.

function Test-AmProgramFile([string]$p) {
  if ($p -match '(?i)\.exe$') { return $true }
  try { $fs = [IO.File]::OpenRead($p); $b = New-Object byte[] 4; $n = $fs.Read($b, 0, 4); $fs.Close() } catch { return $false }
  return ($n -eq 4 -and $b[0] -eq 0x7F -and $b[1] -eq 0x45 -and $b[2] -eq 0x4C -and $b[3] -eq 0x46)   # Linux ELF
}

function Get-AmDirIndex([string[]]$Roots, [int]$Levels = 6) {
  # every folder up to 6 levels under the roots, by lower-case folder name (several folders can share a name).
  # Folders only: listing them takes ~2 s; listing every file under D:\Arcade PC (700,000+) took 9-14 s.
  $ix = @{}
  foreach ($r in $Roots | Select-Object -Unique) {
    if (-not (Test-Path -LiteralPath $r)) { continue }
    foreach ($l in (robocopy $r "$env:TEMP\am-none" /S /L "/LEV:$Levels" /NJH /NJS /NFL /NC /NS /XJ /R:0 /W:0 2>$null)) {
      $d = $l.Trim().TrimEnd('\'); if ($d -notmatch '^[A-Za-z]:\\') { continue }
      $k = [IO.Path]::GetFileName($d).ToLower()
      if (-not $ix.ContainsKey($k)) { $ix[$k] = New-Object System.Collections.Generic.List[string] }
      $ix[$k].Add($d)
    }
  }
  $ix
}

function Get-AmGameRoots($games) {
  # the folders games live in: two levels above every game file the catalog knows (D:\Arcade PC\Konami\X\x.exe ->
  # D:\Arcade PC), never a drive root or a Windows folder
  $roots = @{}
  foreach ($g in $games) {
    foreach ($v in $g.variants.Values) {
      foreach ($p in @($v.gamePath, $v.file, $v.movedFrom)) {
        if (-not $p -or $p -match '(?i)\.(xml|bat|cmd|lnk|url)$' -or $p -match '(?i)\\(collections|UserProfiles)\\') { continue }
        $d = [IO.Path]::GetDirectoryName($p)
        for ($i = 0; $i -lt 2 -and $d; $i++) { $up = [IO.Path]::GetDirectoryName($d); if ($up -and $up.Length -gt 3) { $d = $up } else { break } }
        if ($d -and $d.Length -gt 3 -and $d -notmatch '(?i)\\(windows|program files[^\\]*|programdata)(\\|$)') { $roots[$d.ToLower()] = $d }
      }
    }
  }
  # a root inside another root is scanned with it: keep only the outermost (D:\Arcade PC, not also D:\Arcade PC\PC ...)
  $all = @($roots.Values | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object Length)
  $keep = New-Object System.Collections.Generic.List[string]
  foreach ($r in $all) { if (-not @($keep | Where-Object { $r.ToLower().StartsWith($_.ToLower().TrimEnd('\') + '\') }).Count) { $keep.Add($r) } }
  @($keep)
}

# folder names arcade dumps commonly use that don't look like the game's name (TeknoParrot name -> folder names)
$script:AmFolderHints = @{
  FNF = @('FF', 'FNF'); FNFSB = @('FFSB', 'FNFSB'); FNFSB2 = @('FFSB2', 'FNFSB2'); FNFSC = @('FFSC', 'FNFSC'); FNFDrift = @('FFD', 'FNFDrift')
  SnoCross = @('SNOTP', 'SnoCross'); DirtyDrivin = @('dd', 'Dirty Drivin'); Batman = @('BATMAN'); Cars = @('cars')
}

# Is $new the same game as $old? Their paths must end the same way (file name, then folders upwards) up to and including
# a folder that names the game. "Game\RingGame.exe" alone is not enough: Under Night In-Birth and Fighting Climax Ignition
# both have one; "Fighting Climax Ignition [SDCS]\Game\RingGame.exe" is.
$script:AmGenericFolders = @('game', 'games', 'bin', 'binaries', 'win32', 'win64', 'x64', 'x86', 'exe', 'data', 'app', 'release', 'linux', 'dump', 'rom', 'roms', 'program', 'main', 'disk', 'files', 'content', 'build', 'sys', 'system', 'windowsnoeditor')
function Test-AmSameGamePath([string]$old, [string]$new) {
  $a = @($old -split '\\' | Where-Object { $_ }); $b = @($new -split '\\' | Where-Object { $_ })
  if ($a.Count -lt 2 -or $b.Count -lt 2 -or $a[-1] -ne $b[-1]) { return $false }
  for ($i = 2; $i -le [Math]::Min($a.Count, $b.Count) - 1; $i++) {
    $x = $a[$a.Count - $i]; $y = $b[$b.Count - $i]
    if ($x -ne $y) { return $false }                                  # -ne is case-insensitive
    if ($script:AmGenericFolders -notcontains $x.ToLower()) { return $true }
  }
  $false
}

function ConvertTo-AmKey([string]$s) { ($s.ToLower() -replace '[^a-z0-9]', '') }

# the game's own program file in a folder: the name TeknoParrot expects if it says one, else the largest .exe / Linux
# program that is not a loader, config or installer tool
function Find-AmProgram([string]$dir, [string]$expected) {
  $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Depth 3 -ErrorAction SilentlyContinue)
  if ($expected) { $hit = $files | Where-Object { $_.Name -eq $expected } | Sort-Object { $_.FullName.Length } | Select-Object -First 1; if ($hit) { return $hit.FullName } }
  $cand = $files | Where-Object { $_.Length -gt 100KB -and $_.Name -notmatch '(?i)loader|config|setup|install|unins|jconfig|crash|vcredist|dxsetup|directx|test' -and ($_.Extension -in '.exe', '.elf', '') } |
    Where-Object { Test-AmProgramFile $_.FullName } |
    Sort-Object @{ e = { if ($_.BaseName -match '(?i)^(game|main)$') { 0 } else { 1 } } }, @{ e = 'Length'; Descending = $true } | Select-Object -First 1
  if ($cand) { $cand.FullName }
}

function Invoke-AmGameDoctor($games) {
  $list = @($games)
  $roots = Get-AmGameRoots $list
  $script:amDirIndex = $null
  $dirIx = { if ($null -eq $script:amDirIndex) { $script:amDirIndex = Get-AmDirIndex $roots }; $script:amDirIndex }
  $stats =[ordered]@{ moved = 0; incomplete = 0; 'not-installed' = 0; 'not-set-up' = 0; 'no-path' = 0 }
  foreach ($g in $list) {
    foreach ($name in @($g.variants.Keys)) {
      $v = $g.variants[$name]
      if ($v.ok) { continue }
      $path = if ($v.gamePath) { $v.gamePath } else { $v.file }
      if (-not $path) { $v.problem = 'no-path'; $v.why = 'the profile has no game path - set the game up in its emulator'; $stats['no-path']++; continue }

      if ($path -match '(?i)^(.*)\\UserProfiles\\([^\\]+)\.xml$') {
        $tpDir = $Matches[1]; $tpId = $Matches[2]
        $v.problem = 'not-set-up'; $stats['not-set-up']++
        $v.why = "TeknoParrot has never been set up for this game (no $tpId.xml)"
        # a folder named after the game (its TeknoParrot name or its title)?
        $keys = @((ConvertTo-AmKey $tpId), (ConvertTo-AmKey $g.title) -replace '^the', '') | Where-Object { $_.Length -ge 4 }
        $ix = & $dirIx
        $found = @($script:AmFolderHints[$tpId]) | Where-Object { $_ -and $ix.ContainsKey($_.ToLower()) } | ForEach-Object { $ix[$_.ToLower()][0] } | Select-Object -First 1
        if (-not $found) { $found = $ix.Keys | Where-Object { $k = ConvertTo-AmKey $_; $k.Length -ge 5 -and @($keys | Where-Object { $_ -eq $k -or ($k.Length -ge 6 -and $_.Contains($k)) -or $k.Contains($_) }).Count } | ForEach-Object { $ix[$_][0] } | Select-Object -First 1 }
        if ($found) {
          $gp = Join-Path $tpDir "GameProfiles\$tpId.xml"
          $expected = if (Test-Path -LiteralPath $gp) { ([regex]::Match([IO.File]::ReadAllText($gp), '<ExecutableName>([^<]+)<')).Groups[1].Value } else { '' }
          $prog = Find-AmProgram $found $expected
          if ($prog) { $v.setupReady = $prog; $v.why = "ready to set up: the game is at $found ($([IO.Path]::GetFileName($prog))). Set it up with: tools\Add-TPGame.ps1 -Id $tpId -GamePath '$prog' -Apply" }
          else { $v.why = "the game's data is at $found but it has no program file (.exe, or a Linux program for Linux-based boards) - copy the program files in, then set it up" }
        }
        continue
      }

      $exe = [IO.Path]::GetFileName($path); $folder = [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($path))
      # moved: a folder with the same name somewhere under the game folders that holds the same program file
      $hits = @(@((& $dirIx)[$folder.ToLower()]) | Where-Object { $_ } | ForEach-Object { Join-Path $_ $exe } | Where-Object { (Test-Path -LiteralPath $_ -PathType Leaf) -and (Test-AmProgramFile $_) -and (Test-AmSameGamePath $path $_) })
      if ($hits.Count -ge 1) {
        $new = $hits | Sort-Object { $_.Length } | Select-Object -First 1   # the shallowest copy (not a tools\32\ duplicate)
        $v.problem = 'moved'; $stats.moved++
        if ($v.profile) {
          # TeknoParrot starts the game from its own profile, so the catalog alone can't fix it: say where it is
          $v.foundAt = $new; $v.why = "found at $new, but its TeknoParrot profile still points at $path - fix: tools\Repair-TPProfiles.ps1 -TpDir '$($v.install)' -Apply (the health check does it by itself for the frontend's own TeknoParrot)"
        } else {
          $v.movedFrom = $path; $v.file = $new; $v.ok = $true; $v.why = "found at $new (was $path)"
        }
        continue
      }
      $dir = [IO.Path]::GetDirectoryName($path)
      if (-not (Test-Path -LiteralPath $dir)) {
        # the folder may be elsewhere without its program file (a partial copy): look for it by name
        $same = @(@((& $dirIx)[$folder.ToLower()]) | Where-Object { $_ }) | Select-Object -First 1
        if ($same) { $dir = $same }
      }
      if (Test-Path -LiteralPath $dir) {
        $v.problem = 'incomplete'; $stats.incomplete++
        $v.why = "the game's data is at $dir but $exe is missing - copy the game's program files in again"
      } else {
        $v.problem = 'not-installed'; $v.why = "not on this cabinet ($path)"; $stats['not-installed']++
      }
    }
  }
  $stats
}
