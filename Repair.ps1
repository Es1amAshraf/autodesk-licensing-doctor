<#
    Repair.ps1  -  Phase 4: REPAIR / REINSTALL official licensing components
    ---------------------------------------------------------------------------
    Restores a healthy Autodesk single-user (Sign-in) licensing setup after
    Phase 3 cleanup.  PREVIEW by default; add -Apply to run.

    It does:
      1. Pre-flight checks (admin, pending reboot, Windows Installer)
      2. Reset the ADLS service state        -> fixes "Connection Lost"
      3. Re-point 'Current' at the newest genuine build and drop unsigned
         stub build folders (what non-genuine activators leave behind)
      4. Restart + fix startup of the services (ADLS, Access)
      5. Clear the licensing/token cache and the sign-in window profile
      6. Install official components (ADLS, AdSSO, Genuine, WebView2) that are missing
      7. Verify everything (service + files + WebView2 + connectivity to Autodesk)

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
# 3. Licensing build folder ('Current' junction)
# ---------------------------------------------------------------------------
# Non-genuine activators replace the licensing stack with a doctored old build
# and re-point 'Current' at it. The genuine builds are still on the disk, so
# the repair is to point 'Current' back at the newest genuine one - no download.
Section 'Licensing build folder'

function Test-GenuineAdlsBuild {
    param([string]$Path)
    # A real build folder carries the signed agent, the signed service or the
    # signed helper; a planted stub usually holds only an unsigned fake.
    foreach ($rel in @('AdskLicensingAgent\AdskLicensingAgent.exe',
                       'AdskLicensingService\AdskLicensingService.exe',
                       'AdskLicensingInstHelper.exe')) {
        $cand = Join-Path $Path $rel
        if (-not (Test-Path -LiteralPath $cand)) { continue }
        $sig = Get-AuthenticodeSignature -LiteralPath $cand -ErrorAction SilentlyContinue
        if ($sig -and $sig.Status -eq 'Valid' -and $sig.SignerCertificate -and ($sig.SignerCertificate.Subject -match 'Autodesk')) { return $true }
    }
    return $false
}

