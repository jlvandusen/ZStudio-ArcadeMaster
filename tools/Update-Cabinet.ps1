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
$git = (Get-Command git -ErrorAction SilentlyContinue).Source; if (-not $git -and (Test-Path 'C:\Program Files\Git\cmd\git.exe')) { $git = 'C:\Program Files\Git\cmd\git.exe' }
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

  # 2. the build this repo wants
  $parts = @(Get-ChildItem (Join-Path $repo 'retrofe\patches') -Filter *.patch -File | Sort-Object Name) + @(Get-Item (Join-Path $repo 'retrofe\Build-RetroFE.ps1'))
  $sha = [Security.Cryptography.SHA1]::Create()
  $all = New-Object IO.MemoryStream
  foreach ($p in $parts) { $b = [Text.Encoding]::UTF8.GetBytes($p.Name + "`n"); $all.Write($b, 0, $b.Length); $c = [IO.File]::ReadAllBytes($p.FullName); $all.Write($c, 0, $c.Length) }
  $key = (-join ($sha.ComputeHash($all.ToArray()) | ForEach-Object { $_.ToString('x2') })).Substring(0, 10)
  $have = if (Test-Path $stampFile) { ((Get-Content $stampFile | Where-Object { $_ -match '^key=' } | Select-Object -First 1) -replace '^key=', '').Trim() } else { '' }
  $built = Join-Path $BuildRoot "retrofe-$key\retrofe"
  if ($have -eq $key) { Write-Host "RetroFE is up to date (build $key, $($parts.Count - 1) patches)"; return }

  # 3. build (not at boot: -DeployOnly only installs a finished build)
  if (-not (Test-Path (Join-Path $built 'retrofe.exe'))) {
    if ($DeployOnly -or $NoBuild) { Write-Host "RetroFE build $key not built yet (installed: $(if ($have) { $have } else { 'unknown' }))"; return }
    # only what is merged: a clone on a branch or with edited files (someone developing a patch) is never built and
    # installed by the timer - that is the developer's job, by hand
    if ($git) {
      $br = (& $git -C $repo rev-parse --abbrev-ref HEAD 2>$null); $dirty = @(& $git -C $repo status --porcelain --untracked-files=no -- retrofe 2>$null)
      if ($br -ne 'main' -or $dirty.Count) { Write-Host "RetroFE build $key not made: the clone is on '$br'$(if ($dirty.Count) { " with edited RetroFE files" }) - only main is built automatically"; return }
    }
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $GstRoot) { $GstRoot = @('D:\ArcadeMaster\_tools\gstreamer\gstreamer\1.0\msvc_x86_64', 'R:\ArcadeMaster\_tools\gstreamer\gstreamer\1.0\msvc_x86_64', 'C:\gstreamer\1.0\msvc_x86_64') | Where-Object { Test-Path (Join-Path $_ 'include') } | Select-Object -First 1 }
    # Visual Studio (any drive - RACE1 has it on D:\VS) through vswhere, and its own cmake
    $vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
    $vs = if (Test-Path $vswhere) { & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1 } else { $null }
    $cmake = if ($vs) { Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe' } else { $null }
    if ($cmake -and -not (Test-Path $cmake)) { $cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source }
    $missing = @($(if (-not $pwsh) { 'PowerShell 7 (pwsh)' }), $(if (-not $GstRoot) { 'GStreamer 1.24 kit' }), $(if (-not $vs) { 'Visual Studio Build Tools (C++)' }), $(if ($vs -and -not $cmake) { 'CMake' }) | Where-Object { $_ })
    if ($missing) { Say "RetroFE build $key needed but this cabinet can't compile (missing: $($missing -join ', ')) - copy a package from Z:\ArcadeMaster\builds"; return }
    $out = Join-Path $BuildRoot "retrofe-$key"; $blog = Join-Path $BuildRoot "retrofe-$key.build.log"
    Say "building RetroFE $key (installed: $(if ($have) { $have } else { 'unknown' })) - log $blog"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process $pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $repo 'retrofe\Build-RetroFE.ps1')`"", '-GstRoot', "`"$GstRoot`"", '-Work', "`"$(Join-Path $BuildRoot 'src')`"", '-Out', "`"$out`"", '-Git', "`"$git`"", '-CMake', "`"$cmake`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput $blog -RedirectStandardError "$blog.err"
    try { $p.PriorityClass = 'BelowNormal' } catch { }
    $p.WaitForExit()
    if ($p.ExitCode -or -not (Test-Path (Join-Path $built 'retrofe.exe'))) { Say "RetroFE build $key FAILED (exit $($p.ExitCode)) after $([int]$sw.Elapsed.TotalMinutes) min - see $blog"; return }
    Set-Content (Join-Path $built 'am-build.txt') "key=$key`r`nbuilt=$(Get-Date -Format s)`r`ncommit=$(& $git -C $repo rev-parse --short HEAD)`r`nmachine=$env:COMPUTERNAME" -Encoding ascii
    Say "built RetroFE $key in $([int]$sw.Elapsed.TotalSeconds) s"
  }

  # 4. deploy (only with RetroFE closed)
  if ($running) { Say "RetroFE $key is built; it goes in at the next start (the frontend is open now)"; return }
  $prev = Join-Path (Split-Path $rtDir) 'retrofe.am-prev'
  if (Test-Path $rtDir) {
    if (Test-Path $prev) { Remove-Item $prev -Recurse -Force }
    robocopy $rtDir $prev /E /XF 'retrofe.exe.*' /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
    Copy-Item (Join-Path $rtDir 'retrofe.exe') $prev -ErrorAction SilentlyContinue
  }
  robocopy $built $rtDir /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
  if ($LASTEXITCODE -ge 8) { Say "deploy of RetroFE $key FAILED (robocopy $LASTEXITCODE); previous files are in $prev"; return }
  if ((Get-FileHash (Join-Path $built 'retrofe.exe')).Hash -ne (Get-FileHash (Join-Path $rtDir 'retrofe.exe')).Hash) { Say "deploy of RetroFE $key did not take (retrofe.exe differs) - previous files in $prev"; return }
  Say "installed RetroFE $key into $rtDir (was $(if ($have) { $have } else { 'unknown' }); previous files kept in $prev)"
} finally { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
