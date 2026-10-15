<#
    Repair.ps1  -  Phase 4: REPAIR / REINSTALL official licensing components
    ---------------------------------------------------------------------------
    Restores a healthy Autodesk single-user (Sign-in) licensing setup after
    Phase 3 cleanup.  PREVIEW by default; add -Apply to run.

    It does:
      1. Pre-flight checks (admin, pending reboot, Windows Installer)
      2. Reset the ADLS service state        -> fixes "Connection Lost"
      3. Restart + fix startup of the services (ADLS, Access)
      4. Clear the licensing/token cache and the sign-in window profile
      5. Install/repair official components (ADLS, AdSSO, Genuine, WebView2) if provided
      6. Verify everything (service + files + WebView2 + connectivity to Autodesk)

    Official installers (optional but recommended). Point -InstallerDir at a
    folder that contains them, or pass each path explicitly. They are matched
    by name, and the product's own install image is searched automatically:
        *Licensing* / *AdskLicensing* / *DesktopLicensing*  -> ADLS
        *AdSSO* / *SingleSignOn*                            -> AdSSO
        *Genuine*                                           -> Genuine Service
        *WebView2*                                          -> Edge WebView2 (Microsoft)

    This script never downloads anything. If a component is missing and no
    installer was supplied, it prints exactly where to get the official one.

    Usage:
      .\Repair.ps1                                   # preview
      .\Repair.ps1 -Apply                            # reset + verify
      .\Repair.ps1 -Apply -InstallerDir "D:\Installers"
      .\Repair.ps1 -Apply -AdlsInstaller "C:\...\Autodesk_Licensing_Service.exe"
      .\Repair.ps1 -Apply -WebView2Installer "C:\...\MicrosoftEdgeWebview2Setup.exe"
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$InstallerDir,
    [string]$AdlsInstaller,
    [string]$AdSsoInstaller,
    [string]$GenuineInstaller,
    [string]$WebView2Installer,
    [string]$SilentArgs = '/S',
    [switch]$SkipReset,
    [switch]$SkipConnectivity
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$script:Changes = 0
$script:Errors  = 0

function Step {
    param([string]$Desc, [scriptblock]$Do)
    if ($script:Apply) {
        try { & $Do; Write-Host ("  [ done ] {0}" -f $Desc) -ForegroundColor Green; $script:Changes++ }
        catch { Write-Host ("  [ FAIL ] {0} -> {1}" -f $Desc, $_.Exception.Message) -ForegroundColor Red; $script:Errors++ }
    } else { Write-Host ("  [preview] {0}" -f $Desc) -ForegroundColor DarkGray }
}
function Section { param([string]$t) Write-Host ''; Write-Host ("== {0} ==" -f $t) -ForegroundColor Cyan }
function Info { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Test-TcpPort {
    param([string]$ComputerName,[int]$Port=443,[int]$TimeoutMs=4000)
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $iar = $c.BeginConnect($ComputerName,$Port,$null,$null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs,$false)) { $c.Close(); return $false }
        $c.EndConnect($iar); $c.Close(); return $true
    } catch { return $false }
}

$isAdmin = Test-IsAdmin
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   Autodesk Licensing Doctor  -  Phase 4: Repair' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("   Mode  : {0}" -f $(if ($Apply) { 'APPLY (will make changes)' } else { 'PREVIEW (nothing changes)' })) -ForegroundColor $(if ($Apply) {'Yellow'} else {'Green'})
Write-Host ("   Admin : {0}" -f $isAdmin)
if ($Apply -and -not $isAdmin) { Write-Host '   ERROR: -Apply needs an administrator shell.' -ForegroundColor Red; exit 1 }

$commonFiles = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared'
$adskLicensingRoot = Join-Path $commonFiles 'AdskLicensing'

