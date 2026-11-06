<#
    Repair.ps1  -  Phase 4: REPAIR / REINSTALL official licensing components
    ---------------------------------------------------------------------------
    Restores a healthy Autodesk single-user (Sign-in) licensing setup after
    Phase 3 cleanup.  PREVIEW by default; add -Apply to run.

    Order matters - an ADLS installer will not replace a running service, and
    'Current' must not be re-pointed before its replacement is installed:
      1. Pre-flight checks (admin, pending reboot, Windows Installer)
      2. Clear stale AutoCAD 2027 NLM installer pointers (backed up first)
      3. Inspect the installed components (read-only; -CheckOnly exits here)
      4. Stop the licensing service and its agent processes
      5. Reset the ADLS service state        -> fixes "Connection Lost"
      6. Install the missing official components (service is stopped)
      7. Repair the licensing build folder ('Current' junction) and remove
         non-Autodesk binaries left by an activator
      8. Restart + fix startup of the services (ADLS, Access)
      9. Clear the licensing/token cache and the sign-in window profile
     10. Verify everything (service + files + WebView2 + connectivity)

    The AutoCAD 2027 setup error "the Network License Manager version you use
    does not meet the minimum requirements" is often caused by stale local NLM
    pointers, not by the installed NLM itself. Step 2 removes only those
    pointers (nlm-server-info.json, licpath.lic, old NLM registry keys and
    ADSKFLEX_LICENSE_FILE / ADSK_LICENSE_FILE / LICPATH / ACADSERVER) after
    copying them to a dedicated backup with a runnable UNDO.ps1. It never
    removes the NLM service or its installation. If this PC is the license
    server, update NLM to 11.19.9.0+ instead; use -SkipNlmFix to leave the
    pointers alone.

    Official installers: point -InstallerDir at a folder that contains them, or
    pass each path explicitly. They are matched by name, and the product's own
    install image is searched automatically:
        *Licensing* / *AdskLicensing* / *DesktopLicensing*  -> ADLS
        *AdSSO* / *SingleSignOn*                            -> AdSSO (2020-2023)
        *Identity* / *AdskIdentityManager*                  -> Identity Manager (2024+)
        *Genuine*                                           -> Genuine Service
        *WebView2*                                          -> Edge WebView2 (Microsoft)

    -AllowDownload (opt-in, off by default) fetches missing ADLS, AdSSO,
    Identity Manager and WebView2 from the vendors' official servers, and only
    uses a download whose Authenticode signature is valid and signed by the
    vendor. Without the switch nothing is ever downloaded: the script prints
    exactly where to get the official installer instead.

    Usage:
      .\Repair.ps1                                   # preview
      .\Repair.ps1 -CheckOnly                        # report what is missing, exit
      .\Repair.ps1 -Apply                            # reset + verify
      .\Repair.ps1 -Apply -AllowDownload             # fetch + install missing components
      .\Repair.ps1 -Apply -SkipNlmFix                # leave NLM pointers untouched
      .\Repair.ps1 -Apply -InstallerDir "D:\Installers"
      .\Repair.ps1 -Apply -AdlsInstaller "C:\...\Autodesk_Licensing_Service.exe"
      .\Repair.ps1 -Apply -IdentityInstaller "C:\...\AdskIdentityManager-Installer.exe"
      .\Repair.ps1 -Apply -WebView2Installer "C:\...\MicrosoftEdgeWebview2Setup.exe"
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$InstallerDir,
    [string]$AdlsInstaller,
    [string]$AdSsoInstaller,
    [string]$IdentityInstaller,
    [string]$GenuineInstaller,
    [string]$WebView2Installer,
    [string]$SilentArgs = '/S',
    [switch]$SkipReset,
    [switch]$SkipConnectivity,
    [switch]$SkipNlmFix,
    [switch]$AllowDownload,
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

# -CheckOnly answers one question ("which official components are missing?")
# and never changes anything, so it forces preview even if -Apply was passed.
if ($CheckOnly) { $Apply = $false }

$script:Changes = 0
$script:Errors  = 0

