# The menu buttons of THIS cabinet, in words: catalog\menu-controls.json (one layout for every cabinet) turned into the
# names of the buttons on the controllers this cabinet has (cabinet.json): the G29's own names (as New-GameControlsArt
# draws them), an Xbox-style pad, an arcade panel (button n / its I-PAC key), the keyboard. Used by the Tools card
# "Menu Buttons" and its screen.
$script:AmG29Names = @{ 0 = 'Cross'; 1 = 'Square'; 2 = 'Circle'; 3 = 'Triangle'; 4 = 'Right paddle'; 5 = 'Left paddle'; 6 = 'R2'; 7 = 'L2'; 8 = 'Share'; 9 = 'Options'; 10 = 'R3'; 11 = 'L3' }
$script:AmPadNames = @{ 0 = 'A'; 1 = 'B'; 2 = 'X'; 3 = 'Y'; 4 = 'LB'; 5 = 'RB'; 6 = 'Back'; 7 = 'Start'; 8 = 'Left stick click'; 9 = 'Right stick click' }
$script:AmPanelKeys = @{ 'Left Ctrl' = 'button 1'; 'Left Alt' = 'button 2'; 'Space' = 'button 3'; 'Left Shift' = 'button 4'; 'Z' = 'button 5'; 'X' = 'button 6'; 'C' = 'button 7'; 'V' = 'button 8'; '1' = 'Start'; '5' = 'Coin' }
# the actions worth showing, in this order (moving is the stick / D-pad / wheel everywhere)
$script:AmMenuShown = 'select', 'back', 'prevCyclePlaylist', 'nextCyclePlaylist', 'letterUp', 'letterDown', 'random', 'togglePlaylist', 'favPlaylist'

function Get-AmMenuButtons([string]$RepoRoot, [string]$ManifestDir) {
  $roles = (Get-Content -LiteralPath (Join-Path $RepoRoot 'catalog\menu-controls.json') -Raw | ConvertFrom-Json).roles
  $cap = $null; $cf = Join-Path $ManifestDir 'cabinet.json'; if (Test-Path -LiteralPath $cf) { $cap = (Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json).capabilities }
  $wheel = [bool]($cap -and $cap.wheel); $pads = [bool]($cap -and [int]$cap.gamepads -gt 0); $panel = [bool]($cap -and $cap.controlPanel)
  foreach ($a in $script:AmMenuShown) {
    $r = $roles.$a; if (-not $r) { continue }
    $nums = @($r.joy | Where-Object { $_ -match '^joyButton(\d+)$' } | ForEach-Object { [int]($_ -replace '^joyButton', '') })
    $parts = @()
    if ($wheel) { $w = @($nums | Where-Object { $script:AmG29Names.ContainsKey($_) } | ForEach-Object { $script:AmG29Names[$_] } | Select-Object -Unique); if ($w) { $parts += [pscustomobject]@{ on = 'wheel'; names = ($w -join ' / ') } } }
    if ($pads -or -not ($wheel -or $panel)) { $p = @($nums | Where-Object { $script:AmPadNames.ContainsKey($_) } | ForEach-Object { $script:AmPadNames[$_] } | Select-Object -First 2); if ($p) { $parts += [pscustomobject]@{ on = 'pad'; names = ($p -join ' / ') } } }
    if ($panel) { $k = @($r.keys | Where-Object { $script:AmPanelKeys.ContainsKey($_) } | ForEach-Object { $script:AmPanelKeys[$_] }); if (-not $k) { $k = @($nums | Select-Object -First 1 | ForEach-Object { "button $($_ + 1)" }) }; if ($k) { $parts += [pscustomobject]@{ on = 'panel'; names = ($k -join ' / ') } } }
    $kb = @(@($(if (-not $panel) { $r.letters }) + @($r.keys | Where-Object { $_ -notin $script:AmPanelKeys.Keys })) | Where-Object { $_ } | Select-Object -First 1)
    if ($kb) { $parts += [pscustomobject]@{ on = 'keyboard'; names = ($kb -join ' / ') } }
    [pscustomobject]@{ action = $a; does = [string]$r.does; parts = $parts; text = (($parts | ForEach-Object { $_.names }) -join '   |   ') }
  }
}
