<#
    AdskDoctor.ps1  -  Phase 1: DIAGNOSTIC (read-only, enhanced)
    ------------------------------------------------------------
    Deep, read-only scan for Autodesk licensing problems caused by
    cracked ("non-genuine") installs. CHANGES NOTHING.

    Coverage:
      - System / environment readiness (admin, restore point, pending reboot)
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

    Usage:
      .\AdskDoctor.ps1
      .\AdskDoctor.ps1 -Export C:\temp\report.txt
      .\AdskDoctor.ps1 -Json -Export C:\temp\report.json
      .\AdskDoctor.ps1 -Html -Export C:\temp\report.html
#>

[CmdletBinding()]
param(
    [switch]$Json,
    [switch]$Html,
    [string]$Export
)

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
                Add-Finding OK 'Files' ("Genuine (Autodesk-signed): {0}" -f $Label) $FilePath
            } else {
                Add-Finding WARN 'Files' ("Signed but not by Autodesk: {0}" -f $Label) ($FilePath + ' | ' + $subject)
            }
        }
        'NotSigned' {
            $sev = if ($Strict) { 'BAD' } else { 'WARN' }
            Add-Finding $sev 'Files' ("UNSIGNED ({0}): {1}" -f $(if($Strict){'expected Autodesk signature'}else{'review'}), $Label) $FilePath
        }
        default {
            Add-Finding BAD 'Files' ("SIGNATURE INVALID [{0}] - patched/cracked: {1}" -f $sig.Status, $Label) $FilePath
        }
    }
}

# Scan every exe/dll in a folder; report bad signatures.
function Scan-FolderSignatures {
    param([string]$Root, [string]$Tag, [switch]$Strict)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $files = Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.exe','*.dll' -ErrorAction SilentlyContinue
    $bad = 0
    foreach ($f in $files) {
        $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName
        if ($sig.Status -eq 'NotSigned') {
            if ($Strict) { Add-Finding BAD 'Files' ("UNSIGNED in {0}: {1}" -f $Tag, $f.Name) $f.FullName; $bad++ }
        } elseif ($sig.Status -ne 'Valid') {
            Add-Finding BAD 'Files' ("INVALID signature in {0}: {1}" -f $Tag, $f.Name) $f.FullName
            $bad++
        }
    }
    if ($bad -eq 0) {
        Add-Finding OK 'Files' ("All binaries in {0} have valid signatures" -f $Tag)
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
            if ($exe -and (Test-Path -LiteralPath $exe)) {
                Test-AutodeskSigned -FilePath $exe -Label ("service {0}" -f $s.Name) -Strict
            }
        }
    } else {
        Add-Finding WARN 'Services' 'No Autodesk/FlexNet services found at all' 'Official products register ADLS/Access services'
    }

    $adls = $svc | Where-Object { $_.Name -eq 'AdskLicensingService' }
    if ($adls) {
        if ($adls.State -eq 'Running') { Add-Finding OK 'Services' 'AdskLicensingService present and running' }
        else { Add-Finding WARN 'Services' ("AdskLicensingService present but State={0}" -f $adls.State) 'The product will show "Connection Lost to Autodesk Desktop Licensing Service"' }
        if ($adls.StartMode -eq 'Disabled') { Add-Finding WARN 'Services' 'AdskLicensingService start mode is Disabled' 'Set it to Automatic' }
    } else {
        Add-Finding BAD 'Services' 'AdskLicensingService (ADLS) is MISSING - single-user licensing cannot work' 'Causes "Desktop Licensing Service - Connection Lost" and licensing errors'
    }
    # the agent component the app also talks to
    $agent = $svc | Where-Object { $_.Name -match 'AdskLicensingAgent' }
    if (-not $agent) { Add-Finding WARN 'Services' 'AdskLicensingAgent not found (part of the licensing stack)' '' }
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
        Add-Finding INFO 'Files' ('AdskLicensing versions: ' + (($versions.Name) -join ', ')) $adskLicensingRoot
        Scan-FolderSignatures -Root $adskLicensingRoot -Tag 'AdskLicensing'
    } else { Add-Finding WARN 'Files' 'AdskLicensing folder exists but is empty' $adskLicensingRoot }
} else {
    Add-Finding BAD 'Files' 'AdskLicensing folder NOT found' ("Expected: " + $adskLicensingRoot)
}