# ---------------------------------------------------------------------------
# Operation log: every run lands in %ProgramData%\UNLOCK DIGITAL\logs (or the
# folder in ADSKDOCTOR_LOGDIR) so a support request can carry it. Never fatal:
# if the folder cannot be created the run continues without a log.
# ADSKDOCTOR_NOLOG=1 turns logging off (the test suite sets it).
# ---------------------------------------------------------------------------
$script:LogPath = $null
if (-not $env:ADSKDOCTOR_NOLOG) {
    try {
        $logRoot = if ($env:ADSKDOCTOR_LOGDIR) { $env:ADSKDOCTOR_LOGDIR } else { Join-Path $env:ProgramData 'UNLOCK DIGITAL\logs' }
        New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
        $script:LogPath = Join-Path $logRoot ('repair-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -LiteralPath $script:LogPath -Force | Out-Null
    } catch { $script:LogPath = $null }
}

function Step {
    param([string]$Desc, [scriptblock]$Do)
    if ($script:Apply) {
        try { & $Do; Write-Host ("  [ done ] {0}" -f $Desc) -ForegroundColor Green; $script:Changes++ }
        catch { Write-Host ("  [ FAIL ] {0} -> {1}" -f $Desc, $_.Exception.Message) -ForegroundColor Red; $script:Errors++ }
    } else { Write-Host ("  [preview] {0}" -f $Desc) -ForegroundColor DarkGray }
}
function Section { param([string]$t) Write-Host ''; Write-Host ("== {0} ==" -f $t) -ForegroundColor Cyan }
function Info { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Protect-DirectoryAcl {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    if (-not $env:ProgramData -or -not $Path.StartsWith($env:ProgramData, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { return }

        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        if (Test-Path -LiteralPath $icacls) {
            & $icacls $Path /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" >$null 2>&1
        }
    } catch {}
}

function Expand-ArchiveSafe {
    param([string]$ZipPath, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    }
    Protect-DirectoryAcl -Path $Destination
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName -match '(^|[\\/])\.\.($|[\\/])' -or $e.FullName -match '^[\\/]') {
                throw ('unsafe archive entry (Zip Slip): ' + $e.FullName)
            }
        }
    } finally {
        $zip.Dispose()
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

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

# True only when the file exists and carries a valid Autodesk Authenticode
# signature. A planted crack binary is unsigned (or signed by somebody else).
function Test-AutodeskSignature {
    param([string]$FilePath)
    if (-not $FilePath -or -not (Test-Path -LiteralPath $FilePath)) { return $false }
    $sig = Get-AuthenticodeSignature -LiteralPath $FilePath -ErrorAction SilentlyContinue
    return [bool]($sig -and $sig.Status -eq 'Valid' -and $sig.SignerCertificate -and ($sig.SignerCertificate.Subject -match 'Autodesk'))
}

function Test-GenuineAdlsBuild {
    param([string]$Path)
    # A real build folder carries signed agent, service and helper binaries; a
    # planted stub usually holds only an unsigned fake.
    foreach ($rel in @('AdskLicensingAgent\AdskLicensingAgent.exe',
                       'AdskLicensingService\AdskLicensingService.exe',
                       'helper\AdskLicensingInstHelper.exe',
                       'AdskLicensingInstHelper.exe')) {
        if (Test-AutodeskSignature (Join-Path $Path $rel)) { return $true }
    }
    return $false
}

function Test-CompleteAdlsBuild {
    param([string]$Path)
    # The agent and the service are the two binaries every working build needs.
    # The helper lives in 'helper\' in current builds and at the root in older
    # ones, so it is not part of the completeness test.
    return [bool]((Test-Path -LiteralPath (Join-Path $Path 'AdskLicensingAgent\AdskLicensingAgent.exe')) -and
                  (Test-Path -LiteralPath (Join-Path $Path 'AdskLicensingService\AdskLicensingService.exe')))
}

function Get-AdlsBuildList {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
             Sort-Object { [version]$_.Name } |
             ForEach-Object {
                 [pscustomobject]@{
                     Name     = $_.Name
                     Path     = $_.FullName
                     Version  = [version]$_.Name
                     Genuine  = [bool](Test-GenuineAdlsBuild $_.FullName)
                     Complete = [bool](Test-CompleteAdlsBuild $_.FullName)
                 }
             })
}

function Get-AdlsCurrent {
    param([string]$Root)
    $path = Join-Path $Root 'Current'
    $result = [pscustomobject]@{
        Path = $path; Exists = $false; IsLink = $false; Target = $null
    }
    # A dangling junction is invisible to Test-Path but still occupies the
    # name, so mklink would fail with "Cannot create a file when that file
    # already exists". Get-Item -Force still sees it.
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $result }
    $result.Exists = $true
    $result.IsLink = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    $t = @($item.Target)[0]
    if ($t) { $result.Target = ($t -replace '[\\/]+$', '') }
    return $result
}

function Get-AdlsStack {
    param([string]$Root)
    $builds  = @(Get-AdlsBuildList -Root $Root)
    $usable  = @($builds | Where-Object { $_.Genuine -and $_.Complete })
    $newest  = if ($usable.Count) { $usable[-1] } else { $null }
    $current = Get-AdlsCurrent -Root $Root
    $curBuild = $null
    if ($current.Target) {
        $curBuild = @($builds | Where-Object { $_.Path -eq $current.Target }) | Select-Object -First 1
    }
    # A genuine-but-incomplete build newer than the newest usable one is a
    # failed official update: the installer must run again. An unsigned stub
    # is a crack leftover - Repair deletes it, no download needed.
    $newerIncomplete = @()
    if ($newest) {
        $newerIncomplete = @($builds | Where-Object {
            $_.Version -gt $newest.Version -and $_.Genuine -and -not $_.Complete
        })
    }
    $serviceOk = [bool](Get-Service 'AdskLicensingService' -ErrorAction SilentlyContinue)
    $currentUsable = [bool]($current.IsLink -and $curBuild -and $curBuild.Genuine -and $curBuild.Complete)
    $currentOk = [bool]($currentUsable -and $newest -and $curBuild.Path -eq $newest.Path)
    [pscustomobject]@{
        Builds          = $builds
        Usable          = $usable
        Newest          = $newest
        Current         = $current
        CurrentBuild    = $curBuild
        NewerIncomplete = $newerIncomplete
        ServiceOk       = $serviceOk
        CurrentUsable   = $currentUsable
        CurrentOk       = $currentOk
        InstallOk       = [bool]($serviceOk -and $newest -and $newerIncomplete.Count -eq 0)
        Healthy         = [bool]($serviceOk -and $newest -and $currentOk -and $newerIncomplete.Count -eq 0)
    }
}

