# Finds a real Python (never the Microsoft Store stub, never a program's private copy) whether or not it is on PATH.
# A process started without the user's PATH (from another tool, a task, a service) found no Python, and the Stream
# Deck controller and the card / story / preview steps were skipped without a word. On PATH, the Azure CLI's private
# Python (Microsoft SDKs\Azure\CLI2) can come first: it has none of our packages, so it is skipped too.
# Dot-source this file, then: Find-AmPython            -> python.exe
#                             Find-AmPython -Windowed  -> pythonw.exe (no console window)
function Find-AmPython([switch]$Windowed) {
  $name = if ($Windowed) { 'pythonw.exe' } else { 'python.exe' }
  $private = '\\WindowsApps\\|\\Microsoft SDKs\\|\\Microsoft Visual Studio\\|\\Inkscape\\|\\Blender'
  # 1. python.org / winget installs: per-user, then all-users (newest version first). The wildcard folders are
  #    expanded FIRST - Get-ChildItem 'C:\Program Files\Python*' -Recurse would crawl all of Program Files.
  $dirs = @(Get-Item (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python*'), (Join-Path $env:ProgramFiles 'Python*'), 'C:\Python*' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSIsContainer })
  $found = @($dirs | ForEach-Object { Join-Path $_.FullName $name } | Where-Object { Test-Path $_ } |
             Sort-Object { $v = (Get-Item $_).VersionInfo.ProductVersion -replace '[^\d.].*$', ''; try { [version]$v } catch { [version]'0.0' } } -Descending)
  if ($found) { return $found[0] }
  # 2. the registry entries the python.org installer writes (PEP 514)
  foreach ($hive in 'HKCU:', 'HKLM:') {
    foreach ($k in Get-ChildItem "$hive\Software\Python\PythonCore" -ErrorAction SilentlyContinue | Sort-Object PSChildName -Descending) {
      $ip = (Get-ItemProperty (Join-Path $k.PSPath 'InstallPath') -ErrorAction SilentlyContinue).'(default)'
      if ($ip -and (Test-Path (Join-Path $ip $name))) { return (Join-Path $ip $name) }
    }
  }
  # 3. whatever is on PATH, minus the Store stub and programs' private copies
  $hit = Get-Command $name -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -notmatch $private } | Select-Object -First 1
  if ($hit) { return $hit.Source }
  return $null
}
