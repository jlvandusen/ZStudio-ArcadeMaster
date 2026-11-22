# AmTypeCache.ps1 - compile inline C# once, reuse the DLL on every later run.
# Add-Type -TypeDefinition runs csc every time a script starts (~0.25 s each, several times per boot and per Tools
# page). Add-AmCachedType hashes the source + references, keeps the DLL in %LOCALAPPDATA%\ArcadeMaster\typecache and
# loads it with Add-Type -Path. A changed source gets a new hash, so edits never load a stale build. Any cache
# problem falls back to the normal in-memory compile, so it can never stop a tool from starting.
function Add-AmCachedType {
  param([Parameter(Mandatory)][string]$Source, [string[]]$References = @(), [Parameter(Mandatory)][string]$ProbeType)
  if ($ProbeType -as [type]) { return }
  try {
    $dir = Join-Path $env:LOCALAPPDATA 'ArcadeMaster\typecache'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $sha = [Security.Cryptography.SHA256]::Create()
    $key = ($Source + '|' + ($References -join ',') + '|' + $PSVersionTable.CLRVersion)
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))[0..7] | ForEach-Object { $_.ToString('x2') })
    $dll = Join-Path $dir ("{0}-{1}.dll" -f ($ProbeType -replace '[^A-Za-z0-9]', '_'), $hash)
    if (-not (Test-Path $dll)) {
      # compile to a private name, then rename: two processes compiling at once never load a half-written DLL
      $tmp = Join-Path $dir ("{0}.{1}.tmp.dll" -f $hash, $PID)
      $p = @{ TypeDefinition = $Source; OutputAssembly = $tmp; OutputType = 'Library' }
      if ($References) { $p.ReferencedAssemblies = $References }
      Add-Type @p
      try { [IO.File]::Move($tmp, $dll) } catch { Remove-Item $tmp -ErrorAction SilentlyContinue }
    }
    if (-not ($ProbeType -as [type])) { Add-Type -Path $dll }
  } catch {
    if (-not ($ProbeType -as [type])) { $p = @{ TypeDefinition = $Source }; if ($References) { $p.ReferencedAssemblies = $References }; Add-Type @p }
  }
}
