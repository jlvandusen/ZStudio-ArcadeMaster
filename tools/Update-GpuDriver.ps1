<#
.SYNOPSIS
  Finds the newest graphics driver for every NVIDIA / AMD card in this PC - legacy cards included - and (with
  -Install) downloads it from the maker and installs it. Check only by default.

  NVIDIA: the same lookup nvidia.com's download page uses (product list, then the newest WHQL driver for that exact
  product and Windows). A card NVIDIA has moved to a legacy branch (Kepler 474.xx, Pascal "security update" 58x.xx)
  gets that branch's newest driver, because the lookup is per product. Laptop chips use the Notebook series.
  The package is checked with Authenticode (signed by NVIDIA Corporation) and installed silently: -s -noreboot.
  AMD: AMD publishes no lookup service, so the newest "AMD Software Auto-Detect" installer is taken from amd.com (a
  Referer header is required) and started; it finds the right driver for the card, legacy GCN cards included, but
  it asks its own questions - somebody must be at the cabinet. Intel and others are reported only.

  -Install needs an admin prompt (it asks for one) and a restart afterwards. AM_SYSTEM_DRYRUN=1: everything up to the
  install command, which is printed instead of run. Downloads go to <DownloadDir> and are kept.
.EXAMPLE
  tools\Update-GpuDriver.ps1                     # what is installed, what is newest
  tools\Update-GpuDriver.ps1 -Download           # also fetch and verify the package
  tools\Update-GpuDriver.ps1 -Install            # fetch, verify, install (admin)
