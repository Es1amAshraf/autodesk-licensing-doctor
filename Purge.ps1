<#
    Purge.ps1  -  Phase 5: FULL AUTODESK REMOVAL (preview by default)
    ---------------------------------------------------------------------------
    The "start from zero" option. Clean.ps1 repairs the licensing leftovers and
    keeps the genuine parts; Purge takes out EVERYTHING Autodesk:

      - official products are uninstalled first (ODIS manifests + MSI entries)
      - processes, services, scheduled tasks, startup entries (Run / RunOnce)
      - hosts hijacks, firewall rules, Defender exclusions, IFEO blockers
      - crack leftovers (FLEXlm keys, patched files, a fake license server)
      - every Autodesk folder (Program Files / ProgramData / installer caches /
        user profiles) and registry key, incl. broken Add-Remove entries
      - environment variables
      - a verification pass reports anything that survived (locked files
        normally clear after a reboot)

    SAFETY:
      - Default is PREVIEW (changes nothing). Add -Apply to actually run.
      - With -Apply, the full layered backup (Phase 2) runs FIRST and aborts
        the purge if the backup fails.
      - The backup is for reference / registry restore; the products themselves
        have to be re-installed fresh afterwards, so there is no UNDO for them.

    Usage:
      .\Purge.ps1                       # preview
      .\Purge.ps1 -Apply                # backup + full removal
      .\Purge.ps1 -Apply -SkipBackup    # (not recommended)
      .\Purge.ps1 -Apply -BackupRoot "D:\AdskBackups"
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$SkipBackup,
    [string]$BackupRoot
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$script:Changes   = 0
$script:Errors    = 0
$script:BackupDir = $null

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
    if ($CommandLine -match '^\s*(.+?\.exe)\b')   { return $matches[1].Trim('"') }
    return $null
}

# Flexera's own licensing service (FNPLicensingService64) is infrastructure
# other software uses, so a flexnet/flexlm-named service is only removed when
# its binary is gone or lives in a suspicious place (same rule as Clean.ps1).
function Test-CrackFlexService {
    param([string]$Name)
    $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    $bin = Get-ExeFromCommandLine $svc.PathName
    if (-not $bin) { return $true }
    $p = $bin.ToLowerInvariant()
    return ($p -match '\\appdata\\|\\temp\\|\\users\\|\\programdata\\|\\downloads\\|flexlm|adskflex|lmgrd|lmutil|lmadmin|keygen|xf-adsk|xforce|crack|licgen') -or
           (-not (Test-Path -LiteralPath $bin))
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

# Registry:: provider path -> plain HKLM/HKCU path (for reg.exe export)
function Get-RegPath { param([string]$P) ($P -replace '^.*Registry::','') }

# Product names that mean "this Add-Remove entry belongs to Autodesk"
$productPattern = 'autodesk|adsk|autocad|revit|inventor|navisworks|3ds ?max|maya|civil ?3d|advance steel|robot structural|infraworks|recap|desktop connector|featured apps|app manager|identity manager|save to web|genuine service|adlm|odis'

$pf86 = ${env:ProgramFiles(x86)}
if (-not $pf86) { $pf86 = $env:ProgramFiles }

# ---------------------------------------------------------------------------
$isAdmin = Test-IsAdmin
Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   Autodesk Licensing Doctor  -  Phase 5: Full removal' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ("   Mode    : {0}" -f $(if ($Apply) { 'APPLY (will remove everything Autodesk)' } else { 'PREVIEW (nothing changes)' })) -ForegroundColor $(if ($Apply) {'Yellow'} else {'Green'})
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
        Write-Host '   ERROR: backup failed. Aborting purge.' -ForegroundColor Red
        exit 1
    }
    $bkRoot = if ($BackupRoot) { $BackupRoot } else { Join-Path $PSScriptRoot 'backups' }
    $bk = @(Get-ChildItem -LiteralPath $bkRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($bk.Count -gt 0) { $script:BackupDir = $bk[0].FullName }
    Write-Host '   Backup OK. Continuing.' -ForegroundColor Green
} elseif ($Apply) {
    Write-Host '   WARNING: running with -SkipBackup. No fresh safety net!' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 1. Stop Autodesk processes
# ---------------------------------------------------------------------------
Section 'Stop Autodesk processes'
# The pattern below also matches OUR OWN executable (UNLOCK-DIGITAL-AdskDoctor),
# so the toolkit's own process tree is always excluded - stopping it would
# close the GUI that launched this purge. Both the parent process and the name
# are checked, so a renamed copy is still safe.
$procNames = 'acad|revit|3dsmax|maya|civil3d|autocad|adsk|autodesk|genuine|lmgrd|adskflex|lmtools|adsso|adappmgr|aceventsync|acqmod|odis'
$selfIds = @([int]$PID)
try {
    $me = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $PID) -ErrorAction Stop
    if ($me -and $me.ParentProcessId) { $selfIds += [int]$me.ParentProcessId }
} catch { }
$procs = @(Get-Process | Where-Object {
    $_.ProcessName -match $procNames -and
    $selfIds -notcontains $_.Id -and
    $_.ProcessName -notmatch 'AdskDoctor|UNLOCK'
})
if ($procs.Count -eq 0) {
    Write-Host '  none running' -ForegroundColor DarkGray
} else {
    foreach ($p in $procs) { Step ("Stop process {0} (PID {1})" -f $p.ProcessName, $p.Id) { Stop-Process -Id $p.Id -Force } }
}