if (Test-Path -LiteralPath $adSSO) {
    Add-Finding OK 'Files' 'AdSSO (Single Sign-On) component present' $adSSO
    Scan-FolderSignatures -Root $adSSO -Tag 'AdSSO'
} else {
    Add-Finding WARN 'Files' 'AdSSO component not found' ("Expected: " + $adSSO)
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
# license-server binaries in the shared folder
$shared = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared'
$flex = @()
if (Test-Path -LiteralPath $shared) {
    $flex = @(Get-ChildItem -LiteralPath $shared -Recurse -Include 'adskflex.exe','lmgrd.exe' -ErrorAction SilentlyContinue | Select-Object -First 5)
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
    'C:\Autodesk')) {
    if (Test-Path -LiteralPath $path) { Add-Finding INFO 'Leftovers' ("Found: {0}" -f $path) '' }
}

$pit = @(Get-ChildItem -LiteralPath $env:ProgramData -Filter 'ProductInformation.pit' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 5)
foreach ($f in $pit) { Add-Finding WARN 'Leftovers' ('ProductInformation.pit (verify not patched) - ' + $f.LastWriteTime) $f.FullName }

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
    $procs = @(Get-Process | Where-Object {
        $_.ProcessName -match 'autodesk|adsk|acad|revit|3dsmax|maya|flexnet|flexlm|lmgrd|adskflex|nimsoft|adlm'
    })
    if ($procs.Count -gt 0) {
        foreach ($pr in $procs) {
            $ppath = $null
            try { $ppath = $pr.Path } catch {}
            $sev = 'INFO'; $susp = Get-PathSuspicion $ppath; if ($susp) { $sev = $susp }
            if ($pr.ProcessName -match 'lmgrd|adskflex|flexlm') { $sev = 'BAD' }
            Add-Finding $sev 'Processes' ("Process running: {0} (PID {1})" -f $pr.ProcessName, $pr.Id) $ppath
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

$verdict = if ($badCount -gt 0) { 'Machine has non-genuine leftovers -> needs cleaning.' }
           elseif ($warnCount -gt 0) { 'Mostly fine; review the warnings.' }
           else { 'Looks genuine and healthy.' }
$verdictColor = if ($badCount -gt 0) { 'Red' } elseif ($warnCount -gt 0) { 'Yellow' } else { 'Green' }

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   SUMMARY' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("   Problems (FAIL) : {0}" -f $badCount)  -ForegroundColor $(if ($badCount) {'Red'} else {'Green'})
Write-Host ("   Warnings (WARN) : {0}" -f $warnCount) -ForegroundColor $(if ($warnCount) {'Yellow'} else {'Green'})
Write-Host ("   Healthy  ( OK ) : {0}" -f $okCount)  -ForegroundColor Green
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
                Computer = $env:COMPUTERNAME
                Date     = (Get-Date).ToString('s')
                Admin    = $isAdmin
                Summary  = [pscustomobject]@{ Fail = $badCount; Warn = $warnCount; Ok = $okCount }
                Verdict  = $verdict
                Findings = $script:Findings
            } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Export -Encoding UTF8
        }
        elseif ($Html) {
            function HtmlEnc($s) { ([string]$s) -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
            $rows = ''
            foreach ($f in $script:Findings) {
                $cls = @{ OK='ok'; WARN='warn'; BAD='bad'; INFO='info' }[$f.Status]
                $rows += "<tr class='$cls'><td>$($f.Status)</td><td>$(HtmlEnc $f.Category)</td><td>$(HtmlEnc $f.Message)</td><td>$(HtmlEnc $f.Detail)</td></tr>`n"
            }
            $htmlDoc = @"
<!DOCTYPE html><html><head><meta charset='utf-8'>
<title>AkdskDoctor report - $env:COMPUTERNAME</title>
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
                "Verdict  : $verdict",
                ('-' * 60)
            )
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