# ---------------------------------------------------------------------------
# 1. Pre-flight
# ---------------------------------------------------------------------------
Section 'Pre-flight'
$pending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
if ($pending) { Write-Host '  WARNING: a reboot is pending - reboot first for best results' -ForegroundColor Yellow }
else { Info 'No pending reboot' }
$msi = Get-Service msiserver -ErrorAction SilentlyContinue
if ($msi) { Info 'Windows Installer service available' } else { Write-Host '  Windows Installer service not found' -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# 2. Reset ADLS state  (fixes "Desktop Licensing Service - Connection Lost")
# ---------------------------------------------------------------------------
Section 'Reset licensing service state'
if ($SkipReset) {
    Info 'skipped (-SkipReset)'
} else {
    foreach ($svc in @('AdskLicensingService','AdskLicensingAgent')) {
        $s = Get-Service $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') { $sn = $svc; Step ("Stop {0}" -f $svc) { Stop-Service -Name $sn -Force } }
    }
    # the service's runtime state folder (safe to clear; regenerated on start)
    $stateDir = Join-Path $env:ProgramData 'Autodesk\AdskLicensing'
    if (Test-Path -LiteralPath $stateDir) {
        $sd = $stateDir
        Step ("Clear ADLS state folder {0}" -f $stateDir) { Remove-Item -LiteralPath $sd -Recurse -Force }
    }
    # licensing cache / LGS
    $lgs = Join-Path $env:ProgramData 'Autodesk\CLM\LGS'
    if (Test-Path -LiteralPath $lgs) { $lg = $lgs; Step ("Clear licensing cache {0}" -f $lgs) { Remove-Item -LiteralPath $lg -Recurse -Force } }
}

# ---------------------------------------------------------------------------
# 3. Restart + fix services
# ---------------------------------------------------------------------------
Section 'Services'
$adls = Get-Service 'AdskLicensingService' -ErrorAction SilentlyContinue
if ($adls) {
    Step 'Set AdskLicensingService to Automatic' { Set-Service -Name AdskLicensingService -StartupType Automatic -ErrorAction SilentlyContinue }
    Step 'Start AdskLicensingService' { Start-Service -Name AdskLicensingService -ErrorAction SilentlyContinue }
} else {
    Write-Host '  AdskLicensingService is missing - supply the official installer with -AdlsInstaller' -ForegroundColor Yellow
}
foreach ($extra in @('AdskAccessServiceHost')) {
    $s = Get-Service $extra -ErrorAction SilentlyContinue
    if ($s) { $en = $extra; Step ("Start {0}" -f $extra) { Start-Service -Name $en -ErrorAction SilentlyContinue } }
}

# ---------------------------------------------------------------------------
# 4. Clear sign-in token cache (forces clean re-authentication)
# ---------------------------------------------------------------------------
Section 'Sign-in token cache'
foreach ($p in @(
    (Join-Path $env:LOCALAPPDATA 'Autodesk\Web Services'),
    (Join-Path $env:APPDATA 'Autodesk\Web Services'))) {
    if (Test-Path -LiteralPath $p) { $pp = $p; Step ("Clear token cache {0}" -f $p) { Remove-Item -LiteralPath $pp -Recurse -Force } }
}
Info 'Products will ask you to sign in again after this.'

# The sign-in window itself is rendered with Edge WebView2, and its profile can
# hold a stale/corrupt session that makes a product fail *before* the window
# ever opens ("Licensing error - An error occurred"). The profile is rebuilt on
# the next sign-in attempt; the agent binaries next to it are left alone.
$agentLocal = Join-Path $env:LOCALAPPDATA 'Autodesk\AdskLicensingAgent'
if (Test-Path -LiteralPath $agentLocal) {
    $eb = @(Get-ChildItem -LiteralPath $agentLocal -Recurse -Directory -Filter 'EBWebView' -ErrorAction SilentlyContinue)
    foreach ($d in $eb) {
        $dp = $d.FullName
        Step ("Clear sign-in window profile {0}" -f $dp) { Remove-Item -LiteralPath $dp -Recurse -Force }
    }
    if ($eb.Count -eq 0) { Info 'No sign-in window profile found (nothing to clear)' }
}

# ---------------------------------------------------------------------------
# 5. Install / repair official components
# ---------------------------------------------------------------------------
Section 'Official components'

# auto-detect in -InstallerDir
if ($InstallerDir -and (Test-Path -LiteralPath $InstallerDir)) {
    # Get-ChildItem ignores a name -Include filter when the path comes from
    # -LiteralPath, which would let any file in this folder match the name
    # patterns below, so the extension filter is explicit instead.
    $files = @(Get-ChildItem -LiteralPath $InstallerDir -File -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.exe','.msi' })
    if (-not $AdlsInstaller)    { $AdlsInstaller    = ($files | Where-Object { $_.Name -match 'Licensing|AdskLicensing|DesktopLicensing' } | Select-Object -First 1).FullName }
    if (-not $AdSsoInstaller)   { $AdSsoInstaller   = ($files | Where-Object { $_.Name -match 'AdSSO|SingleSignOn|SSO' }             | Select-Object -First 1).FullName }
    if (-not $GenuineInstaller) { $GenuineInstaller = ($files | Where-Object { $_.Name -match 'Genuine' }                            | Select-Object -First 1).FullName }
    if (-not $WebView2Installer){ $WebView2Installer= ($files | Where-Object { $_.Name -match 'WebView2|WebView' }                   | Select-Object -First 1).FullName }
}

# A product's own install image carries the exact component builds it needs, so
# the usual places are probed too (the wildcard path is intentional: a name
# -Include filter is ignored with -LiteralPath, which would match anything).
if (-not $AdlsInstaller -or -not $AdSsoInstaller) {
    $images = @('C:\Autodesk\*\x64', 'C:\Autodesk\*\*\x64')
    if (-not $AdlsInstaller) {
        $AdlsInstaller = (Get-ChildItem -Path ($images | ForEach-Object { Join-Path $_ 'AdskLicensing\*.exe' }) -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if (-not $AdSsoInstaller) {
        $AdSsoInstaller = (Get-ChildItem -Path ($images | ForEach-Object { Join-Path $_ 'AdSSO\*.exe' }) -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if (-not $GenuineInstaller) {
        $GenuineInstaller = (Get-ChildItem -Path ($images | ForEach-Object { Join-Path $_ 'Components\*\Genuine*\*.exe' }) -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
}
if ($AdlsInstaller -and -not $InstallerDir) { Info ('Found an official ADLS installer on this machine: ' + $AdlsInstaller) }

# Where an official component comes from. This script installs only what it is
# given and never downloads anything, so be explicit about the sources.
function Show-ComponentSources {
    param([string]$What)
    Write-Host ("  {0} is missing and no installer was supplied. Official sources:" -f $What) -ForegroundColor Yellow
    Write-Host '    1) the product image (best: it matches the product version)' -ForegroundColor DarkGray
    Write-Host '         <image>\x64\AdskLicensing\*.exe     (ADLS)' -ForegroundColor DarkGray
    Write-Host '         <image>\x64\AdSSO\*.exe             (identity / sign-in)' -ForegroundColor DarkGray
    Write-Host '         <image>\x64\Components\*\Genuine*   (Genuine Service)' -ForegroundColor DarkGray
    Write-Host '    2) your Autodesk account: https://manage.autodesk.com/products/all' -ForegroundColor DarkGray
    Write-Host '    3) a Custom Install / Deployment folder -> point -InstallerDir at it' -ForegroundColor DarkGray
    Write-Host '    4) WebView2 is a Microsoft component:' -ForegroundColor DarkGray
    Write-Host '         https://developer.microsoft.com/microsoft-edge/webview2' -ForegroundColor DarkGray
}

function Invoke-Pkg {
    param([string]$Label,[string]$Path,[string]$Args)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Info ("{0}: no installer supplied" -f $Label)
        return
    }
    Info ("{0}: {1}" -f $Label, $Path)
    Step ("Install {0}" -f $Label) {
        if ($Path -match '\.msi$') {
            $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$Path`"", '/qn', '/norestart') -Wait -PassThru
        } else {
            $argList = if ($Args) { $Args.Split(' ') } else { @('/S') }
            $p = Start-Process -FilePath $Path -ArgumentList $argList -Wait -PassThru
        }
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw ("exit code " + $p.ExitCode) }
    }
}
Invoke-Pkg -Label 'ADLS'     -Path $AdlsInstaller     -Args $SilentArgs
Invoke-Pkg -Label 'AdSSO'    -Path $AdSsoInstaller    -Args $SilentArgs
Invoke-Pkg -Label 'Genuine'  -Path $GenuineInstaller  -Args $SilentArgs
# the WebView2 installers (Evergreen bootstrapper and the standalone package)
# both accept /silent /install
Invoke-Pkg -Label 'WebView2' -Path $WebView2Installer -Args '/silent /install'

# A component that is absent and has no installer never gets invented here: say
# where the official one comes from instead.
if (-not (Test-Path -LiteralPath $adskLicensingRoot) -and -not $AdlsInstaller) {
    Show-ComponentSources 'AdskLicensing (ADLS)'
}
$wv2Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
if (-not (Test-Path -LiteralPath $wv2Key) -and -not $WebView2Installer) {
    Show-ComponentSources 'Microsoft Edge WebView2 (the sign-in window)'
}

# report what is installed
if (Test-Path -LiteralPath $adskLicensingRoot) {
    $vers = @(Get-ChildItem -LiteralPath $adskLicensingRoot -Directory -ErrorAction SilentlyContinue)
    if ($vers) { Info ('AdskLicensing versions present: ' + (($vers.Name) -join ', ')) }
} else {
    Info 'AdskLicensing folder not present yet'
}
$helper = Get-ChildItem -LiteralPath $adskLicensingRoot -Recurse -Filter 'AdskLicensingInstHelper.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($helper) { Info ('AdskLicensingInstHelper: ' + $helper.FullName + '   (run: ' + $helper.FullName + ' list)') }

# ---------------------------------------------------------------------------
# 6. Verify
# ---------------------------------------------------------------------------
Section 'Verification'
$adls2 = Get-Service 'AdskLicensingService' -ErrorAction SilentlyContinue
if ($adls2) {
    if ($adls2.Status -eq 'Running') { Write-Host '  [ OK ] AdskLicensingService is RUNNING' -ForegroundColor Green }
    else { Write-Host ("  [WARN] AdskLicensingService state = {0}" -f $adls2.Status) -ForegroundColor Yellow }
} else {
    Write-Host '  [FAIL] AdskLicensingService is MISSING' -ForegroundColor Red
}
if (Test-Path -LiteralPath $adskLicensingRoot) { Write-Host '  [ OK ] AdskLicensing component present' -ForegroundColor Green }
else { Write-Host '  [FAIL] AdskLicensing component missing' -ForegroundColor Red }

if (Test-Path -LiteralPath $wv2Key) {
    Write-Host '  [ OK ] Microsoft Edge WebView2 present (the sign-in window can render)' -ForegroundColor Green
} else {
    Write-Host '  [WARN] Microsoft Edge WebView2 MISSING - the sign-in window cannot open' -ForegroundColor Yellow
}
$idm = @(
    (Join-Path $env:ProgramFiles 'Autodesk\AdskIdentityManager\AdskIdentityManager.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\AdskIdentityManager\AdskIdentityManager.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($idm) { Write-Host ('  [ OK ] Identity component present: ' + $idm) -ForegroundColor Green }
else { Write-Host '  [WARN] Identity component (AdskIdentityManager) not found - sign-in may not complete' -ForegroundColor Yellow }

if (-not $SkipConnectivity) {
    foreach ($h in @('registeronce.autodesk.com','genuine-software.autodesk.com','accounts.autodesk.com')) {
        if (Test-TcpPort -ComputerName $h -Port 443) { Write-Host ("  [ OK ] {0} reachable on 443" -f $h) -ForegroundColor Green }
        else { Write-Host ("  [WARN] {0} not reachable on 443" -f $h) -ForegroundColor Yellow }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
if ($Apply) {
    Write-Host ("   Applied : {0}   Failures : {1}" -f $script:Changes, $script:Errors) -ForegroundColor $(if ($script:Errors) {'Yellow'} else {'Green'})
    Write-Host ''
    Write-Host '   Next:' -ForegroundColor Cyan
    Write-Host '     1) Reboot if a reboot is pending.'
    Write-Host '     2) Open the Autodesk product and Sign In with the subscription account.'
    Write-Host '     3) Run AdskDoctor.ps1 again to confirm everything is green.'
} else {
    Write-Host '   PREVIEW only - nothing changed.' -ForegroundColor Green
    Write-Host '   Add  -Apply  to perform the repair.' -ForegroundColor Yellow
}
Write-Host ''
