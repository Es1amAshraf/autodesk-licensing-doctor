<#
    AdskDoctor.ps1  -  Phase 1: DIAGNOSTIC (read-only, enhanced)
    ------------------------------------------------------------
    Deep, read-only scan for Autodesk licensing problems caused by
    cracked ("non-genuine") installs. CHANGES NOTHING.

    Coverage:
      - System / environment readiness (admin, restore point, pending reboot,
        pending file renames)
      - Hosts file hijacks
      - Firewall rules blocking Autodesk
      - Autodesk / FlexNet services (existence, state, suspicious image path,
        signature of the service binary, missing required services)
      - Deep signature scan of licensing components (AdskLicensing, AdSSO)
      - Signature scan of installed product binaries
      - Crack leftovers & suspicious file names
      - Suspicious / hijacked registry values
      - Environment variables
      - Scheduled tasks (by name AND by action target)
      - Startup entries (Run keys + Startup folders)
      - Running Autodesk / license-server processes
      - Local fake license server (listening FLEXlm ports)
      - Connectivity to Autodesk endpoints (443) + DNS sanity
      - WinHTTP proxy
      - Sign-in prerequisites: Edge WebView2, identity component,
        .NET Framework 4.8, TLS 1.2 / strong crypto
      - Licensing logs (the agent log names the exact failure)

    Usage:
      .\AdskDoctor.ps1
      .\AdskDoctor.ps1 -Export C:\temp\report.txt
      .\AdskDoctor.ps1 -Json -Export C:\temp\report.json
      .\AdskDoctor.ps1 -Html -Export C:\temp\report.html
      .\AdskDoctor.ps1 -Html -Export C:\temp\report.html -Bundle
#>

[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$Html,
    [string]$Export,
    # collect the licensing logs next to the report and zip them, so a support
    # request can be sent as one file
    [switch]$Bundle
)

# -Bundle needs a report file to put inside the zip
if ($Bundle -and -not $Export) {
    $Html   = $true
    $Export = Join-Path (Get-Location).Path 'report.html'
}

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ===========================================================================
# Report plumbing
# ===========================================================================
$script:Findings = New-Object System.Collections.Generic.List[object]

function Add-Finding {
    param(
        [ValidateSet('OK','WARN','BAD','INFO')][string]$Status,
        [string]$Category,
        [string]$Message,
        [string]$Detail
    )
    $script:Findings.Add([pscustomobject]@{
        Status   = $Status
        Category = $Category
        Message  = $Message
        Detail   = $Detail
    })
    $color = @{ OK='Green'; WARN='Yellow'; BAD='Red'; INFO='DarkGray' }[$Status]
    $tag   = @{ OK='[ OK ]'; WARN='[WARN]'; BAD='[FAIL]'; INFO='[info]' }[$Status]
    Write-Host ("{0} {1}" -f $tag, $Message) -ForegroundColor $color
    if ($Detail) { Write-Host ("        -> {0}" -f $Detail) -ForegroundColor DarkGray }
}

function Write-Section { param([string]$Title) Write-Host ''; Write-Host ("== {0} ==" -f $Title) -ForegroundColor Cyan }

# ===========================================================================
# Helpers
# ===========================================================================
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-TcpPort {
    param([string]$ComputerName, [int]$Port = 443, [int]$TimeoutMs = 4000)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { $client.Close(); return $false }
        $client.EndConnect($iar); $client.Close(); return $true
    } catch { return $false }
}

function Get-ExeFromCommandLine {
    param([string]$CommandLine)
    if (-not $CommandLine) { return $null }
    if ($CommandLine -match '^\s*"([^"]+\.exe)"') { return $matches[1] }
    if ($CommandLine -match '^\s*([^\s]+\.exe)')   { return $matches[1] }
    return $null
}

# Returns 'BAD', 'WARN' or $null depending on how suspicious an exe path is.
function Get-PathSuspicion {
    param([string]$Path)
    if (-not $Path) { return $null }
    $p = $Path.ToLowerInvariant()
    if ($p -match '\\appdata\\|\\temp\\|\\users\\|\\downloads\\') { return 'BAD' }
    if ($p -match '\\programdata\\') { return 'WARN' }
    return $null
}

# Query a trustworthy internet clock via the HTTP "Date" header.
function Get-InternetTime {
    foreach ($url in @('https://www.autodesk.com','https://www.microsoft.com')) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Method = 'HEAD'
            $req.Timeout = 8000
            $req.UserAgent = 'AdskDoctor'
            $resp = $req.GetResponse()
            $hdr = $resp.Headers['Date']
            $resp.Close()
            if ($hdr) { return [datetime]::Parse($hdr, [System.Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() }
        } catch {}
    }
    return $null
}

function Test-AutodeskSigned {
    param([string]$FilePath, [string]$Label, [switch]$Strict)
    if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
    $sig = Get-AuthenticodeSignature -LiteralPath $FilePath
    $subject = $sig.SignerCertificate.Subject
    switch ($sig.Status) {
        'Valid' {
            if ($subject -match 'Autodesk') {
                Add-Finding OK 'Signatures' ("Genuine (Autodesk-signed): {0}" -f $Label) $FilePath
            } else {
                Add-Finding WARN 'Signatures' ("Signed but not by Autodesk: {0}" -f $Label) ($FilePath + ' | ' + $subject)
            }
        }
        # A file with no signature at all reports NotSigned for a binary and
        # UnknownError for a plain data file - neither one means "tampered".
        { $_ -in 'NotSigned','UnknownError' } {
            $sev = if ($Strict) { 'BAD' } else { 'WARN' }
            Add-Finding $sev 'Signatures' ("UNSIGNED ({0}): {1}" -f $(if($Strict){'expected Autodesk signature'}else{'review'}), $Label) $FilePath
        }
        # This one is real: the file carries a signature that no longer matches
        # its bytes, which is what a hex-edited (cracked) binary looks like.
        'HashMismatch' {
            Add-Finding BAD 'Signatures' ("SIGNATURE INVALID [patched/cracked]: {0}" -f $Label) $FilePath
        }
        # The signature exists but the chain cannot be validated - usually a
        # missing/removed root CA or an offline machine, not a crack.
        'NotTrusted' {
            Add-Finding WARN 'Signatures' ("Signature could not be trusted [{0}]: {1}" -f $sig.Status, $Label) ($FilePath + ' - check the certificate chain / internet access')
        }
        default {
            Add-Finding WARN 'Signatures' ("Signature could not be checked [{0}]: {1}" -f $sig.Status, $Label) $FilePath
        }
    }
}

# Authenticode only ever covers real binaries, so a folder scan has to look at
# binaries and nothing else. Get-ChildItem SILENTLY IGNORES -Include when it is
# combined with -LiteralPath, which made an earlier release scan every JSON,
# font and PNG in the licensing folder and report each one as "INVALID
# signature" (a customer saw 322 of those on a healthy machine), so the file
# list is filtered explicitly here.
$script:SignatureExtensions = @(
    '.exe','.dll','.sys','.ocx','.cpl','.msi','.msp','.drv','.ax','.scr','.com'
)

function Scan-FolderSignatures {
    param([string]$Root, [string]$Tag, [switch]$Strict)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $script:SignatureExtensions -contains $_.Extension.ToLowerInvariant() })
    $checked  = 0
    $bad      = 0
    $unsigned = 0
    foreach ($f in $files) {
        $checked++
        $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
        if ($sig.Status -in 'NotSigned','UnknownError') {
            $unsigned++
            if ($Strict) { Add-Finding BAD 'Signatures' ("UNSIGNED in {0}: {1}" -f $Tag, $f.Name) $f.FullName; $bad++ }
        } elseif ($sig.Status -eq 'HashMismatch') {
            Add-Finding BAD 'Signatures' ("PATCHED binary in {0}: {1} (its signature no longer matches)" -f $Tag, $f.Name) $f.FullName
            $bad++
        } elseif ($sig.Status -ne 'Valid') {
            Add-Finding WARN 'Signatures' ("Signature not trusted in {0}: {1} [{2}]" -f $Tag, $f.Name, $sig.Status) $f.FullName
        }
    }
    if ($bad -eq 0) {
        if ($unsigned -gt 0) {
            Add-Finding INFO 'Signatures' ("{0} unsigned binary/binaries in {1} (no signature - nothing patched)" -f $unsigned, $Tag) ''
        } else {
            Add-Finding OK 'Signatures' ("All {0} binaries in {1} carry a valid signature" -f $checked, $Tag)
        }
    }
}