#>
param(
  [switch]$Download,
  [switch]$Install,
  [string]$DownloadDir = 'D:\ArcadeMaster\_downloads\drivers',
  [switch]$Json,                                   # one line of JSON per card
  [string]$Cache                                   # also write the result here (the health check reads it; refreshed once a day)
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$dry = $env:AM_SYSTEM_DRYRUN -eq '1'
if ($Install) { $Download = $true }
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ArcadeMaster-driver-check'

function Get-NvInstalledVersion([string]$winVer) {
  # Windows driver version 32.0.15.6094 -> NVIDIA 560.94 (last five digits of the last two fields)
  $d = (($winVer -split '\.')[-2..-1] -join '') -replace '\D', ''
  if ($d.Length -lt 5) { return $null }
  $d = $d.Substring($d.Length - 5); "{0}.{1}" -f [int]$d.Substring(0, 3), $d.Substring(3)
}
function Compare-Version([string]$a, [string]$b) { [version]($a + '.0') -lt [version]($b + '.0') }

$cards = @(Get-CimInstance Win32_VideoController | Where-Object { $_.PNPDeviceID -match 'VEN_(10DE|1002|8086)' })
$laptop = @(Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue | ForEach-Object { $_.ChassisTypes } | Where-Object { $_ -in 8, 9, 10, 14, 30, 31, 32 }).Count -gt 0
$win11 = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber -ge 22000
$results = @()

foreach ($c in $cards) {
  $r = [ordered]@{ card = $c.Name; vendor = ''; installed = $c.DriverVersion; latest = $null; date = $null; url = $null; newer = $false; note = '' }
  try {
    if ($c.PNPDeviceID -match 'VEN_10DE') {
      $r.vendor = 'NVIDIA'; $r.installed = Get-NvInstalledVersion $c.DriverVersion
      $series = ([xml](Invoke-WebRequest 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=2' -UseBasicParsing -UserAgent $ua -TimeoutSec 30).Content).LookupValueSearch.LookupValues.LookupValue
      $prods = ([xml](Invoke-WebRequest 'https://www.nvidia.com/Download/API/lookupValueSearch.aspx?TypeID=3' -UseBasicParsing -UserAgent $ua -TimeoutSec 30).Content).LookupValueSearch.LookupValues.LookupValue
      $nb = $laptop -or $c.Name -match '(?i)laptop|max-q|mobile'
      $sName = @{}; foreach ($s in $series) { $sName[[string]$s.Value] = [string]$s.Name }
      # "NVIDIA GeForce GTX 1060 6GB" -> "GeForce GTX 1060"; try the full name first, then without memory size / suffixes
      $want = @(($c.Name -replace '^NVIDIA\s+', '').Trim())
      $want += ($want[0] -replace '\s+\d+\s*GB$', '' -replace '\s+(Laptop GPU|with Max-Q Design)$', '').Trim()
      $hit = $null
      foreach ($w in ($want | Select-Object -Unique)) {
        $cands = @($prods | Where-Object { $_.Name -eq $w })
        $hit = $cands | Where-Object { ($sName[[string]$_.ParentID] -match 'Notebook') -eq $nb } | Select-Object -First 1
        if (-not $hit) { $hit = $cands | Select-Object -First 1 }
        if ($hit) { break }
      }
      if (-not $hit) { $r.note = "not in NVIDIA's product list (name '$($c.Name)')"; $results += [pscustomobject]$r; continue }
      $osId = if ($win11) { 135 } else { 57 }
      $dch = 1   # every driver for Windows 10 / 11 since 2019 is DCH
      $q = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php?func=DriverManualLookup&psid=$($hit.ParentID)&pfid=$($hit.Value)&osID=$osId&languageCode=1033&isWHQL=1&dch=$dch&sort1=0&numberOfResults=1"
      $ans = Invoke-RestMethod $q -UserAgent $ua -TimeoutSec 30
      if (-not $ans.IDS) { $r.note = 'NVIDIA returned no driver for this product / Windows'; $results += [pscustomobject]$r; continue }
      $i = @($ans.IDS)[0].downloadInfo
      $r.latest = [uri]::UnescapeDataString($i.Version); $r.date = [uri]::UnescapeDataString($i.ReleaseDateTime); $r.url = $i.DownloadURL
      $r.note = "$($sName[[string]$hit.ParentID]) / $($hit.Name): $([uri]::UnescapeDataString($i.Name))"
      $r.newer = $r.installed -and (Compare-Version $r.installed $r.latest)
    }
    elseif ($c.PNPDeviceID -match 'VEN_1002') {
      $r.vendor = 'AMD'
      # AMD: no lookup service. The Auto-Detect installer on amd.com picks the driver for the card (legacy GCN too).
      $page = (Invoke-WebRequest 'https://www.amd.com/en/support/download/drivers.html' -UseBasicParsing -UserAgent $ua -TimeoutSec 30).Content
      $m = [regex]::Match($page, 'https://drivers\.amd\.com/drivers/installer/[^"''\s]+minimalsetup[^"''\s]+\.exe')
      if ($m.Success) { $r.url = $m.Value; $r.latest = ([regex]::Match($m.Value, 'edition-([\d.]+)')).Groups[1].Value; $r.newer = $true; $r.note = 'AMD Auto-Detect installer (interactive - picks the driver itself)' }
      else { $r.note = 'could not find the AMD Auto-Detect installer link on amd.com' }
    }
    else { $r.vendor = 'Intel'; $r.note = 'Intel: use Intel Driver & Support Assistant (not automated here)' }
  } catch { $r.note = "lookup failed: $($_.Exception.Message)" }
  $results += [pscustomobject]$r
}

if ($Cache) { New-Item -ItemType Directory -Force (Split-Path $Cache) | Out-Null; [IO.File]::WriteAllText($Cache, ([ordered]@{ checked = (Get-Date).ToString('s'); cards = @($results) } | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false)) }
foreach ($r in $results) {
  if ($Json) { $r | ConvertTo-Json -Compress; continue }
  Write-Host ("{0} ({1})" -f $r.card, $r.vendor) -ForegroundColor Cyan
  Write-Host ("  installed {0}   newest {1} {2}" -f $r.installed, $r.latest, $(if ($r.date) { "($($r.date))" }))
  Write-Host ("  {0}" -f $r.note)
  Write-Host ("  {0}" -f $(if ($r.newer) { 'UPDATE AVAILABLE' } elseif ($r.latest) { 'up to date' } else { '' })) -ForegroundColor $(if ($r.newer) { 'Yellow' } else { 'Green' })
}
if (-not $Download) { return }

foreach ($r in @($results | Where-Object { $_.newer -and $_.url })) {
  New-Item -ItemType Directory -Force $DownloadDir | Out-Null
  $file = Join-Path $DownloadDir ([IO.Path]::GetFileName(([uri]$r.url).AbsolutePath))
  if (-not (Test-Path $file)) {
    Write-Host "downloading $($r.url)"
    $hdr = @{ 'User-Agent' = $ua }; if ($r.vendor -eq 'AMD') { $hdr['Referer'] = 'https://www.amd.com/' }
    Invoke-WebRequest $r.url -OutFile "$file.part" -Headers $hdr -UseBasicParsing -TimeoutSec 3600
    Move-Item "$file.part" $file -Force
  }
  $sig = Get-AuthenticodeSignature $file
  $signer = "$($sig.SignerCertificate.Subject)"
  $okSigner = if ($r.vendor -eq 'NVIDIA') { $signer -match 'O=NVIDIA Corporation' } else { $signer -match 'O=Advanced Micro Devices' }
  if ($sig.Status -ne 'Valid' -or -not $okSigner) { throw "signature check failed for $file ($($sig.Status), $signer) - not installing" }
  Write-Host ("  {0}: {1:N0} MB, signature valid ({2})" -f (Split-Path $file -Leaf), ((Get-Item $file).Length / 1MB), ($signer -replace '^CN=([^,]+).*', '$1'))
  if (-not $Install) { continue }

  $instArgs = if ($r.vendor -eq 'NVIDIA') { '-s -noreboot -noeula' } else { '' }   # AMD Auto-Detect: interactive
  if ($dry) { Write-Host "DRY RUN (AM_SYSTEM_DRYRUN=1): would run elevated: `"$file`" $instArgs"; continue }
  $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  Write-Host "installing $($r.vendor) $($r.latest) - the screen goes black for a moment; restart afterwards"
  try { $p = if ($admin) { Start-Process $file -ArgumentList $instArgs -PassThru -Wait } else { Start-Process $file -ArgumentList $instArgs -Verb RunAs -PassThru -Wait } }
  catch { Write-Warning "not installed: Windows' admin prompt was cancelled or timed out (nobody answered it). The package is kept in $DownloadDir - run Tools > Graphics Driver at the cabinet and press Yes."; continue }
  Write-Host "  installer exit code $($p.ExitCode) $(if ($p.ExitCode -in 0, 1) { '(ok - restart to finish)' } else { '(see %ProgramData%\NVIDIA Corporation\Installer2 logs)' })"
}
