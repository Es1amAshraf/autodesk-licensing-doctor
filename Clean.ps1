<#
    Clean.ps1  -  Phase 3: SAFE CLEANUP (preview by default)
    ---------------------------------------------------------------------------
    Removes the leftovers that break Autodesk official licensing, based on the
    exact causes seen in the field:
      - old Network License Manager (adskflex/lmgrd)  -> blocks Revit/AutoCAD 2026+
      - FLEXlm license-server leftovers
      - hosts hijacks (incl. blocked time servers) + firewall blocks
      - crack-scheduled tasks & startup entries (Run / RunOnce)
      - Defender exclusions that hide patched files
      - execution blockers (IFEO Debugger keys on Autodesk services)
      - Autodesk installer cache (ODIS) -> "error while preparing installation"
      - suspicious environment variables
      - a broken system clock -> "Clock Error"

    SAFETY:
      - Default is PREVIEW (changes nothing). Add -Apply to actually run.
      - With -Apply, a full layered backup (Phase 2) runs FIRST and aborts
        the cleanup if the backup fails.
      - Nothing is deleted without a matching backup.

    Usage:
      .\Clean.ps1                       # preview
      .\Clean.ps1 -Apply                # backup + clean
      .\Clean.ps1 -Apply -KeepNLM       # keep Network License Manager
      .\Clean.ps1 -Apply -SkipBackup    # (not recommended)
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$SkipBackup,
    [switch]$KeepNLM,
    [string]$BackupRoot
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
    } else {
        Write-Host ("  [preview] {0}" -f $Desc) -ForegroundColor DarkGray
    }
}
function Section { param([string]$t) Write-Host ''; Write-Host ("== {0} ==" -f $t) -ForegroundColor Cyan }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ExeFromCommandLine {
    param([string]$CommandLine)
    if (-not $CommandLine) { return $null }
    if ($CommandLine -match '^\s*"([^"]+\.exe)"') { return $matches[1] }
    # An unquoted path may still contain spaces (C:\Program Files\Autodesk\
    # Genuine Service\GenuineService.exe - a real Autodesk Run value): take
    # everything up to the first .exe, not just the first space-free token.
    if ($CommandLine -match '^\s*(.+?\.exe)\b')   { return $matches[1].Trim('"') }
    return $null
}

# A path is crack-suspicious when it lives outside the normal program folders
# or carries a known crack-tool name. The khale case runs C:\FlexLM\adskflex.exe
# from a task, a Run value and a LICPATH variable, so the check has to cover
# names, not just the user folders.
function Test-SuspiciousExecPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    $p = $Path.ToLowerInvariant()
    if ($p -match '\\appdata\\|\\temp\\|\\users\\|\\programdata\\|\\downloads\\') { return $true }
    return [bool]($p -match 'flexlm|adskflex|lmgrd|lmutil|lmadmin|keygen|xf-adsk|xforce|crack|licgen')
}

# A FlexNet/FLEXlm-named service is crack tooling only when its binary is gone
# or lives in a suspicious place. The genuine Flexera service
# (FNPLicensingService64.exe under Program Files\Common Files\Macrovision
# Shared, signed by Flexera) is infrastructure other software uses, and the lab
# run wrongly deleted it because the name matched "flexnet" (2026-10-16).
function Test-CrackFlexService {
    param([string]$Name)
    $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    $bin = Get-ExeFromCommandLine $svc.PathName
    if (-not $bin) { return $true }                                  # no binary at all
    return (Test-SuspiciousExecPath $bin) -or (-not (Test-Path -LiteralPath $bin))
}

# A startup target is only left alone when it is a real, intact binary. A dead
# path, a patched file (HashMismatch), or an unsigned helper in the Autodesk
# tree is exactly what an activator leaves behind, so those are removed.
function Test-KeepStartupTarget {
    param([string]$Path)
    try { $status = [string](Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop).Status }
    catch { return $true }   # the check itself failed - never remove on that
    return -not ($status -in @('HashMismatch','NotSigned','UnknownError'))
}