$AutodeskHosts = @(
    'activation.autodesk.com','registeronce.autodesk.com','genuine-software.autodesk.com',
    'ipm.autodesk.com','accounts.autodesk.com','autodesk.com'
)

# ===========================================================================
# Banner
# ===========================================================================
$isAdmin = Test-IsAdmin
Clear-Host
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   Autodesk Licensing Doctor  -  Diagnostic v2 (read-only)' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ("   Computer : {0}" -f $env:COMPUTERNAME)
Write-Host ("   Date     : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Write-Host ("   Admin    : {0}" -f $(if ($isAdmin) { 'yes' } else { 'NO - some checks limited' }))
Write-Host ("   OS       : {0} (build {1})" -f $os.Caption, $os.BuildNumber)

# ===========================================================================
# 0. System readiness
# ===========================================================================
Write-Section 'System readiness'
if (-not $isAdmin) {
    Add-Finding WARN 'System' 'Not running as administrator - registry/service/firewall scans may be incomplete' 'Right-click Run-Diagnostic.cmd -> Run as administrator'
} else {
    Add-Finding OK 'System' 'Running as administrator'
}

# System Restore (needed by Phase 2 backup)
try {
    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $rp = Get-CimInstance -Namespace 'root\default' -ClassName SystemRestore -ErrorAction SilentlyContinue
    if ($rp) { Add-Finding OK 'System' ("System Restore available ({0} restore point(s))" -f @($rp).Count) }
    else { Add-Finding WARN 'System' 'No System Restore points found - enable System Protection before cleaning' '' }
} catch {
    Add-Finding INFO 'System' 'Could not query System Restore status' ''
}

# Pending reboot
$pending = $false
foreach ($k in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')) {
    if (Test-Path -LiteralPath $k) { $pending = $true }
}
if ($pending) { Add-Finding WARN 'System' 'A reboot is pending - reboot before reinstalling licensing components' '' }
else { Add-Finding OK 'System' 'No pending reboot' }

# pending file renames (the third reboot flag, and the one that makes installers
# fail with error 1603)
try {
    $pfr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop).PendingFileRenameOperations
    if (@($pfr).Count -gt 0) {
        Add-Finding WARN 'System' ('Pending file renames are queued ({0} entries) - reboot before installing' -f @($pfr).Count) 'Installers fail with error 1603 while renames are pending'
    }
} catch {}

# Windows Installer service (needed to install/repair components)
$msi = Get-Service msiserver
if ($msi -and $msi.StartType -ne 'Disabled') { Add-Finding OK 'System' 'Windows Installer service is available' }
else { Add-Finding WARN 'System' 'Windows Installer service is disabled/unavailable' '' }