function Get-IdentityManagerExe {
    foreach ($root in @(
        (Join-Path $env:ProgramFiles 'Autodesk\AdskIdentityManager'),
        (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\AdskIdentityManager'))) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $direct = Join-Path $root 'AdskIdentityManager.exe'
        if (Test-Path -LiteralPath $direct) { return $direct }
        foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $cand = Join-Path $d.FullName 'AdskIdentityManager.exe'
            if (Test-Path -LiteralPath $cand) { return $cand }
        }
    }
    return $null
}

function Test-LegacyAdskProduct {
    # AdSSO is the sign-in client for the 2020-2023 releases; 2024+ use the
    # Identity Manager component instead. Product folders carry the year.
    foreach ($root in @((Join-Path $env:ProgramFiles 'Autodesk'),
                        (Join-Path ${env:ProgramFiles(x86)} 'Autodesk'))) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $hit = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match '\b20(20|21|22|23)\b' })
        if ($hit.Count) { return $true }
    }
    return $false
}

function Test-AdssO {
    param([string]$Root, [string]$CommonFiles)
    # The current AdSSO MSI installs AdSSO.exe under
    #   <Program Files>\Autodesk\Autodesk AdSSO
    # (32-bit: Program Files (x86)). The old Common Files\Autodesk Shared\AdSSO
    # layout still exists on very old installs. Check the binaries, not just
    # the folder: an interrupted install can leave an empty directory.
    foreach ($base in @(
        (Join-Path $env:ProgramFiles 'Autodesk\Autodesk AdSSO'),
        (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\Autodesk AdSSO'),
        (Join-Path $CommonFiles 'AdSSO'))) {
        foreach ($leaf in @('AdSSO.exe','AdSSOClient.dll','AdpClientService.exe')) {
            if (Test-Path -LiteralPath (Join-Path $base $leaf)) { return $true }
        }
    }
    # 2020-2023 products sign in through the standalone AdSSO component even
    # when the licensing agent also carries SSOClient.config.
    if (-not (Test-LegacyAdskProduct)) { return $true }
    return $false
}

function Test-WebView2 {
    # 32-bit, 64-bit and per-user registrations; a version of 0.0.0.0 means the
    # runtime was removed. The exe fallback catches a machine whose EdgeUpdate
    # registration is damaged but whose runtime still exists.
    foreach ($k in @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}')) {
        if (Test-Path -LiteralPath $k) {
            $pv = (Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue).pv
            if (-not $pv -or $pv -ne '0.0.0.0') { return $true }
        }
    }
    foreach ($root in @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeWebView\Application'),
        (Join-Path $env:ProgramFiles 'Microsoft\EdgeWebView\Application'))) {
        if (Test-Path -LiteralPath $root) {
            $hit = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                     Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'msedgewebview2.exe') })
            if ($hit.Count) { return $true }
        }
    }
    return $false
}

$isAdmin = Test-IsAdmin
$nlmCommon = Join-Path $PSScriptRoot 'NlmCommon.ps1'
if (Test-Path -LiteralPath $nlmCommon) { . $nlmCommon }
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   Autodesk Licensing Doctor  -  Phase 4: Repair' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("   Mode  : {0}" -f $(if ($Apply) { 'APPLY (will make changes)' } else { 'PREVIEW (nothing changes)' })) -ForegroundColor $(if ($Apply) {'Yellow'} else {'Green'})
Write-Host ("   Admin : {0}" -f $isAdmin)
if ($script:LogPath) { Write-Host ("   Log   : {0}" -f $script:LogPath) -ForegroundColor DarkGray }
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
# 1b. AutoCAD 2027 NLM install blocker (targeted, backed up, reversible)
#     The 2027 installer refuses to start when stale local NLM pointers make
#     it think an old license server is configured. This removes only those
#     pointers - never the NLM service or its installation.
# ---------------------------------------------------------------------------
Section 'AutoCAD 2027 NLM install blocker'
if ($SkipNlmFix) {
    Info 'skipped (-SkipNlmFix)'
} elseif (Get-Command Invoke-NlmBlockerFix -ErrorAction SilentlyContinue) {
    $nlmResult = Invoke-NlmBlockerFix -Apply:$Apply -BackupRoot (Join-Path $PSScriptRoot 'backups') -NoHeader
    if ($nlmResult -and @($nlmResult.Errors).Count -gt 0) {
        foreach ($e in @($nlmResult.Errors)) {
            Write-Host ('  [ WARN ] {0}' -f $e) -ForegroundColor Yellow
        }
        $script:Errors += @($nlmResult.Errors).Count
    }
    if ($nlmResult.Backup) { Info ('NLM backup: {0}' -f $nlmResult.Backup) }
} else {
    Info 'NlmCommon.ps1 not present - NLM blocker check skipped'
}

# ---------------------------------------------------------------------------
# 2. Component state (read-only; -CheckOnly exits here)
# ---------------------------------------------------------------------------
Section 'Component state'
$script:InstallTimeoutMin = 20

$stack        = Get-AdlsStack -Root $adskLicensingRoot
$adlsOk       = $stack.InstallOk       # service + a complete genuine build exists
$adlsCurrent  = $stack.CurrentOk       # Current also points at the newest usable build
$adssOk       = Test-AdssO -Root $adskLicensingRoot -CommonFiles $commonFiles
$idmExe       = Get-IdentityManagerExe
$idmOk        = [bool]$idmExe
$genuineOk    = [bool](@(
    (Join-Path $env:ProgramFiles 'Autodesk\Genuine Service\GenuineService.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\Genuine Service\GenuineService.exe')
) | Where-Object { Test-Path -LiteralPath $_ })
$wv2Ok        = Test-WebView2

