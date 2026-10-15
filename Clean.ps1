<#
    Clean.ps1  -  Phase 3: SAFE CLEANUP (preview by default)
    ---------------------------------------------------------------------------
    Removes the leftovers that break Autodesk official licensing, based on the
    exact causes seen in the field:
      - old Network License Manager (adskflex/lmgrd)  -> blocks Revit/AutoCAD 2026+
      - FLEXlm license-server leftovers
      - hosts hijacks + firewall blocks
      - crack-scheduled tasks & startup entries
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
$svcs = @(Get-Service | Where-Object { $_.Name -match 'adsk|autodesk|flexnet|flexlm' -and $_.Name -notmatch 'AdskDoctor' })
foreach ($s in $svcs) {
    if ($s.Status -eq 'Running') { Step ("Stop service {0}" -f $s.Name) { Stop-Service -Name $s.Name -Force } }
}

# ---------------------------------------------------------------------------
# 3. Hosts file hijacks
# ---------------------------------------------------------------------------
Section 'Hosts file'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsLines = Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue
$bad = @($hostsLines | Where-Object { ($_ -split '#')[0].Trim() -match 'autodesk|adsk|flexnet' })
if ($bad.Count -eq 0) {
    Write-Host '  clean' -ForegroundColor DarkGray
} else {
    Step ("Remove {0} Autodesk line(s) from hosts" -f $bad.Count) {
        $keep = @($hostsLines | Where-Object { -not (($_ -split '#')[0].Trim() -match 'autodesk|adsk|flexnet') })
        Set-Content -LiteralPath $hostsPath -Value $keep -Encoding ASCII
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
        $susp = ($exe -and $exe -match '\\appdata\\|\\temp\\|\\users\\|\\programdata\\|\\downloads\\')
        if ($susp) {
            $tn = $t.TaskName; $tp = $t.TaskPath
            Step ("Unregister suspicious task {0}{1} ({2})" -f $tp, $tn, $exe) { Unregister-ScheduledTask -TaskName $tn -TaskPath $tp -Confirm:$false }
        }
    }
    if (-not $tasks) { Write-Host '  none' -ForegroundColor DarkGray }
} catch {}

# ---------------------------------------------------------------------------
# 6. Crack leftovers / fake license server
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

$suspName = 'crack|keygen|licgen|xforce|xf-|adskflex|lmgrd|_orig|\.bak$'
$commonFiles = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared'
foreach ($root in @($commonFiles, (Join-Path $env:ProgramFiles 'Autodesk'))) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $hits = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $suspName } | Select-Object -First 50)
    foreach ($h in $hits) { $hp = $h.FullName; Step ("Remove crack file {0}" -f $h.Name) { Remove-Item -LiteralPath $hp -Force } }
}
if ($leftovers.Count -eq 0) { Write-Host '  no leftover folders' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 7. Network License Manager (blocks 2026 products)
# ---------------------------------------------------------------------------
Section 'Network License Manager (NLM)'
if ($KeepNLM) {
    Write-Host '  skipped (-KeepNLM)' -ForegroundColor Yellow
} else {
    $nlmPaths = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared\Network License Manager'),
        (Join-Path $env:ProgramFiles 'Common Files\Autodesk Shared\Network License Manager'),
        'C:\Autodesk\Network License Manager',
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
    # deleted binaries (seen on a customer machine).
    foreach ($s in @(Get-Service | Where-Object {
            $_.Name -match 'flexnet|flexlm|adsknlm' -or
            $_.DisplayName -match 'Network License Manager|AdskNLM' })) {
        $sn = $s.Name
        Step ("Remove NLM/FlexNet service {0}" -f $sn) {
            Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue
            & sc.exe delete $sn | Out-Null
        }
        $nlmFound = $true
    }
    if (-not $nlmFound) { Write-Host '  none' -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------------------
# 8. Registry: cracked license-server keys
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
# 9. Autodesk installer cache (ODIS)
# ---------------------------------------------------------------------------
Section 'Installer cache (ODIS)'
foreach ($odis in @(
    (Join-Path $env:ProgramData 'Autodesk\ODIS'),
    (Join-Path $env:LOCALAPPDATA 'Autodesk\ODIS'))) {
    if (Test-Path -LiteralPath $odis) {
        $oo = $odis
        Step ("Clear installer cache {0}" -f $odis) { Remove-Item -LiteralPath $oo -Recurse -Force }
    }
}
Write-Host '  (cleared caches are regenerated automatically)' -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 10. Suspicious environment variables
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
# 11. System clock (fixes "Clock Error")
# ---------------------------------------------------------------------------
Section 'System clock'
Step 'Enable + start Windows Time service (w32time)' {
    Set-Service -Name w32time -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name w32time -ErrorAction SilentlyContinue
}
Step 'Resync system clock with internet time' { & w32tm /resync /force *> $null }

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