# ===========================================================================
# 0b. System clock & time sync   (-> "Clock Error" in products)
# ===========================================================================
Write-Section 'System clock & time sync'
Write-Host ("   Local time : {0}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
$tz = Get-TimeZone
Write-Host ("   Time zone  : {0} (UTC{1})" -f $tz.Id, $tz.BaseUtcOffset)

$w32 = Get-Service w32time
if ($w32) {
    if ($w32.StartType -eq 'Disabled') { Add-Finding WARN 'Clock' 'Windows Time service (w32time) is Disabled - clock can drift' '' }
    else { Add-Finding OK 'Clock' ("Windows Time service present (State={0}, Start={1})" -f $w32.Status, $w32.StartType) }
} else { Add-Finding WARN 'Clock' 'Windows Time service (w32time) not found' '' }

$netTime = Get-InternetTime
if ($netTime) {
    $drift = [math]::Abs(([datetime]::UtcNow - $netTime).TotalSeconds)
    if ($drift -gt 3600) {
        Add-Finding BAD 'Clock' ("System clock is off by ~{0:N0} min vs internet time" -f ($drift/60)) 'This causes the Autodesk "Clock Error"'
    } elseif ($drift -gt 300) {
        Add-Finding WARN 'Clock' ("System clock is off by ~{0:N0} min vs internet time" -f ($drift/60)) 'Should be within a few minutes'
    } else {
        Add-Finding OK 'Clock' ("System clock matches internet time (drift {0:N0}s)" -f $drift) ''
    }
} else {
    Add-Finding WARN 'Clock' 'Could not verify the system clock against internet time' 'Check network / time source'
}

# time servers blocked in hosts (a common crack side-effect)
try {
    $hostsRaw = Get-Content -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') -ErrorAction SilentlyContinue
    $timeBlock = @($hostsRaw | Where-Object { $_ -match 'time\.windows|ntp|time\.autodesk' -and $_ -notmatch '^\s*#' })
    if ($timeBlock.Count -gt 0) { Add-Finding WARN 'Clock' 'Time servers are blocked in the hosts file' ($timeBlock -join ' ; ') }
} catch {}

# ===========================================================================
# 0c. Installer health   (-> "Error 1603")
# ===========================================================================
Write-Section 'Installer health'
try {
    $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeGB = [math]::Round($c.FreeSpace/1GB,1)
    if ($freeGB -lt 10) { Add-Finding WARN 'Installer' ("Low free space on C: ({0} GB)" -f $freeGB) 'Autodesk installs need several GB' }
    else { Add-Finding OK 'Installer' ("Free space on C: {0} GB" -f $freeGB) }
} catch {}

try {
    $probe = Join-Path $env:TEMP ('adskdoctor_' + [guid]::NewGuid().ToString('N') + '.tmp')
    'x' | Set-Content -LiteralPath $probe -ErrorAction Stop
    Remove-Item -LiteralPath $probe -Force
    Add-Finding OK 'Installer' 'TEMP folder is writable' $env:TEMP
} catch { Add-Finding WARN 'Installer' 'TEMP folder is not writable' $env:TEMP }

try {
    $unGlob = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $vcDlls = @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll') |
        ForEach-Object { Join-Path $env:SystemRoot ("System32\" + $_) }
    $vcOk = @($vcDlls | Where-Object { Test-Path -LiteralPath $_ }).Count
    if ($vcOk -ge 2) {
        Add-Finding OK 'Installer' ('Visual C++ 2015-2022 runtime present ({0}/3 core DLLs)' -f $vcOk)
    } else {
        Add-Finding WARN 'Installer' ('Visual C++ 2015-2022 runtime incomplete ({0}/3 core DLLs)' -f $vcOk) 'Install the VC++ 2015-2022 x64 Redistributable'
    }

    $ak = @(Get-ItemProperty $unGlob -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Autodesk' })
    $orphans = 0
    foreach ($e in $ak) {
        if ($e.InstallLocation -and -not (Test-Path -LiteralPath $e.InstallLocation)) { $orphans++ }
    }
    Add-Finding INFO 'Installer' ('Autodesk uninstall entries: {0} (orphaned: {1})' -f $ak.Count, $orphans) ''
    if ($orphans -gt 0) { Add-Finding WARN 'Installer' ('{0} orphaned Autodesk uninstall entries (failed-install leftovers)' -f $orphans) 'A common cause of error 1603' }
} catch {}

# The licensing checks below only mean something when Autodesk is actually
# installed: on a clean machine a missing licensing service is not a defect, so
# those findings stay informational instead of raising a failure.
$adskInstalled = (@($ak).Count -gt 0) -or (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Autodesk'))

# ===========================================================================
# 1. Hosts file
# ===========================================================================
Write-Section 'Hosts file'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
try {
    $hostsLines = Get-Content -LiteralPath $hostsPath -ErrorAction Stop
    $hijacks = @()
    foreach ($line in $hostsLines) {
        $clean = ($line -split '#')[0].Trim()
        if ($clean -and $clean -match 'autodesk|adsk|flexnet') { $hijacks += $clean }
    }
    if ($hijacks.Count -gt 0) {
        Add-Finding BAD 'Hosts' ("Hosts file hijacks Autodesk domains ({0})" -f $hijacks.Count) ($hijacks -join ' ; ')
    } else { Add-Finding OK 'Hosts' 'No Autodesk entries in hosts file' }

    $attr = (Get-Item -LiteralPath $hostsPath).Attributes
    if ($attr -band [System.IO.FileAttributes]::ReadOnly) {
        Add-Finding WARN 'Hosts' 'Hosts file is marked read-only (a crack may have locked it)' ''
    }
} catch {
    Add-Finding WARN 'Hosts' 'Could not read hosts file' $_.Exception.Message
}

# ===========================================================================
# 2. Firewall rules
# ===========================================================================
Write-Section 'Firewall rules'
try {
    $fw = @(Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'autodesk|adsk|flexnet|acad|revit' })
    if ($fw.Count -gt 0) {
        foreach ($rule in $fw) {
            $block = ($rule.Action -eq 'Block')
            $prog = ($rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue).Program
            $detail = "Action=$($rule.Action); Direction=$($rule.Direction); Program=$prog"
            Add-Finding ($(if ($block){'BAD'}else{'INFO'})) 'Firewall' ("Firewall rule: {0}" -f $rule.DisplayName) $detail
        }
    } else { Add-Finding OK 'Firewall' 'No Autodesk-related firewall rules found' }
} catch {
    Add-Finding WARN 'Firewall' 'Could not enumerate firewall rules' $_.Exception.Message
}

# ===========================================================================
# 3. Services
# ===========================================================================
Write-Section 'Services'
try {
    $svc = @(Get-CimInstance Win32_Service | Where-Object {
        $_.Name -match 'adsk|autodesk|flexnet|flexlm' -or $_.DisplayName -match 'adsk|autodesk|flexnet|flexlm'
    })
    if ($svc.Count -gt 0) {
        foreach ($s in $svc) {
            Add-Finding INFO 'Services' ("Service '{0}' ({1}) State={2} Start={3}" -f $s.Name, $s.DisplayName, $s.State, $s.StartMode) $s.PathName
            $exe = Get-ExeFromCommandLine $s.PathName
            $susp = Get-PathSuspicion $exe
            if ($susp) {
                Add-Finding $susp 'Services' ("Service '{0}' runs from a suspicious path" -f $s.Name) $exe
            }
            # A service that survived the removal of its binaries (a leftover
            # Network License Manager, for example) is a real leftover: it still
            # starts at boot and can block a clean reinstall.
            if ($exe -and -not (Test-Path -LiteralPath $exe)) {
                Add-Finding WARN 'Services' ("Service '{0}' points to a missing file (stale leftover)" -f $s.Name) $exe
            }
            if ($exe -and (Test-Path -LiteralPath $exe)) {
                Test-AutodeskSigned -FilePath $exe -Label ("service {0}" -f $s.Name) -Strict
            }
        }
    } elseif ($adskInstalled) {
        Add-Finding WARN 'Services' 'No Autodesk/FlexNet services found at all' 'Official products register ADLS/Access services'
    } else {
        Add-Finding INFO 'Services' 'No Autodesk/FlexNet services found' 'No Autodesk product is installed on this machine'
    }

    $adls = $svc | Where-Object { $_.Name -eq 'AdskLicensingService' }
    if ($adls) {
        if ($adls.State -eq 'Running') { Add-Finding OK 'Services' 'AdskLicensingService present and running' }
        else { Add-Finding WARN 'Services' ("AdskLicensingService present but State={0}" -f $adls.State) 'The product will show "Connection Lost to Autodesk Desktop Licensing Service"' }
        if ($adls.StartMode -eq 'Disabled') { Add-Finding WARN 'Services' 'AdskLicensingService start mode is Disabled' 'Set it to Automatic' }
    } elseif ($adskInstalled) {
        Add-Finding BAD 'Services' 'AdskLicensingService (ADLS) is MISSING - single-user licensing cannot work' 'Causes "Desktop Licensing Service - Connection Lost" and licensing errors'
    } else {
        Add-Finding INFO 'Services' 'AdskLicensingService (ADLS) not installed' 'Nothing to license on this machine'
    }
} catch {
    Add-Finding WARN 'Services' 'Could not enumerate services' $_.Exception.Message
}

# ===========================================================================
# 4. Licensing components - deep signature scan
# ===========================================================================
Write-Section 'Licensing components (deep signature scan)'
$commonFiles = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared'
$adskLicensingRoot = Join-Path $commonFiles 'AdskLicensing'
$adSSO = Join-Path $commonFiles 'AdSSO'

if (Test-Path -LiteralPath $adskLicensingRoot) {
    $versions = @(Get-ChildItem -LiteralPath $adskLicensingRoot -Directory)
    if ($versions.Count -gt 0) {
        Add-Finding INFO 'Licensing' ('AdskLicensing versions: ' + (($versions.Name) -join ', ')) $adskLicensingRoot
        Scan-FolderSignatures -Root $adskLicensingRoot -Tag 'AdskLicensing'
    } else { Add-Finding WARN 'Licensing' 'AdskLicensing folder exists but is empty' $adskLicensingRoot }
} elseif ($adskInstalled) {
    Add-Finding BAD 'Licensing' 'AdskLicensing folder NOT found' ("Expected: " + $adskLicensingRoot)
} else {
    Add-Finding INFO 'Licensing' 'AdskLicensing is not installed' 'No Autodesk product is installed on this machine'
}

# --- ADLS version ----------------------------------------------------------
# A cracked install often leaves an OLD AdskLicensing behind, and an old
# licensing service is a common cause of single-user (sign-in) failures. The
# baseline below is the first ADLS line that serves named-user licensing: an
# older build cannot activate a subscription product and has to be updated with
# the official installer (Repair step). It is a floor, not a target.
$AdlsBaseline = [version]'10.0.0.0'
$adlsVersion  = $null
$versionIni   = Join-Path $adskLicensingRoot 'version.ini'
if (Test-Path -LiteralPath $versionIni) {
    $raw = Get-Content -LiteralPath $versionIni -Raw -ErrorAction SilentlyContinue
    if ($raw -match '(\d+\.\d+\.\d+(?:\.\d+)?)') { $adlsVersion = $matches[1] }
}
if (-not $adlsVersion -and (Test-Path -LiteralPath $adskLicensingRoot)) {
    # the version sub-folders are named after the version; otherwise ask the service exe
    $dirs = @(Get-ChildItem -LiteralPath $adskLicensingRoot -Directory -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -match '^\d+(\.\d+)+$' } | Sort-Object { [version]$_.Name } -Descending)
    if ($dirs.Count) {
        $adlsVersion = $dirs[0].Name
    } else {
        $svcExe = @(Get-ChildItem -LiteralPath $adskLicensingRoot -Recurse -File -Filter 'AdskLicensingService.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($svcExe.Count) { $adlsVersion = $svcExe[0].VersionInfo.FileVersion }
    }
}
if ($adlsVersion) {
    $adlsObj = $null
    try { $adlsObj = [version]$adlsVersion } catch {}
    if ($adlsObj -and $adlsObj -lt $AdlsBaseline) {
        Add-Finding WARN 'Licensing' ("AdskLicensing (ADLS) is {0} - older than the {1} baseline" -f $adlsVersion, $AdlsBaseline) 'An old licensing service cannot serve single-user sign-in - run the Repair step to install the official ADLS'
    } else {
        Add-Finding INFO 'Licensing' ("AdskLicensing (ADLS) version: {0}" -f $adlsVersion) ''
    }
} elseif (Test-Path -LiteralPath $adskLicensingRoot) {
    Add-Finding WARN 'Licensing' 'AdskLicensing (ADLS) version could not be determined' $adskLicensingRoot
}

# --- ADLS 'Current' junction ------------------------------------------------
# ADLS keeps every installed build side by side and points 'Current' at the
# active one. An interrupted licensing-service update can leave that junction on
# an older build than the newest installed one - a known cause of the generic
# "Licensing error - An error occurred".
$curPath = Join-Path $adskLicensingRoot 'Current'
if (Test-Path -LiteralPath $curPath) {
    $numbered = @(Get-ChildItem -LiteralPath $adskLicensingRoot -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^\d+(\.\d+)+$' } | Sort-Object { [version]$_.Name })
    try {
        $curItem = Get-Item -LiteralPath $curPath -Force -ErrorAction Stop
        $curName = Split-Path -Leaf (@($curItem.Target)[0] -replace '[\\/]+$', '')
        if ($curName -and $numbered.Count -and ($numbered.Name -contains $curName) -and $curName -ne $numbered[-1].Name) {
            Add-Finding WARN 'Licensing' ("AdskLicensing 'Current' points at {0} while {1} is installed" -f $curName, $numbered[-1].Name) ($curPath + ' - check this if licensing fails, then reinstall the official licensing service (Repair step)')
        } elseif ($curName) {
            Add-Finding INFO 'Licensing' ("AdskLicensing 'Current' -> {0}" -f $curName) $curPath
        }
    } catch {}
}

# --- licensing agent -------------------------------------------------------
# The agent is NOT a Windows service in current ADLS releases: it is
# AdskLicensingAgent.exe inside the AdskLicensing folder, started on demand.
# Checking for a service of that name produced a false warning, so look for the
# file (or the service, for very old releases).
$agentFile = @(Get-ChildItem -LiteralPath $adskLicensingRoot -Recurse -File -Filter 'AdskLicensingAgent.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)
$agentSvc  = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'AdskLicensingAgent' })
if ($agentFile.Count) {
    Add-Finding OK 'Licensing' 'Licensing agent present (AdskLicensingAgent.exe)' $agentFile[0].FullName
} elseif ($agentSvc.Count) {
    Add-Finding OK 'Licensing' ("Licensing agent present (service {0})" -f $agentSvc[0].Name) ''
} elseif (Test-Path -LiteralPath $adskLicensingRoot) {
    Add-Finding WARN 'Licensing' 'Licensing agent not found (AdskLicensingAgent)' 'Part of the ADLS stack - reinstall ADLS with the official installer'
}

if (Test-Path -LiteralPath $adSSO) {
    Add-Finding OK 'Licensing' 'AdSSO (Single Sign-On) component present' $adSSO
    # report the newest binary version found in the folder (names differ by release)
    $ssoBest = $null
    foreach ($e in @(Get-ChildItem -LiteralPath $adSSO -Recurse -File -Filter '*.exe' -ErrorAction SilentlyContinue)) {
        $v = $null
        try { $v = [version]$e.VersionInfo.FileVersion } catch {}
        if ($v -and (-not $ssoBest -or $v -gt $ssoBest.Version)) {
            $ssoBest = [pscustomobject]@{ Version = $v; Text = $e.VersionInfo.FileVersion; Path = $e.FullName; Name = $e.Name }
        }
    }
    if ($ssoBest) { Add-Finding INFO 'Licensing' ("AdSSO version: {0} ({1})" -f $ssoBest.Text, $ssoBest.Name) $ssoBest.Path }
    Scan-FolderSignatures -Root $adSSO -Tag 'AdSSO'
} elseif ($adskInstalled) {
    # Newer releases ship the sign-in client inside the licensing service
    # (AdskLicensingAgent holds SSOClient.config + AdSkIdentitySDK.config), so a
    # missing standalone AdSSO folder is not a defect there - it was reported as
    # a warning on machines that sign in perfectly well.
    $ssoInAdls = @(Get-ChildItem -LiteralPath $adskLicensingRoot -Recurse -File -ErrorAction SilentlyContinue |
                   Where-Object { $_.Name -in 'SSOClient.config','AdSkIdentitySDK.config' })
    if ($ssoInAdls.Count) {
        Add-Finding INFO 'Licensing' 'Standalone AdSSO not installed - sign-in is handled by AdskLicensing' $ssoInAdls[0].FullName
    } else {
        Add-Finding WARN 'Licensing' 'AdSSO component not found' ("Expected: " + $adSSO + ' - single-user sign-in needs it')
    }
} else {
    Add-Finding INFO 'Licensing' 'AdSSO is not installed' 'No Autodesk product is installed on this machine'
}

# --- sign-in window (Microsoft Edge WebView2) -------------------------------
# Autodesk renders the "Sign in with your Autodesk ID" window with the Edge
# WebView2 runtime (the licensing agent ships an EBWebView user-data folder).
# When that runtime is missing or broken the product never reaches the sign-in
# page: it fails first with the generic "Licensing error - An error occurred",
# which is exactly what a customer reported.
$wv2Key = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
$wv2 = @()
foreach ($root in @(
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients',
    'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients',
    'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients')) {
    if (Test-Path -LiteralPath $root) {
        $wv2 += @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue |
                  Where-Object { $_.PSChildName -eq $wv2Key })
    }
}
if ($wv2.Count) {
    $pv = (Get-ItemProperty -LiteralPath $wv2[0].PSPath -ErrorAction SilentlyContinue).pv
    Add-Finding OK 'Licensing' ('Microsoft Edge WebView2 runtime present ({0})' -f $pv) ($wv2[0].PSPath -replace 'Microsoft\.PowerShell\.Core\\Registry::', '')
} else {
    $wv2Exe = @(Get-ChildItem -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeWebView\Application') -Recurse -File -Filter 'msedgewebview2.exe' -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($wv2Exe.Count) {
        Add-Finding OK 'Licensing' 'Microsoft Edge WebView2 runtime present' $wv2Exe[0].FullName
    } else {
        Add-Finding WARN 'Licensing' 'Microsoft Edge WebView2 runtime not found - the Autodesk sign-in window needs it' 'A product then fails with "Licensing error - An error occurred" before the sign-in page: install the official WebView2 runtime'
    }
}

# --- identity component -----------------------------------------------------
# 2020+ products sign in through Autodesk Identity Manager, which is a separate
# component from ADLS. Without it the sign-in flow cannot complete.
$idm = @(
    (Join-Path $env:ProgramFiles 'Autodesk\AdskIdentityManager\AdskIdentityManager.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\AdskIdentityManager\AdskIdentityManager.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($idm) {
    Add-Finding OK 'Licensing' ('Identity component present (version {0})' -f (Get-Item -LiteralPath $idm).VersionInfo.FileVersion) $idm
} elseif ($adskInstalled) {
    Add-Finding WARN 'Licensing' 'Identity component (AdskIdentityManager) not found' 'Products from 2020 on sign in through it; reinstall it from the official installer (Repair step)'
} else {
    Add-Finding INFO 'Licensing' 'Identity component not installed' 'No Autodesk product is installed on this machine'
}

# --- .NET Framework ---------------------------------------------------------
# the licensing and sign-in user interface is built on .NET Framework 4.8+
try {
    $ndp = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction Stop
    if ($ndp.Release -ge 528040) { Add-Finding OK 'Licensing' ('Microsoft .NET Framework 4.8+ present (release {0})' -f $ndp.Release) '' }
    elseif ($ndp.Release) { Add-Finding WARN 'Licensing' ('.NET Framework is older than 4.8 (release {0})' -f $ndp.Release) 'The licensing interface needs 4.8 or newer' }
    else { Add-Finding INFO 'Licensing' '.NET Framework build number not reported' '' }
} catch {
    Add-Finding WARN 'Licensing' 'Microsoft .NET Framework 4.x not detected' 'The licensing interface needs .NET Framework 4.8 or newer'
}

# --- TLS 1.2 / strong crypto ------------------------------------------------
# sign-in talks HTTPS to accounts.autodesk.com. Old "harden/disable TLS" tweaks
# and the pre-4.7 .NET defaults break it, and the product then fails before the
# sign-in page. Only explicit values are judged - an absent value is the modern
# default.
$tlsBad = @()
foreach ($root in @('HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319')) {
    foreach ($name in @('SchUseStrongCrypto','SystemDefaultTlsVersions')) {
        $v = (Get-ItemProperty -LiteralPath $root -Name $name -ErrorAction SilentlyContinue).$name
        if ($null -ne $v -and $v -eq 0) { $tlsBad += ($root + '\' + $name + ' = 0') }
    }
}
$tls12 = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client' -ErrorAction SilentlyContinue
if ($tls12 -and ($tls12.Enabled -eq 0 -or $tls12.DisabledByDefault -eq 1)) { $tlsBad += 'SCHANNEL: TLS 1.2 client disabled' }
if ($tlsBad.Count -gt 0) {
    Add-Finding BAD 'Licensing' 'TLS 1.2 is disabled - sign-in cannot reach Autodesk over HTTPS' ($tlsBad -join ' ; ')
} else {
    Add-Finding OK 'Licensing' 'TLS 1.2 client settings look correct'
}

# ===========================================================================
# 4b. Network License Manager (NLM)
#     An OLD NLM blocks installation of Revit/AutoCAD 2026+
# ===========================================================================
Write-Section 'Network License Manager (NLM)'
$nlmPaths = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared\Network License Manager'),
    (Join-Path $env:ProgramFiles 'Common Files\Autodesk Shared\Network License Manager'),
    'C:\Autodesk\Network License Manager',
    (Join-Path $env:ProgramFiles 'Autodesk\Network License Manager'),
    (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\Network License Manager')
)
$nlmFound = 0
foreach ($np in $nlmPaths) {
    if (Test-Path -LiteralPath $np) {
        $nlmFound++
        $ver = $null
        foreach ($exeName in @('adskflex.exe','lmgrd.exe')) {
            $exe = Join-Path $np $exeName
            if (Test-Path -LiteralPath $exe) { $ver = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion; break }
        }
        Add-Finding WARN 'NLM' ("Network License Manager present: {0}" -f $np) ("version: " + $ver)
    }
}
# license-server binaries in the shared folder (see the -Include note above:
# it is ignored with -LiteralPath, so the path is built with a wildcard)
$shared = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared'
$flex = @()
if (Test-Path -LiteralPath $shared) {
    $flex = @(Get-ChildItem -Path (Join-Path $shared '*') -Recurse -File -Include 'adskflex.exe','lmgrd.exe' -ErrorAction SilentlyContinue | Select-Object -First 5)
    foreach ($f in $flex) { Add-Finding WARN 'NLM' ("License-server binary found: {0}" -f $f.Name) $f.FullName }
}
if ($nlmFound -eq 0 -and $flex.Count -eq 0) {
    Add-Finding OK 'NLM' 'No Network License Manager installation found'
} else {
    Add-Finding INFO 'NLM' 'Revit/AutoCAD 2026+ require a recent NLM; an old one blocks installation' 'Remove or update it before installing 2026 products'
}

# ===========================================================================
# 4c. Autodesk installer cache (ODIS), antivirus & install logs
#     (-> "Unable to install / error while preparing the installation")
# ===========================================================================
Write-Section 'Installer cache (ODIS), antivirus & logs'
foreach ($odis in @(
    (Join-Path $env:ProgramData 'Autodesk\ODIS'),
    (Join-Path $env:LOCALAPPDATA 'Autodesk\ODIS'))) {
    if (Test-Path -LiteralPath $odis) {
        $n = @(Get-ChildItem -LiteralPath $odis -Recurse -File -ErrorAction SilentlyContinue).Count
        Add-Finding INFO 'ODIS' ("Autodesk installer cache: {0} ({1} files)" -f $odis, $n) 'If installs fail while "preparing", clear this folder and retry'
    }
}

# Defender Controlled Folder Access blocks installers
try {
    $mp = Get-MpPreference -ErrorAction Stop
    if ($mp.EnableControlledFolderAccess -eq 1) {
        Add-Finding WARN 'Antivirus' 'Windows Defender Controlled Folder Access is ON - it can block Autodesk installs' ''
    } else {
        Add-Finding OK 'Antivirus' 'Defender Controlled Folder Access is off'
    }
} catch { Add-Finding INFO 'Antivirus' 'Could not query Defender settings' '' }

# third-party security products
try {
    $av = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction SilentlyContinue)
    if ($av.Count -gt 0) {
        Add-Finding INFO 'Antivirus' ('Security products: ' + (($av | ForEach-Object { $_.displayName }) -join ', ')) 'Temporarily disable during install if it blocks'
    }
} catch {}

# recent Autodesk install logs (matched by the "check the log file" message)
try {
    $logs = @()
    $adLocal = Join-Path $env:LOCALAPPDATA 'Autodesk'
    if (Test-Path -LiteralPath $adLocal) {
        $logs += Get-ChildItem -LiteralPath $adLocal -Filter '*.log' -Recurse -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 3
    }
    if (Test-Path -LiteralPath $env:TEMP) {
        $logs += Get-ChildItem -LiteralPath $env:TEMP -Filter '*.log' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'autodesk|odis|install' } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 3
    }
    if ($logs.Count -gt 0) {
        foreach ($l in $logs) { Add-Finding INFO 'Logs' ("Install log: {0}" -f $l.Name) $l.FullName }
    } else {
        Add-Finding INFO 'Logs' 'No recent Autodesk install logs found' ''
    }
} catch {}

# Licensing logs - what a support request actually needs, because the agent log
# names the exact licensing failure. They are collected with -Bundle.
$script:LogFiles = @()
$logSources = @(
    (Join-Path $env:LOCALAPPDATA 'Autodesk\Logs'),
    (Join-Path $env:ProgramData 'Autodesk\AdskLicensingService'),
    (Join-Path $env:ProgramData 'Autodesk\AdskLicensing'),
    (Join-Path $env:LOCALAPPDATA 'Autodesk\AdskLicensingAgent'),
    (Join-Path $env:ProgramData 'Autodesk\CLM\LGS')
)
foreach ($src in $logSources) {
    if (Test-Path -LiteralPath $src) {
        $script:LogFiles += @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue |
                              Where-Object { $_.Extension -in '.log','.txt' } |
                              Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    }
}
$script:LogFiles = @($script:LogFiles | Sort-Object FullName -Unique)
if ($script:LogFiles.Count -gt 0) {
    $newest = $script:LogFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Add-Finding INFO 'Logs' ('Licensing logs available: {0} file(s), newest "{1}" ({2})' -f $script:LogFiles.Count, $newest.Name, $newest.LastWriteTime) 'The agent log names the exact licensing failure - collect them with -Bundle'
} else {
    Add-Finding INFO 'Logs' 'No licensing logs found' 'No product has tried to license on this machine yet'
}

# Show the reason instead of only filing it away: the newest logs are scanned
# for failure lines and a few of them are printed in the report itself. Email
# addresses are masked, and the full files go into the -Bundle zip.
$hintFiles = @($script:LogFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 2)
$hints = 0
foreach ($hf in $hintFiles) {
    if ($hints -ge 8) { break }
    $tail = @(Get-Content -LiteralPath $hf.FullName -Tail 300 -ErrorAction SilentlyContinue)
    foreach ($line in $tail) {
        if ($hints -ge 8) { break }
        if ($line -notmatch '(?i)\b(error|fail(ed|ure)?|fatal|exception|denied|refused|unable|cannot|timeout|invalid|corrupt|expired|revoked)\b') { continue }
        $clean = ($line -replace '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '***@***').Trim()
        if ($clean.Length -gt 200) { $clean = $clean.Substring(0, 200) + '...' }
        Add-Finding INFO 'Logs' ('Log: ' + $clean) $hf.Name
        $hints++
    }
}
if ($hints -gt 0) {
    Add-Finding INFO 'Logs' ('{0} failure line(s) taken from the newest licensing logs' -f $hints) 'The full logs are collected by the support bundle (-Bundle)'
}

# ===========================================================================
# 5. Installed products - executable signature scan
# ===========================================================================
Write-Section 'Product executables (signature scan)'
$productRoot = Join-Path $env:ProgramFiles 'Autodesk'
if (Test-Path -LiteralPath $productRoot) {
    $productDirs = @(Get-ChildItem -LiteralPath $productRoot -Directory)
    Add-Finding INFO 'Products' ('Products: ' + (($productDirs.Name) -join ', ')) ''
    foreach ($p in $productDirs) {
        foreach ($name in @('acad.exe','revit.exe','3dsmax.exe','maya.exe','AdlmInt.dll','AdlmInt64.dll')) {
            $f = Get-ChildItem -LiteralPath $p.FullName -Filter $name -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) { Test-AutodeskSigned -FilePath $f.FullName -Label ("{0} ({1})" -f $name, $p.Name) -Strict }
        }
    }
} else {
    Add-Finding INFO 'Products' 'No Autodesk products under Program Files\Autodesk' ''
}

# ===========================================================================
# 6. Crack leftovers / suspicious files
# ===========================================================================
Write-Section 'Crack leftovers'
$flexnet = Join-Path $env:ProgramData 'FLEXnet'
if (Test-Path -LiteralPath $flexnet) {
    $fn = @(Get-ChildItem -LiteralPath $flexnet -Force)
    Add-Finding WARN 'Leftovers' ("ProgramData\FLEXnet present ({0} items) - fake license-server leftovers?" -f $fn.Count) $flexnet
} else { Add-Finding OK 'Leftovers' 'No ProgramData\FLEXnet leftovers' }

foreach ($path in @(
    (Join-Path $env:ProgramData 'Autodesk\CLM\LGS'),
    (Join-Path $env:ProgramData 'Autodesk\Web Services'),
    (Join-Path $env:ProgramData 'Autodesk\Adlm'),
    'C:\Autodesk')) {
    if (Test-Path -LiteralPath $path) { Add-Finding INFO 'Leftovers' ("Found: {0}" -f $path) '' }
}

# The legacy ADLM licence cache. A patched ProductInformation.pit is one of the
# classic non-genuine activation leftovers, and ADLS ignores the file, so the
# Cleanup step resets it (the backup restores it if you roll back). Only the
# known cache locations are searched: a recursive sweep of all of ProgramData
# could take minutes on a busy machine.
$pit = @()
foreach ($loc in @(
    (Join-Path $env:ProgramData 'Autodesk\Adlm'),
    (Join-Path $env:ProgramData 'Autodesk\CLM\LGS'),
    (Join-Path $env:ProgramData 'FLEXnet'))) {
    if (Test-Path -LiteralPath $loc) {
        $pit += @(Get-ChildItem -LiteralPath $loc -Filter 'ProductInformation.pit' -Recurse -File -ErrorAction SilentlyContinue)
    }
}
foreach ($f in @($pit | Select-Object -First 5)) { Add-Finding WARN 'Leftovers' ('ProductInformation.pit - legacy licence cache (the Cleanup step resets it) - ' + $f.LastWriteTime) $f.FullName }

# suspicious file names inside Autodesk trees
$suspName = 'crack|keygen|licgen|xforce|xf-|adskflex|lmgrd|_orig|\.bak$|\.old$'
foreach ($root in @($commonFiles, $productRoot)) {
    if (Test-Path -LiteralPath $root) {
        $hits = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $suspName } | Select-Object -First 20)
        foreach ($h in $hits) { Add-Finding BAD 'Leftovers' ("Suspicious file name: {0}" -f $h.Name) $h.FullName }
    }
}

# ===========================================================================
# 6b. Image File Execution Options (IFEO) - execution blockers
#     A very common crack side effect: squeeze a "Debugger" value onto
#     AdskLicensingService.exe, the Genuine Service or a product exe. Windows
#     then launches something else (or nothing) instead, so the official
#     licensing stack can never start - and the Repair step cannot fix it
#     while the block is in place.
# ===========================================================================
Write-Section 'Execution blockers (IFEO)'
$ifeoRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
)
$ifeoSeen = 0
foreach ($ifeoRoot in $ifeoRoots) {
    if (-not (Test-Path -LiteralPath $ifeoRoot)) { continue }
    foreach ($k in @(Get-ChildItem -LiteralPath $ifeoRoot -ErrorAction SilentlyContinue)) {
        $dbg = $null
        try { $dbg = [string](Get-ItemProperty -LiteralPath $k.PSPath -Name 'Debugger' -ErrorAction Stop).Debugger } catch {}
        if (-not $dbg) { continue }
        $autodeskish = $k.PSChildName -match 'adsk|autodesk|genuine|flexnet|flexlm|licens'
        $suspicious  = Get-PathSuspicion $dbg
        if ($autodeskish -or $suspicious) {
            $sev = if ($autodeskish) { 'BAD' } else { 'WARN' }
            Add-Finding $sev 'IFEO' ("Execution blocked via Debugger: {0}" -f $k.PSChildName) $dbg
            $ifeoSeen++
        }
    }
}
if ($ifeoSeen -eq 0) { Add-Finding OK 'IFEO' 'No Autodesk execution blockers (IFEO Debugger keys)' }

# ===========================================================================
# 7. Registry
# ===========================================================================
Write-Section 'Registry'
$regKeys = @(
    'HKLM:\SOFTWARE\Autodesk',
    'HKLM:\SOFTWARE\WOW6432Node\Autodesk',
    'HKCU:\SOFTWARE\Autodesk',
    'HKLM:\SOFTWARE\FLEXlm License Manager',
    'HKLM:\SOFTWARE\WOW6432Node\FLEXlm License Manager'
)
$suspTokens = '127\.0\.0\.1|localhost|crack|keygen|licgen|xf-|activation=off|genuine'
foreach ($key in $regKeys) {
    if (-not (Test-Path -LiteralPath $key)) { continue }
    if ($key -match 'FLEXlm') {
        Add-Finding BAD 'Registry' ("Cracked license-server key present: {0}" -f $key) ''
    } else {
        Add-Finding INFO 'Registry' ("Key present: {0}" -f $key) ''
    }
    # inspect values one level deep for suspicious data
    try {
        $item = Get-Item -LiteralPath $key
        foreach ($vn in $item.GetValueNames()) {
            $val = [string]$item.GetValue($vn)
            if ($val -match $suspTokens) {
                Add-Finding WARN 'Registry' ("Suspicious value {0}\\{1}" -f $key, $vn) $val
            }
        }
        foreach ($sub in $item.GetSubKeyNames()) {
            $subPath = Join-Path $key $sub
            $subItem = Get-Item -LiteralPath $subPath
            foreach ($vn in $subItem.GetValueNames()) {
                $val = [string]$subItem.GetValue($vn)
                if ($val -match $suspTokens) {
                    Add-Finding WARN 'Registry' ("Suspicious value {0}\\{1}" -f $subPath, $vn) $val
                }
            }
        }
    } catch {}
}
if (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\FLEXlm License Manager') -and
    -not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\WOW6432Node\FLEXlm License Manager')) {
    Add-Finding OK 'Registry' 'No FLEXlm License Manager key'
}

# ===========================================================================
# 8. Environment variables
# ===========================================================================
Write-Section 'Environment variables'
$envHit = @()
foreach ($scope in @(@{n='Machine';d=[Environment]::GetEnvironmentVariables('Machine')},
                     @{n='User';d=[Environment]::GetEnvironmentVariables('User')})) {
    foreach ($k in $scope.d.Keys) {
        if ($k -match 'ADSK|AUTODESK|FLEXLM|LICPATH') {
            $envHit += ("{0}:{1}={2}" -f $scope.n, $k, $scope.d[$k])
        }
    }
}
if ($envHit.Count -gt 0) { Add-Finding INFO 'Env' ('Autodesk env vars: ' + $envHit.Count) ($envHit -join ' ; ') }
else { Add-Finding OK 'Env' 'No suspicious Autodesk environment variables' }

# ===========================================================================
# 9. Scheduled tasks (by name AND by action target)
# ===========================================================================
Write-Section 'Scheduled tasks'
try {
    $tasks = @(Get-ScheduledTask)
    $found = $false
    foreach ($t in $tasks) {
        $nameHit = ($t.TaskName -match 'autodesk|adsk|flexnet')
        $exe = $null
        foreach ($a in $t.Actions) { if ($a.Execute) { $exe = $a.Execute; break } }
        $pathHit = ($exe -and $exe -match 'autodesk|adsk|flexnet')
        if ($nameHit -or $pathHit) {
            $found = $true
            $detail = "State=$($t.State); Exec=$exe"
            $sev = 'INFO'
            $susp = Get-PathSuspicion $exe
            if ($susp) { $sev = $susp; $detail += ' (suspicious path)' }
            Add-Finding $sev 'Tasks' ("Task: {0} [{1}]" -f $t.TaskName, $t.State) $detail
        }
    }
    if (-not $found) { Add-Finding OK 'Tasks' 'No Autodesk-related scheduled tasks' }
} catch {
    Add-Finding WARN 'Tasks' 'Could not enumerate scheduled tasks' $_.Exception.Message
}

# ===========================================================================
# 10. Startup entries
# ===========================================================================
Write-Section 'Startup entries'
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
)
$startupHit = $false
foreach ($rk in $runKeys) {
    if (-not (Test-Path -LiteralPath $rk)) { continue }
    $item = Get-Item -LiteralPath $rk
    foreach ($vn in $item.GetValueNames()) {
        $val = [string]$item.GetValue($vn)
        if ($vn -match 'autodesk|adsk|flexnet' -or $val -match 'autodesk|adsk|flexnet') {
            $startupHit = $true
            $sev = 'INFO'; $susp = Get-PathSuspicion $val; if ($susp) { $sev = $susp }
            Add-Finding $sev 'Startup' ("Run key: {0} = {1}" -f $vn, $val) $rk
        }
    }
}
foreach ($sf in @(
    (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'),
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'))) {
    if (Test-Path -LiteralPath $sf) {
        foreach ($f in @(Get-ChildItem -LiteralPath $sf -File)) {
            if ($f.Name -match 'autodesk|adsk|flexnet') {
                $startupHit = $true
                Add-Finding WARN 'Startup' ("Startup folder item: {0}" -f $f.Name) $f.FullName
            }
        }
    }
}
if (-not $startupHit) { Add-Finding OK 'Startup' 'No Autodesk startup entries' }

# ===========================================================================
# 11. Running processes
# ===========================================================================
Write-Section 'Running processes'
try {
    # The toolkit itself matches the "adsk" pattern and may run from a user
    # profile (the portable zip), so its own processes are excluded - an earlier
    # build reported itself as a suspicious running process.
    $procs = @(Get-Process | Where-Object {
        $_.ProcessName -match 'autodesk|adsk|acad|revit|3dsmax|maya|flexnet|flexlm|lmgrd|adskflex|nimsoft|adlm' -and
        $_.ProcessName -notmatch 'adskdoctor|unlock-digital'
    })
    if ($procs.Count -gt 0) {
        foreach ($pr in $procs) {
            $ppath = $null
            try { $ppath = $pr.Path } catch {}
            # A path alone decides nothing: Autodesk ships genuine per-user
            # products (Access, Fusion) under %LOCALAPPDATA%, so the signature of
            # the binary is the real signal.
            $sev  = 'INFO'
            $note = ''
            if ($ppath -and (Test-Path -LiteralPath $ppath)) {
                $sig = Get-AuthenticodeSignature -LiteralPath $ppath -ErrorAction SilentlyContinue
                if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'Autodesk') {
                    $note = 'Autodesk-signed'
                } elseif ($sig.Status -eq 'HashMismatch') {
                    $sev = 'BAD'; $note = 'signature broken - patched binary'
                } elseif ($sig.Status -eq 'Valid') {
                    $sev = 'WARN'; $note = ('signed by ' + $sig.SignerCertificate.Subject)
                } else {
                    $sev = 'WARN'; $note = 'unsigned binary'
                }
                if ($note -ne 'Autodesk-signed') {
                    $psk = Get-PathSuspicion $ppath
                    if ($psk -eq 'BAD') { $sev = 'BAD' }
                    elseif ($psk -and $sev -eq 'INFO') { $sev = 'WARN' }
                }
            }
            if ($pr.ProcessName -match 'lmgrd|adskflex|flexlm') { $sev = 'BAD' }
            Add-Finding $sev 'Processes' ("Process running: {0} (PID {1})" -f $pr.ProcessName, $pr.Id) ($ppath + $(if ($note) { ' | ' + $note } else { '' }))
        }
    } else { Add-Finding OK 'Processes' 'No Autodesk/license processes running' }
} catch {
    Add-Finding WARN 'Processes' 'Could not enumerate processes' $_.Exception.Message
}

# ===========================================================================
# 12. Local fake license server (listening FLEXlm ports)
# ===========================================================================
Write-Section 'Local license server'
try {
    $listen = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPort -ge 27000 -and $_.LocalPort -le 27009 -or $_.LocalPort -eq 2080 })
    if ($listen.Count -gt 0) {
        foreach ($l in $listen) {
            $owner = (Get-Process -Id $l.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            Add-Finding WARN 'LicenseServer' ("Listening on port {0} (possible local license server)" -f $l.LocalPort) ("Process=" + $owner)
        }
    } else { Add-Finding OK 'LicenseServer' 'No FLEXlm-style ports listening (no local crack server)' }
} catch {
    Add-Finding INFO 'LicenseServer' 'Could not enumerate TCP listeners' ''
}

