<#
.SYNOPSIS
  Keeps a cabinet on the latest ArcadeMaster: pulls main, and when the RetroFE patches or the build script changed,
  compiles RetroFE (retrofe\Build-RetroFE.ps1) and installs it. Run every 15 minutes by a scheduled task (-Install)
  and at every boot by Start-ArcadeMaster (-DeployOnly first, so a build made while the frontend was open goes in
  before RetroFE starts).

  1. pull   git pull --ff-only, only when the clone is on main with no edits to tracked files (a cabinet that is
            testing a branch, or has local edits, is left alone and says so)
  2. key    a short fingerprint of retrofe\patches\*.patch + retrofe\Build-RetroFE.ps1 = the build this repo wants
  3. build  when <frontend>\retrofe\am-build.txt names another key and no finished build for this key is waiting:
            Build-RetroFE.ps1 (pwsh 7, VS Build Tools, GStreamer) into <BuildRoot>\retrofe-<key>, in its OWN source
            folder <BuildRoot>\src (never a developer's checkout). A cabinet without the tools says so and keeps its exe.
  4. deploy only while RetroFE is closed: the current files are kept in <frontend>\retrofe.am-prev\ (one level), the
            new build is copied in, am-build.txt records the key. If RetroFE is open the build waits for the next start.
  The crash watchdog in Start-ArcadeMaster + the health check's last-known-good restore cover a build that won't run.

  Log: <ManifestDir>\update-cabinet.log. One run at a time (a lock file); a run never takes more than one build.
.EXAMPLE
  tools\Update-Cabinet.ps1 -Root D:\ArcadeMaster\frontend\DRIVE-coinops            # pull, build if needed, deploy
  tools\Update-Cabinet.ps1 -Root <root> -DeployOnly                                 # boot: install a waiting build
  tools\Update-Cabinet.ps1 -Root <root> -Install                                    # every 15 min (scheduled task)
  $env:AM_SYSTEM_DRYRUN = 1; tools\Update-Cabinet.ps1 -Root <root> -Install         # show the task, change nothing
#>
param(
  [Parameter(Mandatory)][string]$Root,
  [string]$ManifestDir = 'D:\ArcadeMaster\manifest',
  [string]$BuildRoot = 'D:\ArcadeMaster\build',
  [string]$GstRoot,
  [switch]$DeployOnly,
  [switch]$NoPull,
  [switch]$NoBuild,
  [switch]$Install,
  [int]$EveryMinutes = 15
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot
. (Join-Path $PSScriptRoot 'lib\RetroFEPaths.ps1')
$git = (Get-Command git -ErrorAction SilentlyContinue).Source
# git installed per user (the pedestal: %LOCALAPPDATA%\Programs\Git) is not on PATH in every shell
if (-not $git) { $git = @('C:\Program Files\Git\cmd\git.exe', "$env:LOCALAPPDATA\Programs\Git\cmd\git.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1 }
New-Item -ItemType Directory -Force $ManifestDir | Out-Null
$log = Join-Path $ManifestDir 'update-cabinet.log'
function Say([string]$m) { $l = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $m; Write-Host $l; Add-Content $log $l -Encoding UTF8 }

# --- scheduled task (Windows change: AM_SYSTEM_DRYRUN=1 shows it without registering)
if ($Install) {
  $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source; if (-not $pwsh) { $pwsh = (Get-Command powershell).Source }
  $task = 'ArcadeMaster Update'
  # Register-ScheduledTask, not schtasks /TR (that one stops at 261 characters - this command is longer)
  $argLine = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Root `"$Root`" -ManifestDir `"$ManifestDir`" -BuildRoot `"$BuildRoot`""
  if ($env:AM_SYSTEM_DRYRUN) { Write-Host "DRY RUN: task '$task' every $EveryMinutes min as $env:USERNAME (only while logged on): $pwsh $argLine"; return }
  $action = New-ScheduledTaskAction -Execute $pwsh -Argument $argLine -WorkingDirectory $repo
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
  $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
  Say "scheduled task '$task' runs every $EveryMinutes min (remove: Unregister-ScheduledTask -TaskName '$task')"
  return
}

# --- one run at a time (a lock older than 3 h is left over from a crash)
$lock = Join-Path $BuildRoot 'update-cabinet.lock'
New-Item -ItemType Directory -Force $BuildRoot | Out-Null
# A boot (-DeployOnly) that finds the scheduled run in the middle of COPYING a build waits for it: it used to go straight
# on and start RetroFE into the half-copied folder (RACE2 2026-11-27 08:40: robocopy 11, old and new files mixed). Only the
# copy is waited for (deploying.flag, seconds); a build in progress is not - that run will not copy while RetroFE runs.
$deployFlag = Join-Path $BuildRoot 'deploying.flag'
if ($DeployOnly -and (Test-Path $deployFlag) -and ((Get-Date) - (Get-Item $deployFlag).LastWriteTime).TotalMinutes -lt 10) {
  Write-Host 'a RetroFE build is being copied in - waiting for it to finish'
  $until = (Get-Date).AddMinutes(5); while ((Test-Path $deployFlag) -and (Get-Date) -lt $until) { Start-Sleep -Seconds 2 }
}
if ((Test-Path $lock) -and ((Get-Date) - (Get-Item $lock).LastWriteTime).TotalHours -lt 3) { Write-Host "another update is running ($lock)"; return }
Set-Content $lock $PID -Encoding ascii
try {
  $exe = Get-AmRetroFEExe $Root
  $rtDir = if ($exe) { Split-Path $exe } else { Join-Path $Root 'retrofe' }
  $stampFile = Join-Path $rtDir 'am-build.txt'
  $running = @(Get-Process retrofe -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0

  # 1. pull
  if (-not $DeployOnly -and -not $NoPull -and $git) {
    $br = (& $git -C $repo rev-parse --abbrev-ref HEAD 2>$null)
    $dirty = @(& $git -C $repo status --porcelain --untracked-files=no 2>$null)
    if ($br -ne 'main') { Say "pull skipped: the clone is on '$br', not main" }
    elseif ($dirty.Count) { Say "pull skipped: $($dirty.Count) edited file(s) in the clone" }
    else {
      $before = (& $git -C $repo rev-parse --short HEAD)
      $ErrorActionPreference = 'Continue'; $o = & $git -C $repo pull --ff-only --quiet 2>&1; $ErrorActionPreference = 'Stop'
      $after = (& $git -C $repo rev-parse --short HEAD)
      if ($LASTEXITCODE) { Say "pull failed: $(($o | Out-String).Trim())" } elseif ($before -ne $after) { Say "pulled main $before -> $after" }
    }
  }

  # 1b. layout: main's layouts\ArcadeMaster (layout files, images) into the frontend, so every cabinet shows the latest
  #     look without anyone copying it. Only while RetroFE is closed and only from a clean main; per-collection art
  #     (system_artwork / medium_artwork) and the intro pictures are made on each cabinet and are never touched. Files
  #     about to be replaced are backed up first; Cabinet Settings options (manifest\ui.json) are put back afterwards.
  #     The game list plays am_video previews: on a cabinet with none it would show no video, so it waits for them.
  $onMain = $true
  if ($git) { $onMain = ((& $git -C $repo rev-parse --abbrev-ref HEAD 2>$null) -eq 'main') -and -not @(& $git -C $repo status --porcelain --untracked-files=no -- layouts 2>$null).Count }
  $lsrc = Join-Path $repo 'layouts\ArcadeMaster'; $ldst = Join-Path $Root 'layouts\ArcadeMaster'
  if ($onMain -and -not $running -and (Test-Path $lsrc) -and (Test-Path $ldst)) {
    $xf = @()
    if ((Select-String -LiteralPath (Join-Path $lsrc 'layout.xml') -Pattern 'type="am_video"' -Quiet) -and
        -not @(Get-ChildItem (Join-Path $Root 'collections') -Recurse -Depth 3 -Directory -Filter am_video -ErrorAction SilentlyContinue | Where-Object { Get-ChildItem $_.FullName -File -ErrorAction SilentlyContinue | Select-Object -First 1 }).Count) {
      $xf = @('layout.xml'); Write-Host "layout: game list kept - it plays preview videos and this cabinet has none yet (tools\New-PreviewMedia.py)"
    }
    $robo = @($lsrc, $ldst, '/E', '/XD', 'system_artwork', 'medium_artwork', (Join-Path $lsrc 'images\intro'), '/NJH', '/NJS', '/NDL', '/NC', '/NS', '/NP', '/R:1', '/W:1') + $(if ($xf) { @('/XF') + $xf } else { @() })
    $changes = @(robocopy @robo /L 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -like "$lsrc\*" })
    if ($changes.Count) {
      $bk = Join-Path $ManifestDir ("backup\layout-ArcadeMaster-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
      foreach ($c in $changes) { $rel = $c.Substring($lsrc.Length + 1); $old = Join-Path $ldst $rel; if (Test-Path -LiteralPath $old) { $to = Join-Path $bk $rel; New-Item -ItemType Directory -Force (Split-Path $to) | Out-Null; Copy-Item -LiteralPath $old $to } }
      robocopy @robo | Out-Null
      if ($LASTEXITCODE -ge 8) { Say "layout update FAILED (robocopy $LASTEXITCODE)" }
      else {
        if (Test-Path (Join-Path $ManifestDir 'ui.json')) { & (Join-Path $PSScriptRoot 'Set-LayoutUi.ps1') -RetroFE $Root -ManifestDir $ManifestDir *>&1 | Out-Null }
        Say "layout: $($changes.Count) file(s) from main installed$(if (Test-Path $bk) { " (replaced files kept in $bk)" })"
      }
    }
  }

  # 2. the build this repo wants. With retrofe\fork.txt (2026-11-27, docs/21) that is one commit of our RetroFE fork;
  #    without it, the CoinOPS commit plus retrofe\patches as before
  $forkFile = Join-Path $repo 'retrofe\fork.txt'
  $fork = $null
  if (Test-Path $forkFile) {
    $fork = @{}
    foreach ($l in Get-Content $forkFile) { if ($l -match '^\s*(repo|commit)\s*=\s*(\S+)') { $fork[$Matches[1]] = $Matches[2] } }
    if (-not $fork.repo -or $fork.commit -notmatch '^[0-9a-f]{40}$') { Say "retrofe\fork.txt needs repo= and a full 40-character commit= - no build"; return }
    $parts = @(Get-Item $forkFile) + @(Get-Item (Join-Path $repo 'retrofe\Build-RetroFE.ps1'))
  }
  else { $parts = @(Get-ChildItem (Join-Path $repo 'retrofe\patches') -Filter *.patch -File | Sort-Object Name) + @(Get-Item (Join-Path $repo 'retrofe\Build-RetroFE.ps1')) }
  $sha = [Security.Cryptography.SHA1]::Create()
  $all = New-Object IO.MemoryStream
  foreach ($p in $parts) { $b = [Text.Encoding]::UTF8.GetBytes($p.Name + "`n"); $all.Write($b, 0, $b.Length); $c = [IO.File]::ReadAllBytes($p.FullName); $all.Write($c, 0, $c.Length) }
  $key = (-join ($sha.ComputeHash($all.ToArray()) | ForEach-Object { $_.ToString('x2') })).Substring(0, 10)
  $have = if (Test-Path $stampFile) { ((Get-Content $stampFile | Where-Object { $_ -match '^key=' } | Select-Object -First 1) -replace '^key=', '').Trim() } else { '' }
  $built = Join-Path $BuildRoot "retrofe-$key\retrofe"
  if ($have -eq $key) {
    # the recorded build is right - but is the exe really that build? A test exe copied over it by hand (2026-11-25) went
    # unnoticed: compare with the exe that was built and put it back, keeping the odd one aside
    $builtExe = Join-Path $built 'retrofe.exe'; $instExe = Join-Path $rtDir 'retrofe.exe'
    if ((Test-Path -LiteralPath $builtExe) -and (Test-Path -LiteralPath $instExe) -and (Get-FileHash -LiteralPath $builtExe).Hash -ne (Get-FileHash -LiteralPath $instExe).Hash) {
      if ($running) { Say "retrofe.exe is not build $key (a test or hand-copied exe?) - it is put back when RetroFE is closed" }
      else {
        $stray = "$instExe.am-stray-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Move-Item -LiteralPath $instExe $stray; Copy-Item -LiteralPath $builtExe $instExe
        Say "retrofe.exe was not build $key - put back (the other exe kept as $(Split-Path $stray -Leaf))"
      }
    }
    Write-Host "RetroFE is up to date (build $key, $(if ($fork) { 'fork ' + $fork.commit.Substring(0, 8) } else { "$($parts.Count - 1) patches" }))"; return
  }

  # 3. build (not at boot: -DeployOnly only installs a finished build)
  if (-not (Test-Path (Join-Path $built 'retrofe.exe'))) {
    if ($DeployOnly -or $NoBuild) { Write-Host "RetroFE build $key not built yet (installed: $(if ($have) { $have } else { 'unknown' }))"; return }
    # 3a. the build GitHub made (.github\workflows\build-retrofe.yml publishes release "retrofe-<key>" for every merged
    #     patch change): download it, check its SHA-256, unpack it where a local build would go. Only when that is not
    #     there (not built yet, no network) does this cabinet compile.
    $remote = if ($git) { [string](& $git -C $repo remote get-url origin 2>$null) } else { '' }
    if ($remote -match 'github\.com[:/]([^/]+)/([^/.]+?)(\.git)?$') {
      $rel = "https://github.com/$($Matches[1])/$($Matches[2])/releases/download/retrofe-$key"
      $dlDir = Join-Path $BuildRoot "download-$key"; New-Item -ItemType Directory -Force $dlDir | Out-Null
      $zip = Join-Path $dlDir "retrofe-$key.zip"
      $ErrorActionPreference = 'Continue'
      & curl.exe -fsSL -o "$zip.sha256" "$rel/retrofe-$key.zip.sha256" 2>$null
      $got = $LASTEXITCODE -eq 0
      if ($got) { & curl.exe -fsSL -o $zip "$rel/retrofe-$key.zip" 2>$null; $got = $LASTEXITCODE -eq 0 }
      $ErrorActionPreference = 'Stop'
      if ($got) {
        $want = ((Get-Content "$zip.sha256" -Raw) -split '\s+')[0].ToLower()
        if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -eq $want) {
          $out = Join-Path $BuildRoot "retrofe-$key"
          if (Test-Path $out) { Remove-Item $out -Recurse -Force }
          Expand-Archive -LiteralPath $zip -DestinationPath $out
          if (Test-Path (Join-Path $built 'retrofe.exe')) { Say "downloaded RetroFE $key from GitHub ($([math]::Round((Get-Item $zip).Length / 1MB)) MB, checksum ok)" }
        } else { Say "GitHub build $key failed its checksum - compiling here instead" }
      }
      Remove-Item $dlDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
  if (-not (Test-Path (Join-Path $built 'retrofe.exe'))) {
    # only what is merged: a clone on a branch or with edited files (someone developing a patch) is never built and
    # installed by the timer - that is the developer's job, by hand
    if ($git) {
      # new (untracked) patch files count too: a patch being written is not a build to install
      $br = (& $git -C $repo rev-parse --abbrev-ref HEAD 2>$null); $dirty = @(& $git -C $repo status --porcelain -- retrofe 2>$null)
      if ($br -ne 'main' -or $dirty.Count) { Write-Host "RetroFE build $key not made: the clone is on '$br'$(if ($dirty.Count) { " with edited RetroFE files" }) - only main is built automatically"; return }
    }
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
# Build-RetroFE.ps1 also runs under Windows PowerShell 5.1 (PR 109), so a cabinet without pwsh 7 still builds
if (-not $pwsh) { $pwsh = (Get-Command powershell -ErrorAction SilentlyContinue).Source }
    # Install-Prerequisites.ps1 unpacks GStreamer into <ArcadeMaster>\_tools, next to the build folder
    if (-not $GstRoot) { $GstRoot = @([IO.Path]::Combine((Split-Path $BuildRoot), '_tools\gstreamer\gstreamer\1.0\msvc_x86_64'), 'D:\ArcadeMaster\_tools\gstreamer\gstreamer\1.0\msvc_x86_64','R:\ArcadeMaster\_tools\gstreamer\gstreamer\1.0\msvc_x86_64', 'C:\gstreamer\1.0\msvc_x86_64') | Where-Object { Test-Path ([IO.Path]::Combine($_, 'include')) } | Select-Object -First 1 }   # not Join-Path: 5.1 throws on a missing drive (no D: on the pedestal)
    # Visual Studio (any drive - RACE1 has it on D:\VS) through vswhere, and its own cmake
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = if (Test-Path $vswhere) { & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1 } else { $null }
    $cmake = if ($vs) { Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe' } else { $null }
    if ($cmake -and -not (Test-Path $cmake)) { $cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source }
    $missing = @($(if (-not $pwsh) { 'PowerShell 7 (pwsh)' }), $(if (-not $GstRoot) { 'GStreamer 1.24 kit' }), $(if (-not $vs) { 'Visual Studio Build Tools (C++)' }), $(if ($vs -and -not $cmake) { 'CMake' }) | Where-Object { $_ })
    # every cabinet builds its own RetroFE (James, 2026-11-26: no ready-made packages from the NAS)
    if ($missing) { Say "RetroFE build $key needed but this cabinet can't compile yet (missing: $($missing -join ', ')) - run tools\Install-Prerequisites.ps1, or ArcadeMaster.exe --setup with 'Install the programs ArcadeMaster needs' ticked"; return }
    $out = Join-Path $BuildRoot "retrofe-$key"; $blog = Join-Path $BuildRoot "retrofe-$key.build.log"
    if ($fork) {
      # our fork: its own clone in <BuildRoot>\src-fork (never a developer's checkout), at exactly the pinned commit
      if (-not $git) { Say "RetroFE build $key needs git (fork $($fork.commit.Substring(0, 8)))"; return }
      $fsrc = Join-Path $BuildRoot 'src-fork'
      $ErrorActionPreference = 'Continue'
      if (-not (Test-Path (Join-Path $fsrc '.git'))) { & $git clone --quiet --recurse-submodules $fork.repo $fsrc 2>&1 | Out-Null }
      & $git -C $fsrc fetch --quiet origin 2>&1 | Out-Null
      & $git -C $fsrc checkout --quiet --detach $fork.commit 2>&1 | Out-Null
      $at = (& $git -C $fsrc rev-parse HEAD 2>$null)
      & $git -C $fsrc submodule update --init --recursive --quiet 2>&1 | Out-Null
      $ErrorActionPreference = 'Stop'
      if ($at -ne $fork.commit) { Say "RetroFE build $key not made: the fork clone is at '$at', not $($fork.commit) - see $fsrc"; return }
      Say "building RetroFE $key from fork $($fork.commit.Substring(0, 8)) (installed: $(if ($have) { $have } else { 'unknown' })) - log $blog"
      $sw = [Diagnostics.Stopwatch]::StartNew()
      $p = Start-Process $pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $repo 'retrofe\Build-RetroFE.ps1')`"", '-GstRoot', "`"$GstRoot`"", '-Source', "`"$fsrc`"", '-Work', "`"$(Join-Path $BuildRoot 'src-fork-work')`"", '-Out', "`"$out`"", '-Git', "`"$git`"", '-CMake', "`"$cmake`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput $blog -RedirectStandardError "$blog.err"
      try { $p.PriorityClass = 'BelowNormal' } catch { }
      $p.WaitForExit()
      if ($p.ExitCode -or -not (Test-Path (Join-Path $built 'retrofe.exe'))) { Say "RetroFE build $key FAILED (exit $($p.ExitCode)) after $([int]$sw.Elapsed.TotalMinutes) min - see $blog"; return }
      Set-Content (Join-Path $built 'am-build.txt') "key=$key`r`nbuilt=$(Get-Date -Format s)`r`ncommit=$(& $git -C $repo rev-parse --short HEAD)`r`nfork=$($fork.commit)`r`nmachine=$env:COMPUTERNAME" -Encoding ascii
      Say "built RetroFE $key in $([int]$sw.Elapsed.TotalSeconds) s (fork $($fork.commit.Substring(0, 8)))"
    }
    else {
    # Build from a FROZEN copy of the patch set, checked against the key. On 2026-11-26 the key was read while a new
    # patch was in the folder and the patches were listed a moment later, when a developer's git stash had taken it out:
    # 16 patches were built and installed under the 17-patch key. The copy is what gets built, and it must hash to $key.
    $snap = Join-Path $BuildRoot "patchset-$key"
    if (Test-Path $snap) { Remove-Item $snap -Recurse -Force }
    New-Item -ItemType Directory -Force (Join-Path $snap 'patches') | Out-Null
    Copy-Item (Join-Path $repo 'retrofe\patches\*.patch') (Join-Path $snap 'patches')
    Copy-Item (Join-Path $repo 'retrofe\Build-RetroFE.ps1') $snap
    $sparts = @(Get-ChildItem (Join-Path $snap 'patches') -Filter *.patch -File | Sort-Object Name) + @(Get-Item (Join-Path $snap 'Build-RetroFE.ps1'))
    $sall = New-Object IO.MemoryStream
    foreach ($sp in $sparts) { $b = [Text.Encoding]::UTF8.GetBytes($sp.Name + "`n"); $sall.Write($b, 0, $b.Length); $c = [IO.File]::ReadAllBytes($sp.FullName); $sall.Write($c, 0, $c.Length) }
    $skey = (-join ([Security.Cryptography.SHA1]::Create().ComputeHash($sall.ToArray()) | ForEach-Object { $_.ToString('x2') })).Substring(0, 10)
    if ($skey -ne $key) { Remove-Item $snap -Recurse -Force; Say "RetroFE build $key not made: the patches changed while they were being read (copy is $skey) - next run"; return }
    Say "building RetroFE $key (installed: $(if ($have) { $have } else { 'unknown' })) - log $blog"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process $pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $snap 'Build-RetroFE.ps1')`"", '-GstRoot', "`"$GstRoot`"", '-Work', "`"$(Join-Path $BuildRoot 'src')`"", '-Out', "`"$out`"", '-Git', "`"$git`"", '-CMake', "`"$cmake`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput $blog -RedirectStandardError "$blog.err"
    try { $p.PriorityClass = 'BelowNormal' } catch { }
    $p.WaitForExit()
    if ($p.ExitCode -or -not (Test-Path (Join-Path $built 'retrofe.exe'))) { Say "RetroFE build $key FAILED (exit $($p.ExitCode)) after $([int]$sw.Elapsed.TotalMinutes) min - see $blog"; return }
    Set-Content (Join-Path $built 'am-build.txt') "key=$key`r`nbuilt=$(Get-Date -Format s)`r`ncommit=$(& $git -C $repo rev-parse --short HEAD)`r`nmachine=$env:COMPUTERNAME" -Encoding ascii
    Remove-Item $snap -Recurse -Force -ErrorAction SilentlyContinue
    # the log must show every patch of this key going in (applied now, or already there)
    $logged = @(Select-String -LiteralPath $blog -Pattern '^==> (apply|patch already applied:) (\S+\.patch)' | ForEach-Object { $_.Matches[0].Groups[2].Value } | Sort-Object -Unique)
    if ($logged.Count -ne ($sparts.Count - 1)) { Remove-Item (Join-Path $built 'retrofe.exe') -Force; Say "RetroFE build $key THROWN AWAY: the build log shows $($logged.Count) patch(es), the key has $($sparts.Count - 1) - see $blog"; return }
    Say "built RetroFE $key in $([int]$sw.Elapsed.TotalSeconds) s ($($logged.Count) patches)"
    }
  }

  # 4. deploy (only with RetroFE closed)
  if ($running) { Say "RetroFE $key is built; it goes in at the next start (the frontend is open now)"; return }
  $prev = Join-Path (Split-Path $rtDir) 'retrofe.am-prev'
  Set-Content $deployFlag "$key $(Get-Date -Format s)" -Encoding ascii   # a boot now waits for the copy (see the lock above)
  if (Test-Path $rtDir) {
    if (Test-Path $prev) { Remove-Item $prev -Recurse -Force }
    robocopy $rtDir $prev /E /XF 'retrofe.exe.*' /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    Copy-Item (Join-Path $rtDir 'retrofe.exe') $prev -ErrorAction SilentlyContinue
  }
  robocopy $built $rtDir /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
  if ($LASTEXITCODE -ge 8) {
    $rc = $LASTEXITCODE
    # never leave old and new files mixed: put the previous build back while RetroFE is still closed
    $nowRunning = @(Get-Process retrofe -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    if ((Test-Path $prev) -and -not $nowRunning) { robocopy $prev $rtDir /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null; Say "deploy of RetroFE $key FAILED (robocopy $rc) - the previous build was put back ($(if ($LASTEXITCODE -ge 8) { "restore robocopy $LASTEXITCODE" } else { 'complete' }))" }
    else { Say "deploy of RetroFE $key FAILED (robocopy $rc) with RetroFE open - the folder may be mixed; the next start puts the right build in. Previous files: $prev" }
    return
  }
  if ((Get-FileHash (Join-Path $built 'retrofe.exe')).Hash -ne (Get-FileHash (Join-Path $rtDir 'retrofe.exe')).Hash) { Say "deploy of RetroFE $key did not take (retrofe.exe differs) - previous files in $prev"; return }
  Say "installed RetroFE $key into $rtDir (was $(if ($have) { $have } else { 'unknown' }); previous files kept in $prev)"
} finally {
  Remove-Item $deployFlag -Force -ErrorAction SilentlyContinue
  Remove-Item $lock -Force -ErrorAction SilentlyContinue
  # what this cabinet now runs -> Z:\ArcadeMaster\reports\state\<PC>.json (Compare-Cabinets.ps1). In finally: most runs end
  # early ('up to date', 'pull skipped'), and those must report too
  if (-not $Install) { try { & (Join-Path $PSScriptRoot 'Write-CabinetState.ps1') -Root $Root -ManifestDir $ManifestDir 6>$null | Out-Null } catch { } }
}
# robocopy's 1-7 (files copied) must not leak out as the task's 'last run result'
exit 0
