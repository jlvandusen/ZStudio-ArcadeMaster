<#
.SYNOPSIS
  Points every FFB Arcade Plugin config (FFBPlugin.ini) at the cabinet's wheel, so the game's force feedback reaches it.
  Dry run by default; -Apply backs up each changed file to <file>.am-ffbdevice-<timestamp>.bak first.

  The plugin only drives the device whose SDL id equals DeviceGUID, and the id it computes depends on the SDL2.dll
  that sits beside it in the game folder: SDL before 2.26 writes the G29 as 030000006d0400004fc2000000000000, SDL 2.26
  and later adds a checksum of the device name (03004ed76d04...). A config copied from another game or another PC can
  name an id its own SDL never produces, or another device (an Xbox pad), and then the wheel gets no force at all.

  For each FFBPlugin.ini this asks THAT folder's SDL2.dll (a temporary copy, through a small helper built with the
  .NET compiler, 32- or 64-bit to match) for the ids of the controllers present, picks the wheel (-Wheel, a piece of
  its name), and compares. Folders whose SDL2.dll can't be read are left alone and reported.
.EXAMPLE
  tools\Repair-FFBPluginDevice.ps1                 # dry run: what would change
  tools\Repair-FFBPluginDevice.ps1 -Apply
#>
param(
  [string[]]$Root = @('D:\Arcade PC', 'E:\DRIVE Collection\collections\TeknoParrot\roms', 'D:\FLIGHT Collection'),
  [string]$Wheel = 'Racing Wheel',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
$work = Join-Path $env:TEMP ('am-ffbdevice-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $work | Out-Null
try {
  # the helper: lists SDL's controllers as "<index>|<guid>|<name>", using whatever SDL2.dll sits beside it
  $src = @'
using System; using System.Runtime.InteropServices; using System.Text;
class P {
  [StructLayout(LayoutKind.Sequential)] struct G { public ulong a; public ulong b; }
  [DllImport("SDL2.dll", CallingConvention=CallingConvention.Cdecl)] static extern int SDL_Init(uint f);
  [DllImport("SDL2.dll", CallingConvention=CallingConvention.Cdecl)] static extern int SDL_NumJoysticks();
  [DllImport("SDL2.dll", CallingConvention=CallingConvention.Cdecl)] static extern G SDL_JoystickGetDeviceGUID(int i);
  [DllImport("SDL2.dll", CallingConvention=CallingConvention.Cdecl)] static extern IntPtr SDL_JoystickNameForIndex(int i);
  static void Main() {
    SDL_Init(0x200);
    for (int i = 0; i < SDL_NumJoysticks(); i++) {
      var g = SDL_JoystickGetDeviceGUID(i); var sb = new StringBuilder();
      foreach (var b in BitConverter.GetBytes(g.a)) sb.Append(b.ToString("x2"));
      foreach (var b in BitConverter.GetBytes(g.b)) sb.Append(b.ToString("x2"));
      Console.WriteLine(i + "|" + sb + "|" + Marshal.PtrToStringAnsi(SDL_JoystickNameForIndex(i)));
    }
  }
}
'@
  Set-Content (Join-Path $work 'probe.cs') $src -Encoding ascii
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
  foreach ($plat in 'x86', 'x64') { & $csc /nologo "/platform:$plat" "/out:$work\probe-$plat.exe" "$work\probe.cs" | Out-Null }

  $inis = foreach ($r in $Root) { if (Test-Path -LiteralPath $r) { robocopy $r "$env:TEMP\am-none" FFBPlugin.ini /S /L /NJH /NJS /NDL /NC /NS /XJ /R:0 /W:0 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '*\FFBPlugin.ini' } } }
  $byDll = @{}   # SDL2.dll hash -> wheel id (one probe per distinct SDL build)
  $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $ok = 0; $changed = 0; $unknown = New-Object System.Collections.Generic.List[string]
  foreach ($ini in $inis | Sort-Object -Unique) {
    $dir = Split-Path $ini; $dll = Join-Path $dir 'SDL2.dll'
    $raw = [IO.File]::ReadAllBytes($ini)   # written back in its own encoding (the plugin reads it with the Windows INI API)
    $enc = if ($raw.Length -ge 2 -and $raw[0] -eq 0xFF -and $raw[1] -eq 0xFE) { New-Object Text.UnicodeEncoding($false, $true) }
           elseif ($raw.Length -ge 3 -and $raw[0] -eq 0xEF -and $raw[1] -eq 0xBB -and $raw[2] -eq 0xBF) { New-Object Text.UTF8Encoding($true) }
           else { [Text.Encoding]::Default }
    $text = [IO.File]::ReadAllText($ini, $enc)
    $m = [regex]::Match($text, '(?m)^\s*DeviceGUID\s*=\s*(\S*)\s*$')
    if (-not $m.Success) { $unknown.Add("$dir (no DeviceGUID line)"); continue }
    if (-not (Test-Path -LiteralPath $dll)) { $unknown.Add("$dir (no SDL2.dll beside the plugin)"); continue }
    $h = (Get-FileHash -LiteralPath $dll -Algorithm SHA1).Hash
    if (-not $byDll.ContainsKey($h)) {
      $pd = Join-Path $work $h; New-Item -ItemType Directory -Force $pd | Out-Null
      Copy-Item -LiteralPath $dll (Join-Path $pd 'SDL2.dll')
      $b = [IO.File]::ReadAllBytes((Join-Path $pd 'SDL2.dll')); $pe = [BitConverter]::ToInt32($b, 0x3C); $mach = [BitConverter]::ToUInt16($b, $pe + 4)
      $plat = if ($mach -eq 0x14c) { 'x86' } else { 'x64' }
      Copy-Item (Join-Path $work "probe-$plat.exe") (Join-Path $pd 'probe.exe')
      $lines = @(& (Join-Path $pd 'probe.exe') 2>$null)
      $w = $lines | Where-Object { ($_ -split '\|', 3)[2] -like "*$Wheel*" } | Select-Object -First 1
      $byDll[$h] = if ($w) { ($w -split '\|', 3)[1] } else { '' }
    }
    $want = $byDll[$h]; $have = $m.Groups[1].Value
    $ver = (Get-Item -LiteralPath $dll).VersionInfo.FileVersion -replace ', ', '.'
    if (-not $want) { $unknown.Add("$dir (SDL $ver did not list a controller named *$Wheel*)"); continue }
    if ($have -ieq $want) { $ok++; continue }
    $changed++
    Write-Host ("{0} {1}`n    SDL {2}: DeviceGUID {3} -> {4}" -f $(if ($Apply) { 'FIXED' } else { 'WOULD FIX' }), $dir, $ver, $have, $want)
    if ($Apply) {
      Copy-Item -LiteralPath $ini "$ini.am-ffbdevice-$stamp.bak"
      $new = $text.Substring(0, $m.Groups[1].Index) + $want + $text.Substring($m.Groups[1].Index + $m.Groups[1].Length)
      [IO.File]::WriteAllText($ini, $new, $enc)
    }
  }
  Write-Host ("{0} plugin configs: {1} already on the wheel, {2} {3}, {4} not checked" -f @($inis).Count, $ok, $changed, $(if ($Apply) { 'fixed' } else { 'to fix (dry run - add -Apply)' }), $unknown.Count)
  foreach ($u in $unknown) { Write-Host "  not checked: $u" }
} finally { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