# A hosts line is a hijack when it points an Autodesk domain somewhere local,
# or when it blocks the Windows time servers (a crack does both).
function Test-BadHostsLine {
    param([string]$Line)
    $c = ($Line -split '#')[0].Trim()
    if (-not $c) { return $false }
    if ($c -match 'autodesk|adsk|flexnet') { return $true }
    return (($c -match '^\s*(0\.0\.0\.0|127\.0\.0\.1|::1)\s') -and
            ($c -match 'time\.windows\.com|time\.nist\.gov|pool\.ntp\.org|time\.autodesk\.com|w32time'))
}

# ---------------------------------------------------------------------------
$isAdmin = Test-IsAdmin
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   Autodesk Licensing Doctor  -  Phase 3: Cleanup' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("   Mode    : {0}" -f $(if ($Apply) { 'APPLY (will make changes)' } else { 'PREVIEW (nothing changes)' })) -ForegroundColor $(if ($Apply) {'Yellow'} else {'Green'})
Write-Host ("   Admin   : {0}" -f $isAdmin)

if ($Apply -and -not $isAdmin) {
    Write-Host '   ERROR: -Apply requires an administrator shell.' -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Backup gate
# ---------------------------------------------------------------------------
if ($Apply -and -not $SkipBackup) {
    Write-Host ''
    Write-Host 'Running mandatory backup (Phase 2)...' -ForegroundColor Cyan
    $backupScript = Join-Path $PSScriptRoot 'Backup.ps1'
    if (-not (Test-Path -LiteralPath $backupScript)) {
        Write-Host '   ERROR: Backup.ps1 not found. Aborting (or use -SkipBackup).' -ForegroundColor Red
        exit 1
    }
    $bargs = @('-ExecutionPolicy','Bypass','-File',$backupScript)
    if ($BackupRoot) { $bargs += @('-BackupRoot', $BackupRoot) }
    & powershell -NoProfile @bargs
    if ($LASTEXITCODE -ne 0) {
        Write-Host '   ERROR: backup failed. Aborting cleanup.' -ForegroundColor Red
        exit 1
    }
    Write-Host '   Backup OK. Continuing.' -ForegroundColor Green
} elseif ($Apply) {
    Write-Host '   WARNING: running with -SkipBackup. No fresh safety net!' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 1. Stop Autodesk processes
# ---------------------------------------------------------------------------
Section 'Stop Autodesk processes'
# The pattern below also matches OUR OWN executable (UNLOCK-DIGITAL-AdskDoctor),
# so the toolkit's own process tree is always excluded - stopping it would close
# the GUI (or console) that launched this cleanup. Both the parent process and
# the name are checked, so a renamed copy is still safe.
$procNames = 'acad|revit|3dsmax|maya|civil3d|autocad|adsk|autodesk|lmgrd|adskflex|LMTOOLS'
$selfIds = @([int]$PID)
try {
    $me = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $PID) -ErrorAction Stop
    if ($me -and $me.ParentProcessId) { $selfIds += [int]$me.ParentProcessId }
} catch { }
$procs = @(Get-Process | Where-Object {
    $_.ProcessName -match $procNames -and
    $selfIds -notcontains $_.Id -and
    $_.ProcessName -notmatch 'AdskDoctor'
})
if ($procs.Count -eq 0) {
    Write-Host '  none running' -ForegroundColor DarkGray
} else {
    foreach ($p in $procs) { Step ("Stop process {0} (PID {1})" -f $p.ProcessName, $p.Id) { Stop-Process -Id $p.Id -Force } }
}

# ---------------------------------------------------------------------------
# 2. Stop Autodesk / FlexNet services
# ---------------------------------------------------------------------------
Section 'Stop Autodesk / FlexNet services'
$script:svcStopped = @()
$script:svcDeleted = @()
$svcs = @(Get-Service | Where-Object {
    $_.Name -notmatch 'AdskDoctor' -and
    ($_.Name -match 'adsk|autodesk' -or
     (($_.Name -match 'flexnet|flexlm') -and (Test-CrackFlexService $_.Name))) })
foreach ($s in $svcs) {
    if ($s.Status -eq 'Running') {
        $sn = $s.Name
        Step ("Stop service {0}" -f $sn) { Stop-Service -Name $sn -Force; $script:svcStopped += $sn }
    }
}
if ($svcs.Count -eq 0) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 3. Hosts file hijacks
# ---------------------------------------------------------------------------
Section 'Hosts file'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsLines = Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue
$bad = @($hostsLines | Where-Object { Test-BadHostsLine $_ })
if ($bad.Count -eq 0) {
    Write-Host '  clean' -ForegroundColor DarkGray
} else {
    Step ("Remove {0} hijacked line(s) from hosts (Autodesk + time servers)" -f $bad.Count) {
        # The hosts file is watched in real time (antivirus, restore-point and
        # other snapshots, licensing components) and brief exclusive locks are
        # normal on real machines. Write a sibling file, swap it in atomically
        # and retry for ~15 s. The original is never truncated in place, so a
        # transient lock cannot leave it empty or half-written.
        $lastErr = ''
        $ok = $false
        for ($attempt = 1; $attempt -le 12 -and -not $ok; $attempt++) {
            $tmpHosts = "$hostsPath.new"
            try {
                $fresh = @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop)
                $badNow = @($fresh | Where-Object { Test-BadHostsLine $_ })
                if ($badNow.Count -eq 0) {
                    $ok = $true
                } else {
                    $keepNow = @($fresh | Where-Object { -not (Test-BadHostsLine $_) })
                    Set-ItemProperty -LiteralPath $hostsPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
                    Set-Content -LiteralPath $tmpHosts -Value $keepNow -Encoding ASCII -ErrorAction Stop
                    try {
                        [System.IO.File]::Replace($tmpHosts, $hostsPath, $null)
                    } catch {
                        Remove-Item -LiteralPath $hostsPath -Force -ErrorAction Stop
                        Move-Item -LiteralPath $tmpHosts -Destination $hostsPath -Force -ErrorAction Stop
                    }
                    $stillBad = @(Get-Content -LiteralPath $hostsPath -ErrorAction Stop | Where-Object { Test-BadHostsLine $_ }).Count
                    $ok = ($stillBad -eq 0)
                }
            } catch {
                $lastErr = $_.Exception.Message
            } finally {
                if (Test-Path -LiteralPath $tmpHosts) { Remove-Item -LiteralPath $tmpHosts -Force -ErrorAction SilentlyContinue }
            }
            if (-not $ok) { Start-Sleep -Milliseconds (200 + 220 * $attempt) }
        }
        if (-not $ok) { throw ("the hosts file stayed locked and could not be cleaned - pause the antivirus and re-run (last error: {0})" -f $lastErr) }
    }
}