# ---------------------------------------------------------------------------
# 2. Uninstall official products (best effort)
# ---------------------------------------------------------------------------
Section 'Uninstall official products (best effort)'
# ODIS-managed products first: the official uninstaller removes the product
# and its components the supported way. Anything it cannot reach is removed by
# the sweep below, so failures here are logged, never fatal.
$odisInstaller = Join-Path $env:ProgramFiles 'Autodesk\AdODIS\V1\Installer.exe'
$odisMeta      = Join-Path $env:ProgramData 'Autodesk\ODIS\metadata'
if ((Test-Path -LiteralPath $odisInstaller) -and (Test-Path -LiteralPath $odisMeta)) {
    $manifests = @(Get-ChildItem -LiteralPath $odisMeta -Recurse -Filter 'bundleManifest.xml' -File -ErrorAction SilentlyContinue)
    if ($manifests.Count -eq 0) { Write-Host '  no product manifests found' -ForegroundColor DarkGray }
    foreach ($m in $manifests) {
        $mf = $m.FullName
        $label = Split-Path -Leaf (Split-Path -Parent $mf)
        Step ("Uninstall product {0} (ODIS)" -f $label) {
            $argLine = '-i uninstall -q -m "{0}"' -f $mf
            $p = Start-Process -FilePath $odisInstaller -ArgumentList $argLine -WindowStyle Hidden -PassThru
            if (-not $p.WaitForExit(900000)) { try { $p.Kill() } catch { } ; throw 'uninstaller did not finish within 15 minutes' }
            if ($p.ExitCode -ne 0) { throw ("uninstaller exit code {0}" -f $p.ExitCode) }
        }
    }
} else {
    Write-Host '  (no ODIS installer or metadata here - the sweep below removes the leftovers)' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# 3. Uninstall MSI products (best effort)
# ---------------------------------------------------------------------------
Section 'Uninstall MSI products (best effort)'
$uninstallRoots = @(
    'Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'Registry::HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
    'Registry::HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)
$msiFound = $false
foreach ($ur in $uninstallRoots) {
    if (-not (Test-Path -LiteralPath $ur)) { continue }
    foreach ($k in @(Get-ChildItem -LiteralPath $ur -ErrorAction SilentlyContinue)) {
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { continue }
        $dn  = [string]$props.DisplayName
        $pub = [string]$props.Publisher
        if (($dn -notmatch $productPattern) -and ($pub -notmatch 'autodesk')) { continue }
        if ($k.PSChildName -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { continue }
        if ($props.SystemComponent -eq 1) { continue }
        $msiFound = $true
        $code = $k.PSChildName
        Step ("Uninstall {0} (MSI {1})" -f $dn, $code) {
            $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList ('/x {0} /qn /norestart' -f $code) -PassThru
            if (-not $p.WaitForExit(900000)) { try { $p.Kill() } catch { } ; throw 'msiexec did not finish within 15 minutes' }
            if ($p.ExitCode -notin @(0,1605,1614,3010,1641)) { throw ("msiexec exit code {0}" -f $p.ExitCode) }
        }
    }
}
if (-not $msiFound) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 4. Autodesk services
# ---------------------------------------------------------------------------
Section 'Autodesk services'
$svcs = @(Get-Service | Where-Object {
    $_.Name -notmatch 'AdskDoctor' -and (
        $_.Name -match 'adsk|autodesk|genuine' -or
        $_.DisplayName -match 'adsk|autodesk|genuine' -or
        (($_.Name -match 'flexnet|flexlm') -and (Test-CrackFlexService $_.Name))) })
if ($svcs.Count -eq 0) { Write-Host '  none' -ForegroundColor DarkGray }
foreach ($s in $svcs) {
    $sn = $s.Name
    Step ("Remove service {0}" -f $sn) {
        Stop-Service -Name $sn -Force -ErrorAction SilentlyContinue
        & sc.exe delete $sn | Out-Null
    }
}

# ---------------------------------------------------------------------------
# 5. Scheduled tasks
# ---------------------------------------------------------------------------
Section 'Scheduled tasks'
try {
    $taskFound = $false
    foreach ($t in @(Get-ScheduledTask | Where-Object { $_.TaskName -match 'autodesk|adsk|genuine|flexnet' })) {
        $tn = $t.TaskName; $tp = $t.TaskPath
        $taskFound = $true
        Step ("Unregister task {0}{1}" -f $tp, $tn) { Unregister-ScheduledTask -TaskName $tn -TaskPath $tp -Confirm:$false }
    }
    # tasks whose name is random but whose action points at Autodesk / crack tools
    foreach ($t in @(Get-ScheduledTask | Where-Object { $_.TaskName -notmatch 'autodesk|adsk|genuine|flexnet' })) {
        $exe = $null
        foreach ($a in $t.Actions) { if ($a.Execute) { $exe = $a.Execute; break } }
        if (-not $exe) { continue }
        $hit = ($exe -match 'autodesk|adsk|flexlm|adskflex|lmgrd|licgen|xforce|xf-|genuine') -or
               (($exe -match 'acad|revit') -and ($exe -match '\\users\\|\\appdata\\|\\temp\\|\\downloads\\|\\programdata\\'))
        if ($hit) {
            $tn = $t.TaskName; $tp = $t.TaskPath; $exe2 = $exe
            $taskFound = $true
            Step ("Unregister task {0}{1} ({2})" -f $tp, $tn, $exe2) { Unregister-ScheduledTask -TaskName $tn -TaskPath $tp -Confirm:$false }
        }
    }
    if (-not $taskFound) { Write-Host '  none' -ForegroundColor DarkGray }
} catch {}

# ---------------------------------------------------------------------------
# 6. Startup entries (Run / RunOnce)
# ---------------------------------------------------------------------------
Section 'Startup entries'
# For the full removal even genuine Autodesk entries go: no part of Autodesk
# should come back by itself before the fresh installation.
$runKeys = @(
    'Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'Registry::HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'Registry::HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
    'Registry::HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'Registry::HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
$startupPattern = 'autodesk|adsk|flexnet|flexlm|adskflex|acad|revit|licgen|xforce|xf-|genuine'
$startupFound = $false
foreach ($rk in $runKeys) {
    if (-not (Test-Path -LiteralPath $rk)) { continue }
    $item = Get-Item -LiteralPath $rk
    foreach ($vn in @($item.GetValueNames())) {
        if (-not $vn) { continue }
        $val = [string]$item.GetValue($vn)
        if (($vn -notmatch $startupPattern) -and ($val -notmatch $startupPattern)) { continue }
        $startupFound = $true
        $rkn = $vn; $rkp = $rk
        Step ("Remove startup entry {0} ({1} = {2})" -f $rk.Replace('Registry::',''), $vn, $val) { Remove-ItemProperty -LiteralPath $rkp -Name $rkn -Force }
    }
}
if (-not $startupFound) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 7. Hosts file hijacks
# ---------------------------------------------------------------------------
Section 'Hosts file'
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$hostsLines = Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue
$bad = @($hostsLines | Where-Object { Test-BadHostsLine $_ })
if ($bad.Count -eq 0) {
    Write-Host '  clean' -ForegroundColor DarkGray
} else {
    Step ("Remove {0} hijacked line(s) from hosts (Autodesk + time servers)" -f $bad.Count) {
        $keep = @($hostsLines | Where-Object { -not (Test-BadHostsLine $_) })
        # The hosts file is scanned in real time by antivirus - retry, then verify.
        $ok = $false
        for ($attempt = 1; $attempt -le 3 -and -not $ok; $attempt++) {
            try {
                Set-Content -LiteralPath $hostsPath -Value $keep -Encoding ASCII -ErrorAction Stop
                $stillBad = @(Get-Content -LiteralPath $hostsPath -ErrorAction SilentlyContinue | Where-Object { Test-BadHostsLine $_ }).Count
                $ok = ($stillBad -eq 0)
            } catch { Start-Sleep -Milliseconds 500 }
        }
        if (-not $ok) { throw 'the hosts file stayed locked and could not be cleaned - pause the antivirus and re-run' }
    }
}

# ---------------------------------------------------------------------------
# 8. Firewall rules
# ---------------------------------------------------------------------------
Section 'Firewall rules'
try {
    $fw = @(Get-NetFirewallRule | Where-Object { $_.DisplayName -match 'autodesk|adsk|flexnet|flexlm|acad|revit|genuine' })
    if ($fw.Count -eq 0) { Write-Host '  none' -ForegroundColor DarkGray }
    foreach ($r in $fw) { $rn = $r.Name; Step ("Remove firewall rule '{0}'" -f $r.DisplayName) { Remove-NetFirewallRule -Name $rn } }
} catch { Write-Host ('  (firewall query failed: ' + $_.Exception.Message + ')') -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 9. Defender exclusions
# ---------------------------------------------------------------------------
Section 'Defender exclusions'
try {
    $mp = Get-MpPreference -ErrorAction Stop
    $exPaths = @(@($mp.ExclusionPath)    | Where-Object { $_ })
    $exProcs = @(@($mp.ExclusionProcess) | Where-Object { $_ })
    $delPaths = @($exPaths | Where-Object { $_ -match 'flexlm|adskflex|lmgrd|licgen|xforce|xf-|crack|keygen|autodesk|adsk|acad|revit' })
    $delProcs = @($exProcs | Where-Object { $_ -match 'flexlm|adskflex|lmgrd|licgen|xforce|xf-|crack|keygen|autodesk|adsk|acad|revit' })
    if (($delPaths.Count + $delProcs.Count) -eq 0) { Write-Host '  none' -ForegroundColor DarkGray }
    foreach ($p in $delPaths) { $pp = $p; Step ("Remove Defender exclusion: {0}" -f $pp) { Remove-MpPreference -ExclusionPath $pp } }
    foreach ($p in $delProcs) { $pp = $p; Step ("Remove Defender process exclusion: {0}" -f $pp) { Remove-MpPreference -ExclusionProcess $pp } }
} catch { Write-Host ('  (Defender query failed: ' + $_.Exception.Message + ')') -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 10. Crack leftovers / fake license server
# ---------------------------------------------------------------------------
Section 'Crack leftovers'
$leftovers = @()
foreach ($p in @(
    (Join-Path $env:ProgramData 'FLEXnet'),
    (Join-Path $env:ProgramData 'FLEXlm'),
    (Join-Path $env:SystemDrive 'FlexLM'),
    (Join-Path $env:ProgramData 'Autodesk\Web Services\Adlm'),
    (Join-Path $env:ProgramData 'Autodesk\Adlm'))) {
    if (Test-Path -LiteralPath $p) { $leftovers += $p }
}
foreach ($p in $leftovers) { $pp = $p; Step ("Remove leftover folder {0}" -f $p) { Remove-Item -LiteralPath $pp -Recurse -Force } }
if ($leftovers.Count -eq 0) { Write-Host '  no crack-leftover folders' -ForegroundColor DarkGray }

$suspName = 'crack|keygen|licgen|xforce|xf-|adskflex|lmgrd|_orig|patched|licpath|\.bak$'
foreach ($root in @((Join-Path $pf86 'Common Files\Autodesk Shared'), (Join-Path $env:ProgramFiles 'Autodesk'))) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $hits = @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $suspName } | Select-Object -First 100)
    foreach ($h in $hits) { $hp = $h.FullName; Step ("Remove crack file {0}" -f $h.Name) { Remove-Item -LiteralPath $hp -Force } }
}

# ---------------------------------------------------------------------------
# 11. Execution blockers (IFEO)
# ---------------------------------------------------------------------------
Section 'Execution blockers (IFEO)'
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
        if ($name -match 'adsk|autodesk|genuine|flexnet|flexlm|licens|acad|revit') {
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
# 12. Autodesk folders (Program Files / ProgramData / caches / profiles)
# ---------------------------------------------------------------------------
Section 'Autodesk folders'
$userProfiles = @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
$folderTargets = @(
    (Join-Path $env:ProgramFiles 'Autodesk'),
    (Join-Path $pf86 'Autodesk'),
    (Join-Path $env:ProgramFiles 'Common Files\Autodesk Shared'),
    (Join-Path $env:ProgramFiles 'Common Files\Autodesk'),
    (Join-Path $pf86 'Common Files\Autodesk Shared'),
    (Join-Path $pf86 'Common Files\Autodesk'),
    (Join-Path $env:ProgramData 'Autodesk'),
    (Join-Path $env:ProgramData 'FLEXnet'),
    (Join-Path $env:ProgramData 'FLEXlm'),
    (Join-Path $env:PUBLIC 'Documents\Autodesk'),
    (Join-Path $env:SystemDrive 'Autodesk'),
    (Join-Path $env:SystemDrive 'FlexLM')
)
foreach ($u in $userProfiles) {
    $folderTargets += @(
        (Join-Path $u 'AppData\Local\Autodesk'),
        (Join-Path $u 'AppData\Roaming\Autodesk'),
        (Join-Path $u 'AppData\Local\FLEXnet'),
        (Join-Path $u 'AppData\Local\FLEXlm')
    )
    $tmpDir = Join-Path $u 'AppData\Local\Temp'
    if (Test-Path -LiteralPath $tmpDir) {
        foreach ($d in @(Get-ChildItem -LiteralPath $tmpDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Autodesk|AdODIS|AutoCAD)' })) {
            $folderTargets += $d.FullName
        }
    }
}
$folderTargets = @($folderTargets | Where-Object { $_ } | Select-Object -Unique)
$folderFound = @($folderTargets | Where-Object { Test-Path -LiteralPath $_ })
if ($folderFound.Count -eq 0) { Write-Host '  none' -ForegroundColor DarkGray }
foreach ($t in $folderFound) {
    $rp = (Resolve-Path -LiteralPath $t -ErrorAction SilentlyContinue).Path
    if ($rp -and $PSScriptRoot -and ($PSScriptRoot -like ($rp + '\*'))) {
        Write-Host ("  note: skipping {0} (the toolkit itself runs from inside it)" -f $t) -ForegroundColor DarkGray
        continue
    }
    $tt = $t
    Step ("Remove folder {0}" -f $tt) { Remove-Item -LiteralPath $tt -Recurse -Force }
}

# ---------------------------------------------------------------------------
# 13. Start Menu / Desktop shortcuts
# ---------------------------------------------------------------------------
Section 'Start Menu / Desktop shortcuts'
$shortcutPattern = 'autodesk|autocad|revit|inventor|navisworks|3ds ?max|maya|civil ?3d|advance steel|robot structural|infraworks|recap|desktop connector|fusion ?360'
$menuRoots = @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'))
foreach ($u in $userProfiles) { $menuRoots += (Join-Path $u 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs') }
$shortcutFound = $false
foreach ($mr in $menuRoots) {
    if (-not (Test-Path -LiteralPath $mr)) { continue }
    foreach ($d in @(Get-ChildItem -LiteralPath $mr -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(Autodesk|AutoCAD)' })) {
        $dd = $d.FullName; $shortcutFound = $true
        Step ("Remove Start Menu group {0}" -f $d.Name) { Remove-Item -LiteralPath $dd -Recurse -Force }
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $mr -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.lnk' -and $_.BaseName -match $shortcutPattern })) {
        $ff = $f.FullName; $shortcutFound = $true
        Step ("Remove shortcut {0}" -f $f.Name) { Remove-Item -LiteralPath $ff -Force }
    }
}
$desktopRoots = @((Join-Path $env:PUBLIC 'Desktop'))
foreach ($u in $userProfiles) { $desktopRoots += (Join-Path $u 'Desktop') }
foreach ($dr in $desktopRoots) {
    if (-not (Test-Path -LiteralPath $dr)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $dr -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.lnk' -and $_.BaseName -match $shortcutPattern })) {
        $ff = $f.FullName; $shortcutFound = $true
        Step ("Remove desktop shortcut {0}" -f $f.Name) { Remove-Item -LiteralPath $ff -Force }
    }
}
if (-not $shortcutFound) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 14. Registry keys
# ---------------------------------------------------------------------------
Section 'Registry keys'
$regKeys = @(
    'Registry::HKLM\SOFTWARE\Autodesk',
    'Registry::HKLM\SOFTWARE\WOW6432Node\Autodesk',
    'Registry::HKCU\SOFTWARE\Autodesk',
    'Registry::HKLM\SOFTWARE\FLEXlm License Manager',
    'Registry::HKLM\SOFTWARE\WOW6432Node\FLEXlm License Manager',
    'Registry::HKCU\SOFTWARE\FLEXlm License Manager'
)
$regFound = $false
foreach ($rk2 in $regKeys) {
    if (-not (Test-Path -LiteralPath $rk2)) { continue }
    $regFound = $true
    $rkp2 = $rk2; $rp2 = Get-RegPath $rk2
    Step ("Remove registry key {0}" -f $rp2) { Remove-Item -LiteralPath $rkp2 -Recurse -Force }
}
if (-not $regFound) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 15. Leftover Add-Remove entries
# ---------------------------------------------------------------------------
Section 'Leftover Add-Remove entries'
$arpFound = $false
foreach ($ur2 in $uninstallRoots) {
    if (-not (Test-Path -LiteralPath $ur2)) { continue }
    foreach ($k in @(Get-ChildItem -LiteralPath $ur2 -ErrorAction SilentlyContinue)) {
        $props = $null
        try { $props = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction Stop } catch { continue }
        $dn  = [string]$props.DisplayName
        $pub = [string]$props.Publisher
        if (($dn -notmatch $productPattern) -and ($pub -notmatch 'autodesk')) { continue }
        $arpFound = $true
        $akp = $k.PSPath; $akname = $k.PSChildName
        Step ("Remove leftover uninstall entry '{0}'" -f $dn) {
            if ($script:BackupDir) {
                $dest = Join-Path $script:BackupDir 'registry'
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                $safe = ($akname -replace '[^\w\.-]','_')
                & reg.exe export (Get-RegPath $akp) (Join-Path $dest ('purge-arp-' + $safe + '.reg')) /y | Out-Null
            }
            Remove-Item -LiteralPath $akp -Recurse -Force
        }
    }
}
if (-not $arpFound) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 16. App Paths
# ---------------------------------------------------------------------------
Section 'App Paths'
$apRoots = @(
    'Registry::HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
    'Registry::HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths'
)
$apFound = $false
foreach ($apr in $apRoots) {
    if (-not (Test-Path -LiteralPath $apr)) { continue }
    foreach ($k in @(Get-ChildItem -LiteralPath $apr -ErrorAction SilentlyContinue)) {
        $def = ''
        try { $def = [string](Get-Item -LiteralPath $k.PSPath).GetValue('') } catch { }
        if (($k.PSChildName -notmatch 'acad|autodesk|adsk|revit|inventor|navis|3dsmax|maya|civil3d') -and
            ($def -notmatch 'autodesk|adsk|revit|civil 3d|3ds')) { continue }
        $apFound = $true
        $akp = $k.PSPath
        Step ("Remove App Paths entry {0}" -f $k.PSChildName) { Remove-Item -LiteralPath $akp -Recurse -Force }
    }
}
if (-not $apFound) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 17. Broken MSI registrations
# ---------------------------------------------------------------------------
Section 'Broken MSI registrations'
# Windows Installer keeps its own registration of every MSI product; a broken
# one survives in Add/Remove data stores and can block a re-install of the
# same product code (seen in the lab with a leftover product code). These keys
# are exported to the backup folder before removal.
$ciRoots = @(
    'Registry::HKLM\SOFTWARE\Classes\Installer\Products',
    'Registry::HKLM\SOFTWARE\WOW6432Node\Classes\Installer\Products'
)
$ciFound = $false
foreach ($cr in $ciRoots) {
    if (-not (Test-Path -LiteralPath $cr)) { continue }
    foreach ($ck in @(Get-ChildItem -LiteralPath $cr -ErrorAction SilentlyContinue)) {
        $pn = ''
        try { $pn = [string](Get-ItemProperty -LiteralPath ($ck.PSPath + '\Properties') -Name 'ProductName' -ErrorAction Stop).ProductName } catch { }
        if (-not $pn -or $pn -notmatch $productPattern) { continue }
        $ciFound = $true
        if ($Apply -and -not $script:BackupDir) {
            Write-Host ("  [ skip ] MSI registration '{0}' (no backup folder - rerun without -SkipBackup to remove it)" -f $pn) -ForegroundColor Yellow
            continue
        }
        $ckp = $ck.PSPath; $ckname = $ck.PSChildName
        Step ("Remove MSI registration {0} ('{1}')" -f $ckname, $pn) {
            if ($script:BackupDir) {
                $dest = Join-Path $script:BackupDir 'registry'
                New-Item -ItemType Directory -Force -Path $dest | Out-Null
                & reg.exe export (Get-RegPath $ckp) (Join-Path $dest ('purge-msi-' + $ckname + '.reg')) /y | Out-Null
            }
            Remove-Item -LiteralPath $ckp -Recurse -Force
        }
    }
}
if (-not $ciFound) { Write-Host '  none' -ForegroundColor DarkGray }

# ---------------------------------------------------------------------------
# 18. Environment variables
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
# 19. Verification
# ---------------------------------------------------------------------------
Section 'Verification'
if (-not $Apply) {
    Write-Host '  preview - run with -Apply to remove the items above; this check then reports leftovers' -ForegroundColor DarkGray
} else {
    $left = New-Object System.Collections.Generic.List[string]
    foreach ($s in @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'adsk|autodesk|genuine' -or $_.DisplayName -match 'autodesk|adsk' })) {
        $left.Add('service ' + $s.Name)
    }
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -match 'autodesk|adsk|genuine' })) {
        $left.Add('task ' + $t.TaskName)
    }
    foreach ($t in $folderTargets) { if (Test-Path -LiteralPath $t) { $left.Add('folder ' + $t) } }
    foreach ($k in $regKeys)       { if (Test-Path -LiteralPath $k) { $left.Add('registry ' + (Get-RegPath $k)) } }
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { ($_.ProcessName -match 'adsk|autodesk|acad|revit') -and ($_.ProcessName -notmatch 'AdskDoctor|UNLOCK') } | Select-Object -ExpandProperty ProcessName -Unique)) {
        $left.Add('process ' + $p)
    }
    if ($left.Count -eq 0) {
        Write-Host '  VERIFIED: no Autodesk components remain on this machine.' -ForegroundColor Green
    } else {
        Write-Host ("  {0} item(s) still present - locked files usually clear after a reboot; run the purge once more then:" -f $left.Count) -ForegroundColor Yellow
        foreach ($l in $left) { Write-Host ('   - ' + $l) -ForegroundColor DarkGray }
    }
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
if ($Apply) {
    Write-Host ("   Removed items : {0}" -f $script:Changes) -ForegroundColor Green
    Write-Host ("   Failures      : {0}" -f $script:Errors)  -ForegroundColor $(if ($script:Errors) {'Red'} else {'Green'})
    Write-Host ''
    Write-Host '   Next steps:' -ForegroundColor Cyan
    Write-Host '     1. Restart Windows (releases files that were still locked).' -ForegroundColor Cyan
    Write-Host '     2. Install a fresh official copy of the product you need.' -ForegroundColor Cyan
    Write-Host '        (top bar -> Download official products -> manage.autodesk.com)' -ForegroundColor Cyan
    Write-Host '     3. Sign in with the licensed Autodesk account (single-user).' -ForegroundColor Cyan
} else {
    Write-Host '   PREVIEW only - nothing was changed.' -ForegroundColor Green
    Write-Host '   Run again with  -Apply  to remove everything listed above (a backup runs first).' -ForegroundColor Yellow
}
Write-Host ''