Info ("ADLS      : {0}" -f $(if ($adlsOk) { 'installed' } else { 'MISSING or broken' }))
if ($stack.Newest) { Info ("            newest usable build: {0}" -f $stack.Newest.Name) }
if ($adlsOk -and -not $adlsCurrent) { Info '            Current junction needs re-pointing (no installer needed)' }
Info ("AdSSO     : {0}" -f $(if ($adssOk) { 'present / not needed' } else { 'MISSING' }))
Info ("Identity  : {0}" -f $(if ($idmOk) { $idmExe } else { 'MISSING' }))
Info ("Genuine   : {0}" -f $(if ($genuineOk) { 'present' } else { 'MISSING' }))
Info ("WebView2  : {0}" -f $(if ($wv2Ok) { 'present' } else { 'MISSING' }))

# -CheckOnly: report what is missing and exit before anything is touched or
# searched. The GUI runs this first so a machine that has everything is never
# sent to a "pick the folder with the installers" dialogue.
# Genuine Service is reported in the component state but is NOT part of this
# list: it has no public download and is not required to restore sign-in
# licensing, so it must not force a folder-picking dialogue.
if ($CheckOnly) {
    $missingNames = @()
    if (-not $adlsOk)    { $missingNames += 'ADLS' }
    if (-not $adssOk)    { $missingNames += 'AdSSO' }
    if (-not $idmOk)     { $missingNames += 'Identity' }
    if (-not $wv2Ok)     { $missingNames += 'WebView2' }
    Write-Host ('CHECKRESULT missing=' + ($missingNames -join ','))
    if ($script:LogPath) { try { Stop-Transcript | Out-Null } catch { } }
    exit 0
}