# ---------------------------------------------------------------------------
# 4. Firewall rules
# ---------------------------------------------------------------------------
Section 'Firewall rules'
try {
    $fw = @(Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'autodesk|adsk|flexnet|acad|revit' })
    if ($fw.Count -eq 0) { Write-Host '  none' -ForegroundColor DarkGray }
    foreach ($r in $fw) { $rn = $r.Name; Step ("Remove firewall rule '{0}'" -f $r.DisplayName) { Remove-NetFirewallRule -Name $rn } }
} catch { Write-Host ('  (firewall query failed: ' + $_.Exception.Message + ')') -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 5. Scheduled tasks dropped by cracks (suspicious paths only)
# ---------------------------------------------------------------------------
Section 'Scheduled tasks'
try {
    $tasks = @(Get-ScheduledTask | Where-Object { $_.TaskName -match 'autodesk|adsk|flexnet' })
    foreach ($t in $tasks) {
        $exe = $null
        foreach ($a in $t.Actions) { if ($a.Execute) { $exe = $a.Execute; break } }
        $susp = Test-SuspiciousExecPath $exe
        if ($susp) {
            $tn = $t.TaskName; $tp = $t.TaskPath
            Step ("Unregister suspicious task {0}{1} ({2})" -f $tp, $tn, $exe) { Unregister-ScheduledTask -TaskName $tn -TaskPath $tp -Confirm:$false }
        }
    }
    if (-not $tasks) { Write-Host '  none' -ForegroundColor DarkGray }
} catch {}

# ---------------------------------------------------------------------------
# 6. Startup entries (Run / RunOnce) dropped by cracks
# ---------------------------------------------------------------------------
Section 'Startup entries'
$runKeys = @(
    'Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'Registry::HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'Registry::HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
    'Registry::HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'Registry::HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
$startupFound = $false
foreach ($rk in $runKeys) {
    if (-not (Test-Path -LiteralPath $rk)) { continue }
    $item = Get-Item -LiteralPath $rk
    foreach ($vn in @($item.GetValueNames())) {
        if (-not $vn) { continue }
        $val = [string]$item.GetValue($vn)
        if ($vn -notmatch 'autodesk|adsk|flexnet|flexlm|acad|revit|licgen|xforce|xf-' -and
            $val -notmatch 'autodesk|adsk|flexnet|flexlm|acad|revit|licgen|xforce|xf-') { continue }
        $startupFound = $true
        # A genuine entry starts a Program Files binary that is still intact.
        # Anything else is a leftover: an activator in a user/temp folder, a
        # patched binary, or a dead path.
        $exe = Get-ExeFromCommandLine $val
        $keep = $false
        if ($exe -and (Test-Path -LiteralPath $exe) -and -not (Test-SuspiciousExecPath $val)) {
            $keep = Test-KeepStartupTarget $exe
        }
        if ($keep) {
            Write-Host ("  note: startup entry looks genuine (left alone): {0} = {1}" -f $vn, $val) -ForegroundColor DarkGray
        } else {
            $rkn = $vn; $rkp = $rk
            Step ("Remove startup entry {0} ({1} = {2})" -f $rk.Replace('Registry::',''), $vn, $val) { Remove-ItemProperty -LiteralPath $rkp -Name $rkn -Force }
        }
    }
}
if (-not $startupFound) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 7. Defender exclusions that hide patched files
# ---------------------------------------------------------------------------
Section 'Defender exclusions'
try {
    $mp = Get-MpPreference -ErrorAction Stop
    $exPaths = @(@($mp.ExclusionPath)    | Where-Object { $_ })
    $exProcs = @(@($mp.ExclusionProcess) | Where-Object { $_ })
    $crackPaths = @($exPaths | Where-Object { $_ -match 'flexlm|adskflex|lmgrd|licgen|xforce|xf-|crack|keygen|\\temp\\|\\downloads\\|\\appdata\\' })
    $adskPaths  = @($exPaths | Where-Object { $_ -match 'autodesk|adsk' -and $_ -notmatch 'flexlm|adskflex|lmgrd|licgen|xforce|xf-|crack|keygen|\\temp\\|\\downloads\\|\\appdata\\' })
    $crackProcs = @($exProcs | Where-Object { $_ -match 'flexlm|adskflex|lmgrd|licgen|xforce|xf-|crack|keygen' })
    if (($crackPaths.Count + $adskPaths.Count + $crackProcs.Count) -eq 0) {
        Write-Host '  none' -ForegroundColor DarkGray
    }
    foreach ($p in $crackPaths) { $pp = $p; Step ("Remove Defender exclusion (crack-related): {0}" -f $pp) { Remove-MpPreference -ExclusionPath $pp } }
    foreach ($p in $adskPaths)  { $pp = $p; Step ("Remove Defender exclusion (hides patched files): {0}" -f $pp) { Remove-MpPreference -ExclusionPath $pp } }
    foreach ($p in $crackProcs) { $pp = $p; Step ("Remove Defender process exclusion: {0}" -f $pp) { Remove-MpPreference -ExclusionProcess $pp } }
    if (($crackPaths.Count + $adskPaths.Count + $crackProcs.Count) -gt 0) {
        Write-Host '  (removed exclusions are re-scanned; UNDO.ps1 adds them back)' -ForegroundColor DarkGray
    }
} catch { Write-Host ('  (Defender query failed: ' + $_.Exception.Message + ')') -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 8. Crack leftovers / fake license server
# ---------------------------------------------------------------------------
Section 'Crack leftovers'
$leftovers = @()
foreach ($p in @(
    (Join-Path $env:ProgramData 'FLEXnet'),
    (Join-Path $env:ProgramData 'Autodesk\Web Services\Adlm'),
    # The legacy ADLM licence cache (ProductInformation.pit). ADLS ignores it,
    # a patched copy is a classic non-genuine activation leftover, and the
    # backup layer restores it if the clean-up is rolled back.
    (Join-Path $env:ProgramData 'Autodesk\Adlm'))) {
    if (Test-Path -LiteralPath $p) { $leftovers += $p }
}
foreach ($p in $leftovers) { $pp = $p; Step ("Remove leftover folder {0}" -f $p) { Remove-Item -LiteralPath $pp -Recurse -Force } }

$suspName = 'crack|keygen|licgen|xforce|xf-|adskflex|lmgrd|_orig|patched|licpath|\.bak$'
$commonFiles = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared'
foreach ($root in @($commonFiles, (Join-Path $env:ProgramFiles 'Autodesk'))) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $hits = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $suspName } | Select-Object -First 50)
    foreach ($h in $hits) { $hp = $h.FullName; Step ("Remove crack file {0}" -f $h.Name) { Remove-Item -LiteralPath $hp -Force } }
}
if ($leftovers.Count -eq 0) { Write-Host '  no leftover folders' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 9. Network License Manager (blocks 2026 products)
# ---------------------------------------------------------------------------
Section 'Network License Manager (NLM)'
if ($KeepNLM) {
    Write-Host '  skipped (-KeepNLM)' -ForegroundColor Yellow
} else {
    $nlmPaths = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared\Network License Manager'),
        (Join-Path $env:ProgramFiles 'Common Files\Autodesk Shared\Network License Manager'),
        'C:\Autodesk\Network License Manager',
        # the classic crack drop for a fake FLEXlm server (backed up first)
        'C:\FlexLM',
        (Join-Path $env:ProgramFiles 'Autodesk\Network License Manager'),
        (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\Network License Manager')
    )
    $nlmFound = $false
    foreach ($np in $nlmPaths) {
        if (Test-Path -LiteralPath $np) {
            $nlmFound = $true
            $npp = $np
            Step ("Remove old NLM folder {0}" -f $np) { Remove-Item -LiteralPath $npp -Recurse -Force }
        }
    }
    # FlexNet / NLM services. The Autodesk Network License Manager service is
    # called AdskNLM and its display name does not contain "Network License
    # Manager", so it survived an earlier cleanup as a service pointing at
    # deleted binaries (seen on a customer machine). A flexnet/flexlm-named
    # service is removed only when it is dead or suspicious: the genuine
    # Flexera service is infrastructure other software may need.
    foreach ($s in @(Get-Service | Where-Object {
            $_.Name -match 'adsknlm' -or
            $_.DisplayName -match 'Network License Manager|AdskNLM' -or
            (($_.Name -match 'flexnet|flexlm') -and (Test-CrackFlexService $_.Name)) })) {
        $sn = $s.Name
        Step ("Remove NLM/FlexNet service {0}" -f $sn) {
            Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue
            & sc.exe delete $sn | Out-Null
            $script:svcDeleted += $sn
        }
        $nlmFound = $true
    }
    if (-not $nlmFound) { Write-Host '  none' -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------------------
# 10. Registry: cracked license-server keys
# ---------------------------------------------------------------------------
Section 'Registry artifacts'
$regKeys = @(
    'Registry::HKLM\SOFTWARE\FLEXlm License Manager',
    'Registry::HKLM\SOFTWARE\WOW6432Node\FLEXlm License Manager'
)
$found = $false
foreach ($k in $regKeys) {
    if (Test-Path -LiteralPath $k) {
        $found = $true; $kk = $k
        Step ("Remove registry key {0}" -f $k.Replace('Registry::','')) { Remove-Item -LiteralPath $kk -Recurse -Force }
    }
}
if (-not $found) { Write-Host '  no cracked license-server keys' -ForegroundColor DarkGray }

# execution blockers: a "Debugger" value squeezed onto Autodesk processes/services,
# which stops ADLS / the Genuine Service / the product from ever starting.
$ifeoRoots = @(
    'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',
    'Registry::HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
)
$ifeoFound = $false
foreach ($ir in $ifeoRoots) {
    if (-not (Test-Path -LiteralPath $ir)) { continue }
    foreach ($k in @(Get-ChildItem -LiteralPath $ir -ErrorAction SilentlyContinue)) {
        $dbg = $null
        try { $dbg = [string](Get-ItemProperty -LiteralPath $k.PSPath -Name 'Debugger' -ErrorAction Stop).Debugger } catch {}
        if (-not $dbg) { continue }
        $name = $k.PSChildName
        if ($name -match 'adsk|autodesk|genuine|flexnet|flexlm|licens') {
            $ifeoFound = $true; $kp = $k.PSPath
            Step ("Remove execution blocker IFEO\{0} -> {1}" -f $name, $dbg) { Remove-Item -LiteralPath $kp -Recurse -Force }
        } elseif ($dbg -match '\\appdata\\|\\temp\\|\\users\\|\\downloads\\') {
            # someone else's hook - report it, never touch it
            Write-Host ("  note: unrelated execution hook IFEO\{0} -> {1} (left alone)" -f $name, $dbg) -ForegroundColor DarkGray
        }
    }
}
if (-not $ifeoFound) { Write-Host '  no Autodesk execution blockers' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 11. Autodesk installer cache (ODIS)
# ---------------------------------------------------------------------------
Section 'Installer cache (ODIS)'
$script:odisLocked = $false
foreach ($odis in @(
    (Join-Path $env:ProgramData 'Autodesk\ODIS'),
    (Join-Path $env:LOCALAPPDATA 'Autodesk\ODIS'))) {
    if (Test-Path -LiteralPath $odis) {
        $oo = $odis
        Step ("Clear installer cache {0}" -f $odis) {
            # the cache database can still be locked while an Autodesk process
            # is shutting down: clear everything that is free and leave the
            # rest to the reboot instead of throwing raw Remove-Item errors
            # (seen in the lab run)
            Get-ChildItem -LiteralPath $oo -Recurse -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath $oo -Recurse -Directory -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $oo -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $oo) { $script:odisLocked = $true }
        }
    }
}
if ($script:odisLocked) { Write-Host '  note: some cache files are locked by a running Autodesk process - they clear after reboot' -ForegroundColor DarkGray }
Write-Host '  (cleared caches are regenerated automatically)' -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 12. Suspicious environment variables
# ---------------------------------------------------------------------------
Section 'Environment variables'
$hv = @()
foreach ($scope in @('Machine','User')) {
    $vars = [Environment]::GetEnvironmentVariables($scope)
    foreach ($k in $vars.Keys) {
        if ($k -match 'ADSK|AUTODESK|FLEXLM|LICPATH') { $hv += [pscustomobject]@{ Scope=$scope; Name=$k } }
    }
}
foreach ($v in $hv) { $vn = $v.Name; $vs = $v.Scope; Step ("Remove env var {0}:{1}" -f $vs, $vn) { [Environment]::SetEnvironmentVariable($vn, $null, $vs) } }
if ($hv.Count -eq 0) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 13. System clock (fixes "Clock Error")
# ---------------------------------------------------------------------------
Section 'System clock'
Step 'Enable + start Windows Time service (w32time)' {
    Set-Service -Name w32time -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name w32time -ErrorAction SilentlyContinue
}
Step 'Resync system clock with internet time' { & w32tm /resync /force *> $null }

# ---------------------------------------------------------------------------
# 14. Put back the services that were only stopped
# ---------------------------------------------------------------------------
Section 'Restart services that were only stopped'
$script:restarted = 0
foreach ($sn in $script:svcStopped) {
    if ($script:svcDeleted -contains $sn) { continue }
    $sv = Get-Service -Name $sn -ErrorAction SilentlyContinue
    if (-not $sv -or $sv.StartType -eq 'Disabled') { continue }
    Step ("Start service {0}" -f $sn) { Start-Service -Name $sn; $script:restarted += 1 }
}
if ($script:restarted -eq 0) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
if ($Apply) {
    Write-Host ("   Applied changes : {0}" -f $script:Changes) -ForegroundColor Green
    Write-Host ("   Failures        : {0}" -f $script:Errors)  -ForegroundColor $(if ($script:Errors) {'Red'} else {'Green'})
    Write-Host ''
    Write-Host '   Next: run Repair.ps1 to reinstall/verify the official licensing components.' -ForegroundColor Cyan
} else {
    Write-Host '   PREVIEW only - nothing was changed.' -ForegroundColor Green
    Write-Host '   Run again with  -Apply  to make the changes (a backup runs first).' -ForegroundColor Yellow
}
Write-Host ''
