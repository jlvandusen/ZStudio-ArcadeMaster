# Where a RetroFE install keeps its executable. Builds differ:
#   ArcadeMaster / DRIVE      <root>\retrofe\retrofe.exe
#   CoinOPS LEGENDS / CORE    <root>\core\retrofe.exe
#   ATARASHII and plain       <root>\retrofe.exe
# Dot-source this file, then call Get-AmRetroFEExe <root>. Returns $null when none is found.
function Get-AmRetroFEExe([string]$Root) {
  foreach ($rel in 'retrofe\retrofe.exe', 'core\retrofe.exe', 'retrofe.exe') {
    $p = Join-Path $Root $rel
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}