$curPath = Join-Path $adskLicensingRoot 'Current'
$builds = @()
if (Test-Path -LiteralPath $adskLicensingRoot) {
    $builds = @(Get-ChildItem -LiteralPath $adskLicensingRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
                Sort-Object { [version]$_.Name })
}
if (Test-Path -LiteralPath $curPath) {
    $curItem   = Get-Item -LiteralPath $curPath -Force -ErrorAction SilentlyContinue
    $isLink    = $curItem -and (($curItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    $curTarget = if ($curItem) { (@($curItem.Target)[0] -replace '[\\/]+$', '') } else { $null }
    $genuine   = @($builds | Where-Object { Test-GenuineAdlsBuild $_.FullName })
    $newest    = if ($genuine.Count) { $genuine[-1] } else { $null }

    if (-not $isLink) {
        Write-Host '  [WARN] AdskLicensing\Current is not a junction - left alone' -ForegroundColor Yellow
    } elseif (-not $newest) {
        Write-Host '  [WARN] no genuine AdskLicensing build found - a reinstall is needed (see sources below)' -ForegroundColor Yellow
    } elseif ($curTarget -ne $newest.FullName) {
        $from = if ($curTarget) { Split-Path -Leaf $curTarget } else { '?' }
        $to   = $newest.Name
        Step ("Point AdskLicensing\Current back at the genuine build {0} (now: {1})" -f $to, $from) {
            cmd /c rmdir "$curPath" | Out-Null
            $out = cmd /c mklink /J "$curPath" "$($newest.FullName)" 2>&1
            if ($LASTEXITCODE -ne 0) { throw ('mklink failed: ' + ($out -join ' ')) }
        }
    } else {
        Info ('AdskLicensing\Current -> ' + $newest.Name + ' (genuine build - OK)')
    }

    # A numbered build folder that holds no signed Autodesk binary is a planted
    # stub, not a real build; drop it once 'Current' no longer needs it.
    foreach ($b in $builds) {
        if ($newest -and $b.FullName -eq $newest.FullName) { continue }
        if ($curTarget -eq $b.FullName) { continue }
        if (Test-GenuineAdlsBuild $b.FullName) { continue }
        $bp = $b.FullName
        Step ("Remove non-genuine licensing build folder {0} (unsigned stub)" -f $b.Name) { Remove-Item -LiteralPath $bp -Recurse -Force }
    }
} else {
    Info 'AdskLicensing\Current not found'
}

# ---------------------------------------------------------------------------
# 4. Restart + fix services
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
# 5. Clear sign-in token cache (forces clean re-authentication)
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
    # 'EBWebView*' also catches a profile something renamed (EBWebView.broken):
    # the live profile is exactly "EBWebView", so any sibling with that prefix
    # is a stale copy and gets rebuilt on the next sign-in attempt.
    $eb = @(Get-ChildItem -LiteralPath $agentLocal -Recurse -Directory -Filter 'EBWebView*' -ErrorAction SilentlyContinue)
    foreach ($d in $eb) {
        $dp = $d.FullName
        Step ("Clear sign-in window profile {0}" -f $dp) { Remove-Item -LiteralPath $dp -Recurse -Force }
    }
    if ($eb.Count -eq 0) { Info 'No sign-in window profile found (nothing to clear)' }
}

# ---------------------------------------------------------------------------
# 6. Install / repair official components
# ---------------------------------------------------------------------------
Section 'Official components'

# What is already installed is checked first: it is cheap, and when every
# component is present the big installers are never even looked for (scanning a
# full product image takes minutes) - and never run (re-running an installer
# over a healthy copy adds nothing; the Edge WebView2 bootstrapper even held
# the whole repair forever in the lab run).
$script:InstallTimeoutMin = 20
$wv2Key = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

$adlsOk = $false
if ((Get-Service 'AdskLicensingService' -ErrorAction SilentlyContinue) -and (Test-Path -LiteralPath $adskLicensingRoot)) {
    $adlsOk = [bool](@(Get-ChildItem -LiteralPath $adskLicensingRoot -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match '^\d+(\.\d+)+$' -and (Test-GenuineAdlsBuild $_.FullName) }).Count)
}
$adssOk = [bool](@(
    (Join-Path $commonFiles 'AdSSO'),
    (Join-Path $env:ProgramFiles 'Autodesk\AdskIdentityManager'),
    (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\AdskIdentityManager')
) | Where-Object { Test-Path -LiteralPath $_ })
$genuineOk = [bool](@(
    (Join-Path $env:ProgramFiles 'Autodesk\Genuine Service\GenuineService.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\Genuine Service\GenuineService.exe')
) | Where-Object { Test-Path -LiteralPath $_ })
$wv2Ok = Test-Path -LiteralPath $wv2Key

# auto-detect in -InstallerDir (only for a component that is missing)
if ((-not ($adlsOk -and $adssOk -and $genuineOk -and $wv2Ok)) -and $InstallerDir -and (Test-Path -LiteralPath $InstallerDir)) {
    # Get-ChildItem ignores a name -Include filter when the path comes from
    # -LiteralPath, which would let any file in this folder match the name
    # patterns below, so the extension filter is explicit instead.
    $files = @(Get-ChildItem -LiteralPath $InstallerDir -File -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.exe','.msi' } |
               Sort-Object { if ($_.FullName -match '\\x64\\') { 0 } else { 1 } })   # prefer the 64-bit payload
    if (-not $AdlsInstaller)    { $AdlsInstaller    = ($files | Where-Object { $_.Name -match 'Licensing|AdskLicensing|DesktopLicensing' } | Select-Object -First 1).FullName }
    if (-not $AdSsoInstaller)   { $AdSsoInstaller   = ($files | Where-Object { $_.Name -match 'AdSSO|SingleSignOn|SSO' }             | Select-Object -First 1).FullName }
    if (-not $GenuineInstaller) { $GenuineInstaller = ($files | Where-Object { $_.Name -match 'Genuine' }                            | Select-Object -First 1).FullName }
    if (-not $WebView2Installer){ $WebView2Installer= ($files | Where-Object { $_.Name -match 'WebView2|WebView' }                   | Select-Object -First 1).FullName }
}

# A product's own install image carries the exact component builds it needs, so
# the usual places are probed too (the wildcard path is intentional: a name
# -Include filter is ignored with -LiteralPath, which would match anything).
if ($adlsOk -and $adssOk -and $genuineOk -and $wv2Ok) {
    Info 'All official components are present - the installer scan is skipped'
} elseif (-not $AdlsInstaller -or -not $AdSsoInstaller) {
    $images = @('C:\Autodesk\*\x64', 'C:\Autodesk\*\*\x64')
    if (-not $AdlsInstaller) {
        # a product image keeps ADLS under x86\Licensing, a deployment under x64\AdskLicensing
        $adlsProbe = @()
        foreach ($root in @('C:\Autodesk\*\x64', 'C:\Autodesk\*\*\x64')) { $adlsProbe += (Join-Path $root 'AdskLicensing\*.exe') }
        foreach ($root in @('C:\Autodesk\*\x86', 'C:\Autodesk\*\*\x86')) { $adlsProbe += (Join-Path $root 'Licensing\AdskLicensing-installer.exe') }
        $AdlsInstaller = (Get-ChildItem -Path $adlsProbe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
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
    Write-Host '         <image>\x64\AdskLicensing\*.exe   (deployment)  or  <image>\x86\Licensing\AdskLicensing-installer.exe   (product image)' -ForegroundColor DarkGray
    Write-Host '         <image>\x64\AdSSO\*.exe             (identity / sign-in)' -ForegroundColor DarkGray
    Write-Host '         <image>\x64\Components\*\Genuine*   (Genuine Service)' -ForegroundColor DarkGray
    Write-Host '    2) your Autodesk account: https://manage.autodesk.com/products/all' -ForegroundColor DarkGray
    Write-Host '    3) a Custom Install / Deployment folder -> point -InstallerDir at it' -ForegroundColor DarkGray
    Write-Host '    4) WebView2 is a Microsoft component:' -ForegroundColor DarkGray
    Write-Host '         https://developer.microsoft.com/microsoft-edge/webview2' -ForegroundColor DarkGray
}

# An installer must never hang the repair (in the lab run the Edge WebView2
# bootstrapper stayed alive forever in the background and held the whole step):
# the wait has a ceiling and an installer that does not exit gets killed.
function Invoke-Pkg {
    param([string]$Label,[string]$Path,[string]$Args,[bool]$Present)
    if ($Present) {
        Info ("{0}: already present - install skipped" -f $Label)
        return
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        Info ("{0}: no installer supplied" -f $Label)
        return
    }
    Info ("{0}: {1}" -f $Label, $Path)
    Step ("Install {0}" -f $Label) {
        if ($Path -match '\.msi$') {
            $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$Path`"", '/qn', '/norestart') -PassThru
        } else {
            $argList = if ($Args) { $Args.Split(' ') } else { @('/S') }
            $p = Start-Process -FilePath $Path -ArgumentList $argList -PassThru
        }
        if (-not $p.WaitForExit($script:InstallTimeoutMin * 60 * 1000)) {
            try { $p.Kill() } catch { }
            throw ("still running after {0} min - killed (a silent installer must finish on its own)" -f $script:InstallTimeoutMin)
        }
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw ("exit code " + $p.ExitCode) }
    }
}
# ADLS is an InstallBuilder package: its official unattended parameters come
# from its own package manifest (`installParams="--mode unattended
# --unattendedmodeui none"` in pkg.licensing.xml), not from '/S'. An explicit
# -SilentArgs still wins.
$adlsArgs = if ($PSBoundParameters.ContainsKey('SilentArgs')) { $SilentArgs } else { '--mode unattended --unattendedmodeui none' }
Invoke-Pkg -Label 'ADLS'     -Path $AdlsInstaller     -Args $adlsArgs         -Present $adlsOk
Invoke-Pkg -Label 'AdSSO'    -Path $AdSsoInstaller    -Args $SilentArgs       -Present $adssOk
Invoke-Pkg -Label 'Genuine'  -Path $GenuineInstaller  -Args $SilentArgs       -Present $genuineOk
# the WebView2 installers (Evergreen bootstrapper and the standalone package)
# both accept /silent /install
Invoke-Pkg -Label 'WebView2' -Path $WebView2Installer -Args '/silent /install' -Present $wv2Ok

# A component that is absent and has no installer never gets invented here: say
# where the official one comes from instead.
if (-not (Test-Path -LiteralPath $adskLicensingRoot) -and -not $AdlsInstaller) {
    Show-ComponentSources 'AdskLicensing (ADLS)'
}
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
# 7. Verify
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
# the official installer puts the exe either straight inside the folder or
# one level down in a version folder (e.g. ...\AdskIdentityManager\1.19.2.0\)
$idm = @(
    (Join-Path $env:ProgramFiles 'Autodesk\AdskIdentityManager'),
    (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\AdskIdentityManager')
) | Where-Object { Test-Path -LiteralPath $_ } | ForEach-Object {
    Join-Path $_ 'AdskIdentityManager.exe'
    Get-ChildItem -LiteralPath $_ -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Join-Path $_.FullName 'AdskIdentityManager.exe' }
} | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
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