# ---------------------------------------------------------------------------
# 3. Stop the licensing service and its agent processes
# ---------------------------------------------------------------------------
# The ADLS installer refuses to replace files that are still mapped by a
# running process. The old order started the service here, before the install,
# which is why an interrupted 17.0.0.16519 update kept 'Current' on 15.1.
Section 'Stop licensing services'
foreach ($svc in @('AdskLicensingService','AdskLicensingAgent')) {
    $s = Get-Service $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Stopped') {
        $sn = $svc
        Step ("Stop {0}" -f $svc) { Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue }
    }
}
foreach ($procName in @('AdskLicensingAgent','ADSKLicenseAgent','AdskLicensingInstHelper')) {
    foreach ($p in @(Get-Process -Name $procName -ErrorAction SilentlyContinue)) {
        $procId = $p.Id
        Step ("Stop the {0} process (PID {1})" -f $procName, $procId) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
# 4. Reset ADLS state  (fixes "Desktop Licensing Service - Connection Lost")
# ---------------------------------------------------------------------------
Section 'Reset licensing service state'
if ($SkipReset) {
    Info 'skipped (-SkipReset)'
} else {
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
# 5. Install / repair official components  (service is stopped)
# ---------------------------------------------------------------------------
Section 'Official components'

# auto-detect in -InstallerDir (only for a component that is missing)
if ((-not ($adlsOk -and $adssOk -and $idmOk -and $genuineOk -and $wv2Ok)) -and $InstallerDir -and (Test-Path -LiteralPath $InstallerDir)) {
    # Get-ChildItem ignores a name -Include filter when the path comes from
    # -LiteralPath, which would let any file in this folder match the name
    # patterns below, so the extension filter is explicit instead.
    $files = @(Get-ChildItem -LiteralPath $InstallerDir -File -Recurse -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.exe','.msi','.zip' } |
               Sort-Object { if ($_.FullName -match '\\x64\\') { 0 } else { 1 } })   # prefer the 64-bit payload
    if (-not $AdlsInstaller)     { $AdlsInstaller     = ($files | Where-Object { $_.Name -match 'Licensing|AdskLicensing|DesktopLicensing' } | Select-Object -First 1).FullName }
    if (-not $AdSsoInstaller)    { $AdSsoInstaller    = ($files | Where-Object { $_.Name -match 'AdSSO|SingleSignOn|SSO' }             | Select-Object -First 1).FullName }
    if (-not $IdentityInstaller) { $IdentityInstaller = ($files | Where-Object { $_.Name -match 'Identity|AdskIdentityManager|IDSDK' }  | Select-Object -First 1).FullName }
    if (-not $GenuineInstaller)  { $GenuineInstaller  = ($files | Where-Object { $_.Name -match 'Genuine' }                            | Select-Object -First 1).FullName }
    if (-not $WebView2Installer) { $WebView2Installer = ($files | Where-Object { $_.Name -match 'WebView2|WebView' }                   | Select-Object -First 1).FullName }
}

# A product's own install image carries the exact component builds it needs, so
# the usual places are probed too (the wildcard path is intentional: a name
# -Include filter is ignored with -LiteralPath, which would match anything).
if ($adlsOk -and $adssOk -and $idmOk -and $genuineOk -and $wv2Ok) {
    Info 'All official components are present - the installer scan is skipped'
} elseif (-not $AdlsInstaller -or -not $AdSsoInstaller -or -not $IdentityInstaller) {
    $images = @('C:\Autodesk\*\x64', 'C:\Autodesk\*\*\x64')
    if (-not $AdlsInstaller) {
        # a product image keeps ADLS under x86\Licensing, a deployment under x64\AdskLicensing
        $adlsProbe = @()
        foreach ($root in @('C:\Autodesk\*\x64', 'C:\Autodesk\*\*\x64')) { $adlsProbe += (Join-Path $root 'AdskLicensing\*.exe') }
        foreach ($root in @('C:\Autodesk\*\x86', 'C:\Autodesk\*\*\x86')) { $adlsProbe += (Join-Path $root 'Licensing\AdskLicensing-installer.exe') }
        $AdlsInstaller = (Get-ChildItem -Path $adlsProbe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if (-not $AdSsoInstaller) {
        $AdSsoInstaller = (Get-ChildItem -Path ($images | ForEach-Object { Join-Path $_ 'AdSSO\*' }) -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if (-not $IdentityInstaller) {
        $idmProbe = @()
        foreach ($root in $images) {
            $idmProbe += (Join-Path $root 'AdskIdentityManager\*.exe')
            $idmProbe += (Join-Path $root 'Components\*\Identity*\*.exe')
            $idmProbe += (Join-Path $root 'Components\*\AdskIdentityManager*\*.exe')
        }
        $IdentityInstaller = (Get-ChildItem -Path $idmProbe -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if (-not $GenuineInstaller) {
        $GenuineInstaller = (Get-ChildItem -Path ($images | ForEach-Object { Join-Path $_ 'Components\*\Genuine*\*.exe' }) -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
}
if ($AdlsInstaller -and -not $InstallerDir) { Info ('Found an official ADLS installer on this machine: ' + $AdlsInstaller) }

# ---------------------------------------------------------------------------
# Auto-fetch (opt-in): when a component is missing and no local installer was
# supplied, fetch the official one - ADLS and AdSSO from Autodesk's CDN,
# Identity Manager from Autodesk's update server, the Edge WebView2
# bootstrapper from Microsoft - and refuse anything whose Authenticode
# signature is not valid and signed by the vendor.
# Without -AllowDownload nothing is ever downloaded.
# ---------------------------------------------------------------------------
# Picks the actual installer out of an official archive. The AdSSO zip holds
# Adsso.msi; the ADLS zip holds AdskLicensingInstaller.exe (and possibly support
# files). Preferring MSI blindly would pick the wrong file if a future ADLS
# archive also carries one, so the component decides.
function Select-InstallerFromArchive {
    param([string]$Path, [string]$Label)
    $items = @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.exe','.msi' })
    if ($items.Count -eq 0) { return $null }
    if ($Label -match 'AdSSO') {
        $pick = @($items | Where-Object { $_.Extension -eq '.msi' -and $_.Name -match 'AdSSO' } | Select-Object -First 1)
        if ($pick.Count) { return $pick[0].FullName }
    }
    if ($Label -match 'ADLS') {
        $pick = @($items | Where-Object { $_.Extension -eq '.exe' -and $_.Name -match 'AdskLicensing' } | Select-Object -First 1)
        if ($pick.Count) { return $pick[0].FullName }
    }
    $pick = @($items | Sort-Object { if ($_.Extension -eq '.msi') { 0 } else { 1 } } | Select-Object -First 1)
    return $pick[0].FullName
}

function Get-OfficialInstaller {
    param([string]$Label, [string]$Url, [string]$OutPath, [string]$SignerLike)
    try {
        if (-not (Test-Path -LiteralPath $OutPath)) {
            Info ("{0}: downloading the official installer..." -f $Label)
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $Url -OutFile $OutPath -UseBasicParsing -TimeoutSec 1200
        }
        $f = Get-Item -LiteralPath $OutPath
        Info ("{0}: {1} ({2:N1} MB)" -f $Label, $f.Name, ($f.Length / 1MB))
        Info ("{0}: SHA256 {1}" -f $Label, (Get-FileHash -LiteralPath $OutPath -Algorithm SHA256).Hash)
        $exe = $OutPath
        if ($OutPath -match '\.zip$') {
            $ex = $OutPath + '.expanded'
            if (-not (Test-Path -LiteralPath $ex)) { Expand-ArchiveSafe -ZipPath $OutPath -Destination $ex }
            # ADLS ships an .exe, the AdSSO archive ships Adsso.msi.
            $exe = Select-InstallerFromArchive -Path $ex -Label $Label
            if (-not $exe) { throw 'the archive does not contain an installer' }
        }
        $sig = Get-AuthenticodeSignature -LiteralPath $exe
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch $SignerLike) {
            throw ("signature check failed ({0}; signer: {1})" -f $sig.Status, $sig.SignerCertificate.Subject)
        }
        Info ("{0}: signature OK - {1}" -f $Label, $sig.SignerCertificate.Subject)
        return $exe
    } catch {
        Write-Host ("  [WARN] {0}: automatic download failed - {1}" -f $Label, $_.Exception.Message) -ForegroundColor Yellow
        return $null
    }
}

if ($Apply -and $AllowDownload) {
    $dlRoot = Join-Path $env:ProgramData 'UNLOCK DIGITAL\downloads'
    New-Item -ItemType Directory -Force -Path $dlRoot | Out-Null
    Protect-DirectoryAcl -Path $dlRoot
    if (-not $adlsOk -and -not $AdlsInstaller) {
        $AdlsInstaller = Get-OfficialInstaller -Label 'ADLS' -Url 'https://damassets.autodesk.net/content/dam/autodesk/www/files/AdskLicensingInstaller-win-17.0.0.16519.zip' -OutPath (Join-Path $dlRoot 'AdskLicensingInstaller-win-17.0.0.16519.zip') -SignerLike 'Autodesk'
    }
    if (-not $adssOk -and -not $AdSsoInstaller) {
        $AdSsoInstaller = Get-OfficialInstaller -Label 'AdSSO' -Url 'https://damassets.autodesk.net/content/dam/autodesk/external-assets/support-articles/autodesk-single-signon-win/adsso_2025_64-bit-update_installer.zip' -OutPath (Join-Path $dlRoot 'adsso_2025_64-bit-update_installer.zip') -SignerLike 'Autodesk'
    }
    if (-not $idmOk -and -not $IdentityInstaller) {
        $idmUrl = 'https://up1.autodesk.com/Windows/1.19.2.0/AdskIdentityManager-UCT-Installer.exe'
        $IdentityInstaller = Get-OfficialInstaller -Label 'Identity Manager' -Url $idmUrl -OutPath (Join-Path $dlRoot 'AdskIdentityManager-UCT-Installer.exe') -SignerLike 'Autodesk'
    }
    if (-not $wv2Ok -and -not $WebView2Installer) {
        $WebView2Installer = Get-OfficialInstaller -Label 'WebView2' -Url 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' -OutPath (Join-Path $dlRoot 'MicrosoftEdgeWebview2Setup.exe') -SignerLike 'Microsoft'
    }
}

# Where an official component comes from. This script installs only what it is
# given (or hereby fetched with -AllowDownload), so be explicit about the
# sources.
function Show-ComponentSources {
    param([string]$What)
    Write-Host ("  {0} is missing and no installer was supplied. Official sources:" -f $What) -ForegroundColor Yellow
    Write-Host '    1) the product image (best: it matches the product version)' -ForegroundColor DarkGray
    Write-Host '         <image>\x64\AdskLicensing\*.exe   (deployment)  or  <image>\x86\Licensing\AdskLicensing-installer.exe   (product image)' -ForegroundColor DarkGray
    Write-Host '         <image>\x64\AdSSO\*                (identity / sign-in, 2020-2023)' -ForegroundColor DarkGray
    Write-Host '         <image>\x64\Components\*\Identity*  (Identity Manager, 2024+)' -ForegroundColor DarkGray
    Write-Host '         <image>\x64\Components\*\Genuine*   (Genuine Service)' -ForegroundColor DarkGray
    Write-Host '    2) your Autodesk account: https://manage.autodesk.com/products/all' -ForegroundColor DarkGray
    Write-Host '    3) a Custom Install / Deployment folder -> point -InstallerDir at it' -ForegroundColor DarkGray
    Write-Host '    4) WebView2 is a Microsoft component:' -ForegroundColor DarkGray
    Write-Host '         https://developer.microsoft.com/microsoft-edge/webview2' -ForegroundColor DarkGray
    Write-Host '    5) AdSSO (2020-2023): https://www.autodesk.com/support/technical/article/caas/tsarticles/ts/A785RG35hP8oUR96WrYkn.html' -ForegroundColor DarkGray
    Write-Host '    6) Identity Manager (2024+): https://up1.autodesk.com/Windows/1.19.2.0/AdskIdentityManager-UCT-Installer.exe' -ForegroundColor DarkGray
    Write-Host '    7) or re-run with -AllowDownload: ADLS, AdSSO, Identity Manager and WebView2 are then fetched from the official servers' -ForegroundColor DarkGray
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
    # A downloaded archive (AdSSO) is still a zip when it comes from -InstallerDir.
    if ($Path -match '\.zip$') {
        $ex = $Path + '.expanded'
        if (-not (Test-Path -LiteralPath $ex)) { Expand-ArchiveSafe -ZipPath $Path -Destination $ex }
        $Path = Select-InstallerFromArchive -Path $ex -Label $Label
        if (-not $Path) { throw 'the archive does not contain an installer' }
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
# --unattendedmodeui none"` in pkg.licensing.xml), not from '/S'. The Identity
# Manager standalone installer is InstallBuilder too ('-q' is the UCT wrapper's
# switch). An explicit -SilentArgs still wins.
$adlsArgs = if ($PSBoundParameters.ContainsKey('SilentArgs')) { $SilentArgs } else { '--mode unattended --unattendedmodeui none' }
$idmArgs  = if ($IdentityInstaller -match 'UCT') { '-q' } else { '--mode unattended --unattendedmodeui none' }
Invoke-Pkg -Label 'ADLS'             -Path $AdlsInstaller     -Args $adlsArgs  -Present $adlsOk
Invoke-Pkg -Label 'AdSSO'            -Path $AdSsoInstaller    -Args $SilentArgs -Present $adssOk
Invoke-Pkg -Label 'Identity Manager' -Path $IdentityInstaller -Args $idmArgs   -Present $idmOk
Invoke-Pkg -Label 'Genuine'          -Path $GenuineInstaller  -Args $SilentArgs -Present $genuineOk
# the WebView2 installers (Evergreen bootstrapper and the standalone package)
# both accept /silent /install
Invoke-Pkg -Label 'WebView2'         -Path $WebView2Installer -Args '/silent /install' -Present $wv2Ok

# A component that is absent and has no installer never gets invented here: say
# where the official one comes from instead.
if (-not $adlsOk -and -not $AdlsInstaller) { Show-ComponentSources 'AdskLicensing (ADLS)' }
if (-not $adssOk -and -not $AdSsoInstaller) { Show-ComponentSources 'Autodesk Single Sign-On (AdSSO - 2020-2023 products)' }
if (-not $idmOk -and -not $IdentityInstaller) { Show-ComponentSources 'Autodesk Identity Manager (2024+ products)' }
if (-not $wv2Ok -and -not $WebView2Installer) { Show-ComponentSources 'Microsoft Edge WebView2 (the sign-in window)' }
if (-not $genuineOk -and -not $GenuineInstaller) { Show-ComponentSources 'Autodesk Genuine Service' }

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
# 6. Repair the licensing build folder - AFTER the installer has run
# ---------------------------------------------------------------------------
# Non-genuine activators replace the licensing stack with a doctored old build
# and re-point 'Current' at it. The genuine builds are still on the disk, so
# the repair is to point 'Current' back at the newest genuine one - no download.
Section 'Licensing build folder'

# The installer may have started the service again; a live service keeps the
# junction's files open.
$svcNow = Get-Service 'AdskLicensingService' -ErrorAction SilentlyContinue
if ($svcNow -and $svcNow.Status -ne 'Stopped') {
    Step 'Stop AdskLicensingService before re-pointing Current' { Stop-Service -Name AdskLicensingService -Force -ErrorAction SilentlyContinue }
}

$stack    = Get-AdlsStack -Root $adskLicensingRoot
$curPath  = $stack.Current.Path
$newest   = $stack.Newest
$curInfo  = $stack.Current
$curBuild = $stack.CurrentBuild

if (-not (Test-Path -LiteralPath $adskLicensingRoot)) {
    Info 'AdskLicensing\Current not found'
} elseif (-not $newest) {
    Write-Host '  [WARN] no complete genuine AdskLicensing build found - a reinstall is needed (see sources above)' -ForegroundColor Yellow
    if ($curInfo.Exists) { Write-Host ("  [WARN] Current is {0} - left alone until a genuine build exists" -f $curInfo.Path) -ForegroundColor Yellow }
} else {
    if (-not $curInfo.Exists) {
        $np = $newest.Path
        Step ("Create AdskLicensing\Current -> {0}" -f $newest.Name) {
            $out = cmd /c mklink /J "$curPath" "$np" 2>&1
            if ($LASTEXITCODE -ne 0) { throw ('mklink failed: ' + ($out -join ' ')) }
        }
    } elseif (-not $curInfo.IsLink) {
        # Official ADLS always uses a junction. A real folder here is either a
        # copied build or a patched stack; keep it for reference, then link.
        $aside = $curPath + '.non-genuine-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        $np = $newest.Path
        Step ("Move the non-junction Current folder aside ({0}) and link {1}" -f $aside, $newest.Name) {
            Move-Item -LiteralPath $curPath -Destination $aside -Force
            $out = cmd /c mklink /J "$curPath" "$np" 2>&1
            if ($LASTEXITCODE -ne 0) { throw ('mklink failed: ' + ($out -join ' ')) }
        }
    } elseif ($curInfo.Target -ne $newest.Path) {
        $from = if ($curInfo.Target) { Split-Path -Leaf $curInfo.Target } else { '?' }
        $to   = $newest.Name
        $np   = $newest.Path
        Step ("Point AdskLicensing\Current back at the genuine build {0} (now: {1})" -f $to, $from) {
            cmd /c rmdir "$curPath" | Out-Null
            $out = cmd /c mklink /J "$curPath" "$np" 2>&1
            if ($LASTEXITCODE -ne 0) { throw ('mklink failed: ' + ($out -join ' ')) }
        }
    } else {
        Info ('AdskLicensing\Current -> ' + $newest.Name + ' (genuine build - OK)')
    }

    # A numbered build folder that holds no signed Autodesk binary is a planted
    # stub, not a real build; drop it once 'Current' no longer needs it.
    foreach ($b in $stack.Builds) {
        if ($b.Path -eq $newest.Path) { continue }
        if ($b.Genuine -and $b.Complete) { continue }
        if ($b.Genuine -and -not $b.Complete) {
            # An interrupted official update, not a crack stub: keep it for
            # diagnosis but move it out of the numbered namespace so the next
            # installer can lay down a clean build.
            $bp = $b.Path
            $aside = $bp + '.incomplete-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Step ("Move the incomplete licensing build {0} aside ({1})" -f $b.Name, $aside) { Move-Item -LiteralPath $bp -Destination $aside -Force }
            continue
        }
        $bp = $b.Path
        Step ("Remove non-genuine licensing build folder {0} (unsigned stub)" -f $b.Name) { Remove-Item -LiteralPath $bp -Recurse -Force }
    }

    # DLL-search-order hijack names and the all-caps ADSKLicenseAgent.exe are
    # not Autodesk binaries. They are what made the agent die with 0xc0000006,
    # so a repair removes them instead of leaving them for the next product
    # start. Walk the whole licensing tree (not only the numbered builds): a
    # build moved aside above still lives under this root, and the next scan
    # would flag its proxy DLL again. Junctions are skipped.
    function Get-FilesSkippingJunctions {
        param([string]$Path)
        foreach ($d in @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            Get-FilesSkippingJunctions -Path $d.FullName
        }
        Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue
    }
    $proxyNames = @('version.dll','netapi32.dll','winmm.dll','userenv.dll','dbghelp.dll',
                    'mpr.dll','mswsock.dll','ws2_32.dll','secur32.dll','cryptbase.dll',
                    'wtsapi32.dll','profapi.dll','iphlpapi.dll','dwmapi.dll','uxtheme.dll')
    $quarantine = Join-Path $env:ProgramData ('UNLOCK DIGITAL\quarantine\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $hits = @(Get-FilesSkippingJunctions -Path $adskLicensingRoot | Where-Object {
        $n = $_.Name.ToLowerInvariant()
        ($proxyNames -contains $n) -or
        ($_.Extension -eq '.exe' -and $n -match '^adsk.*licenseagent\.exe$' -and $n -ne 'adsklicensingagent.exe')
    })
    foreach ($h in $hits) {
        if (Test-AutodeskSignature $h.FullName) { continue }
        $hp = $h.FullName
        Step ("Quarantine the non-Autodesk licensing file {0}" -f $hp) {
            New-Item -ItemType Directory -Force -Path $quarantine | Out-Null
            Move-Item -LiteralPath $hp -Destination (Join-Path $quarantine $h.Name) -Force
        }
    }
}

# ---------------------------------------------------------------------------
# 7. Restart + fix services
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
# 8. Clear sign-in token cache (forces clean re-authentication)
# ---------------------------------------------------------------------------
Section 'Sign-in token cache'
$lockedCache = @()
foreach ($p in @(
    (Join-Path $env:LOCALAPPDATA 'Autodesk\Web Services'),
    (Join-Path $env:APPDATA 'Autodesk\Web Services'))) {
    if (Test-Path -LiteralPath $p) {
        $pp = $p
        # A running product (acad, revit...) keeps WebServices.log open. The
        # locked files must not print raw Remove-Item error blocks - a customer
        # support bundle (2026-10-17) showed eight of them, which reads as a
        # broken repair. SilentlyContinue + one calm note instead.
        Step ("Clear token cache {0}" -f $p) { Remove-Item -LiteralPath $pp -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $pp) { $lockedCache += $pp }
    }
}
if ($lockedCache.Count -gt 0) {
    Info 'Some cache files are in use by a running Autodesk product - they clear after it is closed (or after a reboot).'
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
    $ebLeft = @()
    foreach ($d in $eb) {
        $dp = $d.FullName
        Step ("Clear sign-in window profile {0}" -f $dp) { Remove-Item -LiteralPath $dp -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $dp) { $ebLeft += $dp }
    }
    if ($eb.Count -eq 0) { Info 'No sign-in window profile found (nothing to clear)' }
    elseif ($ebLeft.Count -gt 0) { Info 'Some sign-in profile files are in use by the licensing agent - they clear after the product is closed (or after a reboot).' }
}

# ---------------------------------------------------------------------------
# 9. Verify
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

$stackEnd = Get-AdlsStack -Root $adskLicensingRoot
if ($stackEnd.Newest -and $stackEnd.CurrentOk) {
    Write-Host ("  [ OK ] AdskLicensing Current -> {0} (complete Autodesk build)" -f $stackEnd.CurrentBuild.Name) -ForegroundColor Green
} elseif ($stackEnd.Newest -and $stackEnd.CurrentUsable) {
    Write-Host ("  [WARN] AdskLicensing Current -> {0}, but {1} is the newest build" -f $stackEnd.CurrentBuild.Name, $stackEnd.Newest.Name) -ForegroundColor Yellow
} elseif ($stackEnd.Newest) {
    Write-Host ("  [WARN] AdskLicensing Current does not point at a usable build (newest: {0})" -f $stackEnd.Newest.Name) -ForegroundColor Yellow
} else {
    Write-Host '  [FAIL] No complete genuine AdskLicensing build found' -ForegroundColor Red
}

if (Test-WebView2) {
    Write-Host '  [ OK ] Microsoft Edge WebView2 present (the sign-in window can render)' -ForegroundColor Green
} else {
    Write-Host '  [WARN] Microsoft Edge WebView2 MISSING - the sign-in window cannot open' -ForegroundColor Yellow
}
# the official installer puts the exe either straight inside the folder or
# one level down in a version folder (e.g. ...\AdskIdentityManager\1.19.2.0\)
$idm = Get-IdentityManagerExe
if ($idm) { Write-Host ('  [ OK ] Identity component present: ' + $idm) -ForegroundColor Green }
else { Write-Host '  [WARN] Identity component (AdskIdentityManager) not found - sign-in may not complete' -ForegroundColor Yellow }

if (Test-AdssO -Root $adskLicensingRoot -CommonFiles $commonFiles) {
    Write-Host '  [ OK ] AdSSO component present (or not required on this machine)' -ForegroundColor Green
} else {
    Write-Host '  [WARN] AdSSO component missing - 2020-2023 products cannot show the sign-in window' -ForegroundColor Yellow
}

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
if ($script:LogPath) {
    Write-Host ("   Log saved: {0}" -f $script:LogPath) -ForegroundColor DarkGray
    try { Stop-Transcript | Out-Null } catch { }
}
