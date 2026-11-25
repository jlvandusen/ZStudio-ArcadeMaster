# AmSettings.ps1 - safe, one-key edits of the cabinet's settings files (dot-source it).
#   settings.conf (RetroFE "key = value" lines), small JSON files edited by key, and manifest\ui.json.
# Every write:
#   - backs the file up next to itself the first time (<file>.am-bak), and never overwrites that first copy
#   - changes only the one key's line; every other byte stays as it was (encoding, line endings, comments)
#   - is skipped when nothing would change, so an unchanged file keeps its date

function Backup-AmFileOnce([string]$Path) {
  $b = "$Path.am-bak"
  if ((Test-Path -LiteralPath $Path) -and -not (Test-Path -LiteralPath $b)) { Copy-Item -LiteralPath $Path $b }
}

# text with its encoding: a UTF-8 BOM file stays UTF-8 with BOM; anything else round-trips byte for byte (Latin-1)
function Read-AmText([string]$Path) {
  $bytes = [IO.File]::ReadAllBytes($Path)
  $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
  if ($bom) { $text = (New-Object Text.UTF8Encoding $false).GetString($bytes, 3, $bytes.Length - 3) }
  else { $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes) }
  @{ text = $text; bom = $bom }
}
function Write-AmText([string]$Path, [string]$Text, [bool]$Bom) {
  $enc = if ($Bom) { New-Object Text.UTF8Encoding $true } else { [Text.Encoding]::GetEncoding(28591) }
  [IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-AmKeyPattern([string]$Key) { '(?m)^[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[^\r\n]*' }

# last value of a settings.conf key (RetroFE uses the last one), without an inline "# comment"; $null when absent
function Get-AmConf([string]$File, [string]$Key) {
  if (-not (Test-Path -LiteralPath $File)) { return $null }
  $m = [regex]::Matches((Read-AmText $File).text, (Get-AmKeyPattern $Key))
  if (-not $m.Count) { return $null }
  $v = $m[$m.Count - 1].Value; $v = $v.Substring($v.IndexOf('=') + 1)
  return ($v -replace '\s+#.*$', '').Trim()
}

# set one key; returns $true when the file changed
function Set-AmConf([string]$File, [string]$Key, [string]$Value) {
  $r = Read-AmText $File; $line = "$Key = $Value"; $pat = Get-AmKeyPattern $Key
  if ([regex]::IsMatch($r.text, $pat)) { $new = [regex]::Replace($r.text, $pat, { param($m) $line }.GetNewClosure()) }
  else {
    $nl = if ($r.text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $new = $r.text; if ($new.Length -and -not $new.EndsWith("`n")) { $new += $nl }; $new += $line + $nl
  }
  if ($new -ceq $r.text) { return $false }
  Backup-AmFileOnce $File; Write-AmText $File $new $r.bom; return $true
}

# remove a key's line(s); returns $true when the file changed
function Remove-AmConfKey([string]$File, [string]$Key) {
  $r = Read-AmText $File; $new = [regex]::Replace($r.text, ((Get-AmKeyPattern $Key) + '(\r?\n)?'), '')
  if ($new -ceq $r.text) { return $false }
  Backup-AmFileOnce $File; Write-AmText $File $new $r.bom; return $true
}

# "# key = value" (a key switched off but remembered) -> the remembered value, else $null
function Get-AmConfCommented([string]$File, [string]$Key) {
  if (-not (Test-Path -LiteralPath $File)) { return $null }
  $m = [regex]::Matches((Read-AmText $File).text, ('(?m)^[ \t]*#[ \t]*' + [regex]::Escape($Key) + '[ \t]*=[ \t]*([^\r\n]*)'))
  if (-not $m.Count) { return $null }
  return $m[$m.Count - 1].Groups[1].Value.Trim()
}
# switch a key off by commenting its line out (the value stays in the file), or back on by uncommenting it
function Set-AmConfCommented([string]$File, [string]$Key, [bool]$Commented) {
  $r = Read-AmText $File; $k = [regex]::Escape($Key)
  if ($Commented) { $new = [regex]::Replace($r.text, ('(?m)^[ \t]*(' + $k + '[ \t]*=)'), '#$1') }
  else { $new = [regex]::Replace($r.text, ('(?m)^[ \t]*#[ \t]*(' + $k + '[ \t]*=)'), '$1') }
  if ($new -ceq $r.text) { return $false }
  Backup-AmFileOnce $File; Write-AmText $File $new $r.bom; return $true
}

# a number (or true/false) key in a JSON file, edited in place so the file's layout and comments stay
function Get-AmJsonNumber([string]$File, [string]$Key) {
  if (-not (Test-Path -LiteralPath $File)) { return $null }
  $m = [regex]::Match((Read-AmText $File).text, ('"' + [regex]::Escape($Key) + '"\s*:\s*(-?[0-9.]+)'))
  if ($m.Success) { return [double]$m.Groups[1].Value } else { return $null }
}
function Set-AmJsonNumber([string]$File, [string]$Key, [double]$Value) {
  $r = Read-AmText $File; $pat = '("' + [regex]::Escape($Key) + '"\s*:\s*)(-?[0-9.]+)'
  if (-not [regex]::IsMatch($r.text, $pat)) { throw "$Key not found in $File" }
  $v = "$Value"; $new = [regex]::Replace($r.text, $pat, { param($m) $m.Groups[1].Value + $v }.GetNewClosure())
  if ($new -ceq $r.text) { return $false }
  Backup-AmFileOnce $File; Write-AmText $File $new $r.bom; return $true
}

# ---- manifest\ui.json: what the ArcadeMaster layout shows, applied by tools\Set-LayoutUi.ps1
$script:AmUiDefaults = [ordered]@{ story = $true; controlHints = $true; menuSounds = $true; videoVolume = 100; streamDeck = $true }
function Read-AmUi([string]$ManifestDir) {
  $u = [ordered]@{}; foreach ($k in $script:AmUiDefaults.Keys) { $u[$k] = $script:AmUiDefaults[$k] }
  $f = Join-Path $ManifestDir 'ui.json'
  if (Test-Path -LiteralPath $f) {
    try { (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { if ($_.Name -notlike '/*') { $u[$_.Name] = $_.Value } } } catch { }
  }
  return $u
}
function Write-AmUi([string]$ManifestDir, $Ui) {
  $f = Join-Path $ManifestDir 'ui.json'
  $o = [ordered]@{ '//' = 'ArcadeMaster layout options (Tools > Cabinet Settings). tools/Set-LayoutUi.ps1 applies them to layouts\ArcadeMaster; docs/08-dynamic-catalog.md' }
  foreach ($k in $Ui.Keys) { if ($k -ne '//') { $o[$k] = $Ui[$k] } }
  $json = $o | ConvertTo-Json
  if ((Test-Path -LiteralPath $f) -and ((Get-Content -LiteralPath $f -Raw).Trim() -ceq $json.Trim())) { return $false }
  Backup-AmFileOnce $f
  [IO.File]::WriteAllText($f, $json + "`r`n", (New-Object Text.UTF8Encoding $false)); return $true
}