# ===========================================================================
# 13. Connectivity
# ===========================================================================
Write-Section 'Connectivity (port 443)'
foreach ($h in $AutodeskHosts) {
    $resolved = $null
    try { $resolved = (Resolve-DnsName -Name $h -Type A -ErrorAction Stop | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress } catch {}
    $blocked = ($resolved -match '^(127\.|0\.0\.0\.0|::1)')
    $reachable = Test-TcpPort -ComputerName $h -Port 443
    if ($blocked) { Add-Finding BAD 'Network' ("{0} resolves to {1} (hijacked)" -f $h, $resolved) '' }
    elseif (-not $resolved) { Add-Finding INFO 'Network' ("{0} did not resolve (may be normal)" -f $h) '' }
    elseif ($reachable) { Add-Finding OK 'Network' ("{0} reachable on 443 ({1})" -f $h, $resolved) '' }
    else { Add-Finding WARN 'Network' ("{0} NOT reachable on 443 ({1})" -f $h, $resolved) 'Proxy/firewall/DNS' }
}

# ===========================================================================
# 14. Proxy
# ===========================================================================
Write-Section 'Proxy'
try {
    $proxy = (netsh winhttp show proxy 2>$null | Out-String).Trim()
    Add-Finding INFO 'Proxy' 'WinHTTP proxy setting' $proxy
} catch {}

# ===========================================================================
# Summary
# ===========================================================================
$badCount  = @($script:Findings | Where-Object { $_.Status -eq 'BAD'  }).Count
$warnCount = @($script:Findings | Where-Object { $_.Status -eq 'WARN' }).Count
$okCount   = @($script:Findings | Where-Object { $_.Status -eq 'OK'   }).Count

# One patched folder can raise hundreds of findings, and a wall of red rows says
# nothing about what to DO. Group the problems by area, then let the verdict name
# the step that actually fixes them.
$badByCat  = @($script:Findings | Where-Object { $_.Status -eq 'BAD'  } | Group-Object Category | Sort-Object Count -Descending)
$warnByCat = @($script:Findings | Where-Object { $_.Status -eq 'WARN' } | Group-Object Category | Sort-Object Count -Descending)

function Get-AreaCount {
    param([string[]]$Names)
    [int]($badByCat | Where-Object { $Names -contains $_.Name } | Measure-Object -Property Count -Sum).Sum
}
$licBad   = Get-AreaCount @('Licensing','Services')
$crackBad = Get-AreaCount @('Hosts','Firewall','IFEO','Registry','Leftovers','NLM','Tasks','Startup','Processes','Environment')
$sigBad   = Get-AreaCount @('Signatures')

$verdict =
    if ($licBad -gt 0)       { "Official licensing stack needs repair ($licBad problem(s)) -> run the Repair step." }
    elseif ($crackBad -gt 0) { "Non-genuine leftovers found ($crackBad) -> run the Cleanup step." }
    elseif ($sigBad -gt 0)   { "Found $sigBad patched or unrecognised file(s). A cleanup cannot repair those - the product has to be repaired or reinstalled from the official installer." }
    elseif ($warnCount -gt 0){ 'Mostly fine; review the warnings.' }
    else                     { 'Looks genuine and healthy.' }
$verdictColor = if ($badCount -gt 0) { 'Red' } elseif ($warnCount -gt 0) { 'Yellow' } else { 'Green' }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   SUMMARY' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("   Problems (FAIL) : {0}" -f $badCount)  -ForegroundColor $(if ($badCount) {'Red'} else {'Green'})
Write-Host ("   Warnings (WARN) : {0}" -f $warnCount) -ForegroundColor $(if ($warnCount) {'Yellow'} else {'Green'})
Write-Host ("   Healthy  ( OK ) : {0}" -f $okCount)  -ForegroundColor Green
if ($badByCat.Count) {
    Write-Host ''
    Write-Host '   Problems by area:' -ForegroundColor Red
    foreach ($g in $badByCat) { Write-Host ("      {0,-15} {1}" -f $g.Name, $g.Count) -ForegroundColor Red }
}
if ($warnByCat.Count) {
    Write-Host ''
    Write-Host '   Warnings by area:' -ForegroundColor Yellow
    foreach ($g in $warnByCat) { Write-Host ("      {0,-15} {1}" -f $g.Name, $g.Count) -ForegroundColor Yellow }
}
Write-Host ''
Write-Host ("   VERDICT: {0}" -f $verdict) -ForegroundColor $verdictColor
Write-Host ''

# ===========================================================================
# Export
# ===========================================================================
if ($Export) {
    try {
        $dir = Split-Path -Parent $Export
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        if ($Json) {
            [pscustomobject]@{
                Computer   = $env:COMPUTERNAME
                Date       = (Get-Date).ToString('s')
                Admin      = $isAdmin
                Summary    = [pscustomobject]@{ Fail = $badCount; Warn = $warnCount; Ok = $okCount }
                FailByArea = $badByCat
                WarnByArea = $warnByCat
                Verdict    = $verdict
                Findings   = $script:Findings
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Export -Encoding UTF8
        }
        elseif ($Html) {
            function HtmlEnc($s) { ([string]$s) -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
            $rows = ''
            foreach ($f in $script:Findings) {
                $cls = @{ OK='ok'; WARN='warn'; BAD='bad'; INFO='info' }[$f.Status]
                $rows += "<tr class='$cls'><td>$($f.Status)</td><td>$(HtmlEnc $f.Category)</td><td>$(HtmlEnc $f.Message)</td><td>$(HtmlEnc $f.Detail)</td></tr>`n"
            }
            # a short "what to fix first" block above the (possibly huge) detail list
            $areaRows = ''
            foreach ($g in $badByCat)  { $areaRows += "<tr class='bad'><td>FAIL</td><td>$(HtmlEnc $g.Name)</td><td>$($g.Count)</td></tr>`n" }
            foreach ($g in $warnByCat) { $areaRows += "<tr class='warn'><td>WARN</td><td>$(HtmlEnc $g.Name)</td><td>$($g.Count)</td></tr>`n" }
            $areaBlock = if ($areaRows) {
                "<h3>Problems by area</h3>`n<table style='width:auto'><thead><tr><th>Status</th><th>Area</th><th>Count</th></tr></thead><tbody>`n$areaRows</tbody></table>"
            } else { '' }
            $htmlDoc = @"
<!DOCTYPE html><html><head><meta charset='utf-8'>
<title>AdskDoctor report - $env:COMPUTERNAME</title>
<style>
 body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#222}
 h1{font-size:20px} .sum span{display:inline-block;padding:6px 12px;border-radius:6px;margin-right:8px;color:#fff}
 .bad{background:#c0392b}.warn{background:#e67e22}.ok{background:#27ae60}.info{background:#7f8c8d}
 table{border-collapse:collapse;width:100%;margin-top:16px;font-size:13px}
 th,td{border:1px solid #ddd;padding:6px 8px;text-align:left;vertical-align:top}
 th{background:#f4f4f4} tr.bad td:first-child{color:#c0392b;font-weight:700}
 tr.warn td:first-child{color:#e67e22;font-weight:700} tr.ok td:first-child{color:#27ae60}
</style></head><body>
<h1>Autodesk Licensing Doctor - Diagnostic Report</h1>
<p><b>Computer:</b> $env:COMPUTERNAME<br>
<b>Date:</b> $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')<br>
<b>OS:</b> $(HtmlEnc $os.Caption) (build $($os.BuildNumber))<br>
<b>Admin:</b> $isAdmin</p>
<p class='sum'><span class='bad'>FAIL: $badCount</span><span class='warn'>WARN: $warnCount</span><span class='ok'>OK: $okCount</span></p>
<p><b>Verdict:</b> $(HtmlEnc $verdict)</p>
$areaBlock
<table><thead><tr><th>Status</th><th>Category</th><th>Finding</th><th>Detail</th></tr></thead>
<tbody>
$rows
</tbody></table></body></html>
"@
            Set-Content -LiteralPath $Export -Value $htmlDoc -Encoding UTF8
        }
        else {
            $lines = @(
                'Autodesk Licensing Doctor - Diagnostic report',
                "Computer : $env:COMPUTERNAME",
                "Date     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
                "Summary  : FAIL=$badCount WARN=$warnCount OK=$okCount",
                "Verdict  : $verdict"
            )
            foreach ($g in $badByCat)  { $lines += ("Fail area: {0} ({1})" -f $g.Name, $g.Count) }
            foreach ($g in $warnByCat) { $lines += ("Warn area: {0} ({1})" -f $g.Name, $g.Count) }
            $lines += ('-' * 60)
            foreach ($f in $script:Findings) {
                $lines += ("[{0}] {1,-10} {2}" -f $f.Status, $f.Category, $f.Message)
                if ($f.Detail) { $lines += ("        -> " + $f.Detail) }
            }
            $lines | Set-Content -LiteralPath $Export -Encoding UTF8
        }
        Write-Host ("Report written to: {0}" -f $Export) -ForegroundColor Green
    } catch {
        Write-Host ("Could not write report: {0}" -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ($_.InvocationInfo.PositionMessage) -ForegroundColor DarkGray
    }
}

# ===========================================================================
# Support bundle  (report + licensing logs + system info in one zip)
# ===========================================================================
if ($Bundle) {
    try {
        $base  = if ($Export) { Split-Path -Parent $Export } else { (Get-Location).Path }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmm'
        $stage = Join-Path $env:TEMP ('adskdoctor-bundle-' + $stamp)
        $logDir = Join-Path $stage 'logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null

        if ($Export -and (Test-Path -LiteralPath $Export)) {
            Copy-Item -LiteralPath $Export -Destination (Join-Path $stage (Split-Path -Leaf $Export)) -Force
        }
        $i = 0
        foreach ($lf in $script:LogFiles) {
            if ($lf.Length -gt 10MB) { continue }   # keep the bundle sendable
            $i++
            # the source folder keeps two "agent-stdout.log" files apart
            $tag = Split-Path -Leaf (Split-Path -Parent $lf.FullName)
            Copy-Item -LiteralPath $lf.FullName -Destination (Join-Path $logDir ("{0:D2}-{1}-{2}" -f $i, $tag, $lf.Name)) -Force -ErrorAction SilentlyContinue
        }

        $info = @(
            'Autodesk Licensing Doctor - support bundle',
            ('Computer : ' + $env:COMPUTERNAME),
            ('User     : ' + $env:USERNAME),
            ('Date     : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
            ('OS       : ' + $os.Caption + ' (build ' + $os.BuildNumber + ')'),
            ('Admin    : ' + $isAdmin),
            ('Shell    : PowerShell ' + $PSVersionTable.PSVersion.ToString()),
            ('Summary  : FAIL=' + $badCount + ' WARN=' + $warnCount + ' OK=' + $okCount),
            ('Verdict  : ' + $verdict),
            '',
            'Problems by area:'
        )
        foreach ($g in $badByCat)  { $info += ('  FAIL  ' + $g.Name + ' (' + $g.Count + ')') }
        foreach ($g in $warnByCat) { $info += ('  WARN  ' + $g.Name + ' (' + $g.Count + ')') }
        $info += ''
        $info += ('Licensing logs collected: ' + $i)
        $info | Set-Content -LiteralPath (Join-Path $stage 'system-info.txt') -Encoding UTF8

        $zip = Join-Path $base ('AdskDoctor-Support-' + $env:COMPUTERNAME + '-' + $stamp + '.zip')
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host ''
        Write-Host ("Support bundle: {0}" -f $zip) -ForegroundColor Green
        Write-Host '   (the report + licensing logs + system info - send this one file with a support request)' -ForegroundColor DarkGray
    } catch {
        Write-Host ("Could not create the support bundle: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}
