<#
    Backup.ps1  -  Phase 2: MANDATORY BACKUP (layered, restore-point-independent)
    ---------------------------------------------------------------------------
    Creates an undo-able safety net BEFORE any cleanup. Works even when
    System Restore / System Protection is disabled or blocked by policy.

    Layers:
      1. System Restore point        (best effort - skipped if it fails)
      2. Registry export (.reg)      of every key the cleanup may touch
      3. File / folder backups       (hosts, AdskLicensing, AdSSO, FLEXnet, NLM)
      4. System state snapshots      (services, firewall, tasks, env)
      5. An UNDO.ps1 script          that reverses everything above

    Nothing on the system is modified except the optional restore point.

    Usage:
      .\Backup.ps1
      .\Backup.ps1 -SkipRestorePoint
      .\Backup.ps1 -BackupRoot "D:\AdskBackups" -Label "customer-name"
#>

[CmdletBinding()]
param(
    [string]$BackupRoot,
    [switch]$SkipRestorePoint,
    [string]$Label
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

if (-not $BackupRoot) { $BackupRoot = Join-Path $PSScriptRoot 'backups' }
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$suffix = if ($Label) { '_' + ($Label -replace '[^\w\-]','_') } else { '' }
$dest   = Join-Path $BackupRoot ("{0}_{1}{2}" -f $env:COMPUTERNAME, $stamp, $suffix)

$regDir   = Join-Path $dest 'registry'
$filesDir = Join-Path $dest 'files'
$stateDir = Join-Path $dest 'state'
foreach ($d in @($dest,$regDir,$filesDir,$stateDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

$script:Items = New-Object System.Collections.Generic.List[object]
function Add-Item {
    param([string]$Type,[string]$Source,[string]$Backup,[string]$Status)
    $script:Items.Add([pscustomobject]@{ Type=$Type; Source=$Source; Backup=$Backup; Status=$Status })
}
function Say {
    param([string]$Msg,[string]$Color='Gray')
    Write-Host $Msg -ForegroundColor $Color
    Add-Content -LiteralPath (Join-Path $dest 'backup.log') -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg)
}

function Copy-Tree {
    param([string]$Source,[string]$DestPath)
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    # /XJ: robocopy follows junctions by default, which stored the doctored old
    # build (behind AdskLicensing\Current) as a real folder and made UNDO copy
    # its files through the junction into the genuine build (lab run 2026-10-16)
    & robocopy $Source $DestPath /E /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
    return ($LASTEXITCODE -lt 8)
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '   Autodesk Licensing Doctor  -  Phase 2: Backup' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Say ("Backup folder: {0}" -f $dest) 'White'

# ---------------------------------------------------------------------------
# Layer 1: System Restore point (best effort)
# ---------------------------------------------------------------------------
$restore = [pscustomobject]@{ Attempted = -not $SkipRestorePoint; Created = $false; Message = 'skipped' }
if ($SkipRestorePoint) {
    Say 'Restore point: skipped (-SkipRestorePoint)' 'Yellow'
} else {
    Say 'Attempting to create a System Restore point...' 'Gray'
    try {
        foreach ($d in @("$env:SystemDrive\")) { Enable-ComputerRestore -Drive $d -ErrorAction Stop }
    } catch {
        $restore.Message = 'Enable-ComputerRestore: ' + $_.Exception.Message
        Say ('  System Protection could not be enabled: ' + $_.Exception.Message) 'Yellow'
    }
    try {
        Checkpoint-Computer -Description ("AdskDoctor before cleanup " + $stamp) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $restore.Created = $true
        $restore.Message = 'Restore point created'
        Say '  Restore point created.' 'Green'
    } catch {
        if (-not $restore.Message) { $restore.Message = '' }
        $restore.Message += ' | Checkpoint-Computer: ' + $_.Exception.Message
        Say ('  Restore point FAILED: ' + $_.Exception.Message) 'Yellow'
        Say '  -> continuing: the .reg / files / undo layers do NOT depend on it.' 'Yellow'
    }
}

# ---------------------------------------------------------------------------
# Layer 2: Registry export
# ---------------------------------------------------------------------------
Say 'Exporting registry keys...' 'Gray'
$regKeys = @(
    'HKLM\SOFTWARE\Autodesk',
    'HKLM\SOFTWARE\WOW6432Node\Autodesk',
    'HKCU\SOFTWARE\Autodesk',
    'HKLM\SOFTWARE\FLEXlm License Manager',
    'HKLM\SOFTWARE\WOW6432Node\FLEXlm License Manager',
    'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',
    'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options',
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
$regExported = 0
foreach ($k in $regKeys) {
    $exists = $false
    try { $exists = (Test-Path -LiteralPath ("Registry::" + $k)) } catch {}
    if (-not $exists) { continue }
    $safe = ($k -replace '[\\:*?"<>|]','_')
    $out  = Join-Path $regDir ($safe + '.reg')
    & reg.exe export "$k" "$out" /y *> $null
    if ($LASTEXITCODE -eq 0) { $regExported++; Add-Item 'registry' $k $out 'ok' }
    else { Add-Item 'registry' $k '' 'failed' }
}

# Every OTHER profile gets the same per-user keys exported (the purge wipes
# them machine-wide): loaded accounts are exported directly, offline accounts
# through a short hive mount. Offline exports are re-tagged with the real SID
# so UNDO.ps1 can import them the next time that account is loaded.
$userRegNames = @('SOFTWARE\Autodesk', 'SOFTWARE\FLEXlm License Manager')
$backupSid = $null
try { $backupSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value } catch { }
foreach ($hu in @(Get-ChildItem -LiteralPath 'Registry::HKEY_USERS' -ErrorAction SilentlyContinue)) {
    $sid = $hu.PSChildName
    if ($sid -eq '.DEFAULT' -or $sid -eq $backupSid -or $sid -like '*_Classes') { continue }
    if ($sid -match '^S-1-5-(18|19|20)$') { continue }
    foreach ($sub in $userRegNames) {
        $k = 'HKU\{0}\{1}' -f $sid, $sub
        $exists = $false
        try { $exists = (Test-Path -LiteralPath ("Registry::" + $k)) } catch {}
        if (-not $exists) { continue }
        $safe = ($k -replace '[\\:*?"<>|]','_')
        $out  = Join-Path $regDir ($safe + '.reg')
        & reg.exe export "$k" "$out" /y *> $null
        if ($LASTEXITCODE -eq 0) { $regExported++; Add-Item 'registry' $k $out 'ok' }
        else { Add-Item 'registry' $k '' 'failed' }
    }
}
$bkpSidByDir = @{}
try {
    foreach ($pl in @(Get-ChildItem -LiteralPath 'Registry::HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue)) {
        try {
            $img = [string](Get-ItemProperty -LiteralPath $pl.PSPath -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath
            if ($img) { $bkpSidByDir[$img.TrimEnd('\')] = $pl.PSChildName }
        } catch { }
    }
} catch { }
foreach ($dir in @($bkpSidByDir.Keys)) {
    $sid = $bkpSidByDir[$dir]
    if ($sid -eq $backupSid) { continue }
    if ($sid -match '^S-1-5-(18|19|20)$') { continue }
    $mounted = $false
    try { $mounted = (Test-Path -LiteralPath ("Registry::HKEY_USERS\" + $sid)) } catch {}
    if ($mounted) { continue }
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    $hiveFile = Join-Path $dir 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $hiveFile)) { continue }
    $mountName = 'UlBkpTmp{0}' -f (Get-Random)
    $mount = 'HKU\' + $mountName
    & reg.exe load $mount $hiveFile 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Say ('  note: profile hive of {0} could not be mounted for backup - skipped' -f (Split-Path -Leaf $dir)) 'Yellow'
        continue
    }
    try {
        foreach ($sub in $userRegNames) {
            $k = '{0}\{1}' -f $mount, $sub
            $exists = $false
            try { $exists = (Test-Path -LiteralPath ("Registry::" + $k)) } catch {}
            if (-not $exists) { continue }
            # the backup file and its content both carry the real SID, never the
            # temporary mount name, so UNDO.ps1 can import it later
            $sidPath = $k -replace [regex]::Escape($mountName), $sid
            $safe = ($sidPath -replace '[\\:*?"<>|]','_')
            $out  = Join-Path $regDir ($safe + '.reg')
            & reg.exe export "$k" "$out" /y *> $null
            if ($LASTEXITCODE -eq 0) {
                try {
                    # reg.exe writes HKEY_USERS\<mount>... - swap the temporary
                    # mount name for the real SID before the hive is unloaded
                    $txt = Get-Content -LiteralPath $out -Raw
                    $txt = $txt -replace [regex]::Escape($mountName), $sid
                    Set-Content -LiteralPath $out -Value $txt -Encoding Unicode
                } catch { }
                $regExported++; Add-Item 'registry' $sidPath $out 'ok'
            }
            else { Add-Item 'registry' $k '' 'failed' }
        }
    } finally {
        [gc]::Collect()
        $unloaded = $false
        for ($ui = 0; $ui -lt 5 -and -not $unloaded; $ui++) {
            Start-Sleep -Milliseconds 300
            & reg.exe unload $mount 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $unloaded = $true }
        }
        if (-not $unloaded) { Say ('  note: backup hive {0} could not be unloaded - it clears at reboot' -f (Split-Path -Leaf $dir)) 'Yellow' }
    }
}

Say ("  registry keys exported: {0}" -f $regExported) 'Gray'

# ---------------------------------------------------------------------------
# Layer 3: File / folder backups
# ---------------------------------------------------------------------------
Say 'Backing up files and folders...' 'Gray'
$commonFiles = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared'

# hosts file
$hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
if (Test-Path -LiteralPath $hostsPath) {
    $hOut = Join-Path $filesDir 'hosts'
    Copy-Item -LiteralPath $hostsPath -Destination $hOut -Force
    Add-Item 'file' $hostsPath $hOut 'ok'
    Say '  hosts backed up' 'Gray'
}

# folders (recursive copies). The leaf name has to be unique per source: two
# different folders can share it (a Network License Manager lives in Common
# Files AND under C:\Autodesk), and copying both into the same backup folder
# merged them, so UNDO would have copied the mixture back to both places.
$folderTargets = @(
    @{ Src = (Join-Path $commonFiles 'AdskLicensing');                  Leaf = 'AdskLicensing' },
    @{ Src = (Join-Path $commonFiles 'AdSSO');                          Leaf = 'AdSSO' },
    @{ Src = (Join-Path $commonFiles 'Network License Manager');        Leaf = 'CommonFiles-NetworkLicenseManager' },
    @{ Src = 'C:\Autodesk\Network License Manager';                     Leaf = 'Autodesk-NetworkLicenseManager' },
    @{ Src = 'C:\FlexLM';                                               Leaf = 'FlexLM' },
    @{ Src = (Join-Path $env:ProgramData 'FLEXnet');                    Leaf = 'FLEXnet' },
    @{ Src = (Join-Path $env:ProgramData 'Autodesk\Adlm');              Leaf = 'Autodesk-Adlm' },
    @{ Src = (Join-Path $env:ProgramData 'Autodesk\Web Services\Adlm'); Leaf = 'Autodesk-WebServices-Adlm' }
)
foreach ($t in $folderTargets) {
    $src = $t.Src
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $out = Join-Path $filesDir $t.Leaf
    if (Copy-Tree -Source $src -DestPath $out) { Add-Item 'folder' $src $out 'ok'; Say ("  backed up: {0}" -f $src) 'Gray' }
    else { Add-Item 'folder' $src $out 'failed'; Say ("  FAILED: {0}" -f $src) 'Yellow' }
}

# Loose crack files that the clean-up deletes (adskflex.exe directly under
# Common Files\Autodesk Shared, a patched copy or licence file in the product
# tree): nothing captured them before, so UNDO could not bring the pre-clean
# state back (seen in the lab run 2026-10-16). The pattern mirrors the
# clean-up's own suspicious-name list.
$suspName = 'crack|keygen|licgen|xforce|xf-|adskflex|lmgrd|_orig|patched|licpath|\.bak$'
$loose = @()
foreach ($root in @($commonFiles, (Join-Path $env:ProgramFiles 'Autodesk'))) {
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $loose += @(Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match $suspName } | Select-Object -First 50)
}
$li = 0
foreach ($f in $loose) {
    $li++
    $out = Join-Path $filesDir ('loose-' + $li.ToString('00') + '-' + $f.Name)
    try {
        Copy-Item -LiteralPath $f.FullName -Destination $out -Force -ErrorAction Stop
        Add-Item 'file' $f.FullName $out 'ok'
    } catch { Add-Item 'file' $f.FullName '' 'failed' }
}
if ($loose.Count) { Say ("  loose crack files backed up: {0}" -f $loose.Count) 'Gray' }

# ---------------------------------------------------------------------------
# Layer 4: System state snapshots
# ---------------------------------------------------------------------------
Say 'Snapshotting system state...' 'Gray'
try {
    Get-CimInstance Win32_Service |
        Select-Object Name,DisplayName,State,StartMode,PathName |
        Export-Csv -LiteralPath (Join-Path $stateDir 'services.csv') -NoTypeInformation -Encoding UTF8
    Add-Item 'state' 'services' (Join-Path $stateDir 'services.csv') 'ok'
} catch { Add-Item 'state' 'services' '' 'failed' }

try {
    $fw = Join-Path $stateDir 'firewall.wfw'
    & netsh advfirewall export "$fw" *> $null
    if (Test-Path -LiteralPath $fw) { Add-Item 'state' 'firewall' $fw 'ok' } else { Add-Item 'state' 'firewall' '' 'failed' }
} catch { Add-Item 'state' 'firewall' '' 'failed' }

try {
    $tasks = Get-ScheduledTask | Where-Object { $_.TaskName -match 'autodesk|adsk|flexnet' }
    $tOut = Join-Path $stateDir 'scheduled_tasks.xml'
    if ($tasks) { $tasks | Export-Clixml -LiteralPath $tOut; Add-Item 'state' 'tasks' $tOut 'ok' }
    else { Add-Item 'state' 'tasks' '' 'none' }
} catch { Add-Item 'state' 'tasks' '' 'failed' }

try {
    $envOut = Join-Path $stateDir 'environment.txt'
    $lines = @()
    foreach ($scope in @(@{n='Machine';d=[Environment]::GetEnvironmentVariables('Machine')},
                         @{n='User';d=[Environment]::GetEnvironmentVariables('User')})) {
        foreach ($k in $scope.d.Keys) { $lines += ("{0}\t{1}\t{2}" -f $scope.n,$k,$scope.d[$k]) }
    }
    $lines | Set-Content -LiteralPath $envOut -Encoding UTF8
    Add-Item 'state' 'environment' $envOut 'ok'
} catch { Add-Item 'state' 'environment' '' 'failed' }

# Defender exclusions belong to the state the clean-up changes (a crack adds
# them so its patched files are never scanned), so the exact list is captured
# here and UNDO.ps1 adds it back.
try {
    $defOut = Join-Path $stateDir 'defender-exclusions.txt'
    $mpNow = Get-MpPreference -ErrorAction Stop
    $defLines = @()
    foreach ($x in @($mpNow.ExclusionPath))      { if ($x) { $defLines += ('Path'      + [char]9 + $x) } }
    foreach ($x in @($mpNow.ExclusionExtension)) { if ($x) { $defLines += ('Extension' + [char]9 + $x) } }
    foreach ($x in @($mpNow.ExclusionProcess))   { if ($x) { $defLines += ('Process'   + [char]9 + $x) } }
    Set-Content -LiteralPath $defOut -Value $defLines -Encoding UTF8
    Add-Item 'state' 'defender-exclusions' $defOut 'ok'
} catch { Add-Item 'state' 'defender-exclusions' '' 'failed' }

# ---------------------------------------------------------------------------
# Layer 5: UNDO script
# ---------------------------------------------------------------------------
Say 'Writing UNDO.ps1 ...' 'Gray'
$undoPath = Join-Path $dest 'UNDO.ps1'
$regBlock = (@($script:Items | Where-Object { $_.Type -eq 'registry' -and $_.Status -eq 'ok' } |
    ForEach-Object { 'reg.exe import "{0}"' -f $_.Backup }) -join "`n")
$fileBlock = (@($script:Items | Where-Object { $_.Type -eq 'file' -and $_.Status -eq 'ok' } |
    ForEach-Object { 'Copy-Item -LiteralPath "{0}" -Destination "{1}" -Force' -f $_.Backup, $_.Source }) -join "`n")
$folderBlock = (@($script:Items | Where-Object { $_.Type -eq 'folder' -and $_.Status -eq 'ok' } |
    ForEach-Object { 'robocopy "{0}" "{1}" /E /R:1 /W:1 /XJ | Out-Null' -f $_.Backup, $_.Source }) -join "`n")

$undo = @"
<#
    UNDO.ps1 - restores the machine to the state captured by AdskDoctor Phase 2.
    Run as Administrator.  Backup: $dest
#>
`$ErrorActionPreference = 'Continue'
Write-Host 'Restoring registry...' -ForegroundColor Cyan
$regBlock

Write-Host 'Restoring files...' -ForegroundColor Cyan
$fileBlock

Write-Host 'Restoring folders...' -ForegroundColor Cyan
$folderBlock

# Services removed by a clean-up cannot be restored from a file copy, so they
# are recreated from the snapshot taken before the clean-up.
`$csv = Join-Path `$PSScriptRoot 'state\services.csv'
if (Test-Path -LiteralPath `$csv) {
    Write-Host 'Restoring services...' -ForegroundColor Cyan
    foreach (`$s in (Import-Csv -LiteralPath `$csv)) {
        if (-not `$s.Name) { continue }
        if (Get-Service -Name `$s.Name -ErrorAction SilentlyContinue) { continue }
        `$start = switch (`$s.StartMode) { 'Auto' { 'auto' } 'Manual' { 'demand' } 'Disabled' { 'disabled' } 'Boot' { 'boot' } 'System' { 'system' } default { 'auto' } }
        Write-Host ("  recreating service " + `$s.Name) -ForegroundColor Yellow
        sc.exe create `$s.Name binPath= "`$(`$s.PathName)" DisplayName= "`$(`$s.DisplayName)" start= `$start | Out-Null
        if (`$s.State -eq 'Running') { sc.exe start `$s.Name | Out-Null }
    }
}

`$fw = Join-Path `$PSScriptRoot 'state\firewall.wfw'
if (Test-Path -LiteralPath `$fw) {
    Write-Host 'Restoring firewall policy...' -ForegroundColor Cyan
    netsh advfirewall import `"`$fw`"
}

# Defender exclusions removed by the clean-up (a crack adds them to hide its
# patched files) are added back from the snapshot taken before the clean-up.
`$def = Join-Path `$PSScriptRoot 'state\defender-exclusions.txt'
if (Test-Path -LiteralPath `$def) {
    Write-Host 'Restoring Defender exclusions...' -ForegroundColor Cyan
    foreach (`$ex in (Get-Content -LiteralPath `$def)) {
        `$parts = `$ex -split '[\t]', 2
        if (`$parts.Count -lt 2) { continue }
        switch (`$parts[0]) {
            'Path'      { Add-MpPreference -ExclusionPath `$parts[1] -ErrorAction SilentlyContinue }
            'Extension' { Add-MpPreference -ExclusionExtension `$parts[1] -ErrorAction SilentlyContinue }
            'Process'   { Add-MpPreference -ExclusionProcess `$parts[1] -ErrorAction SilentlyContinue }
        }
    }
}

Write-Host ''
Write-Host 'UNDO complete. Reboot recommended.' -ForegroundColor Green
"@
Set-Content -LiteralPath $undoPath -Value $undo -Encoding UTF8
Say ("  UNDO script: {0}" -f $undoPath) 'Gray'

# ---------------------------------------------------------------------------
# Manifest + summary
# ---------------------------------------------------------------------------
$manifest = [pscustomobject]@{
    Computer     = $env:COMPUTERNAME
    Date         = (Get-Date).ToString('s')
    Label        = $Label
    BackupFolder = $dest
    RestorePoint = $restore
    Items        = $script:Items
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $dest 'manifest.json') -Encoding UTF8

$total = (Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum
if (-not $total) { $total = 0 }
$sizeText = if ($total -ge 1MB) { "{0:N1} MB" -f ($total/1MB) } else { "{0:N0} KB" -f ($total/1KB) }

Write-Host ''
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host '   BACKUP SUMMARY' -ForegroundColor Cyan
Write-Host '------------------------------------------------------------' -ForegroundColor Cyan
Write-Host ("   Restore point : {0}" -f $(if ($restore.Created) {'CREATED'} elseif ($SkipRestorePoint) {'skipped'} else {'FAILED (layers 2-5 still cover you)'})) -ForegroundColor $(if ($restore.Created) {'Green'} else {'Yellow'})
Write-Host ("   Registry keys : {0}" -f $regExported) -ForegroundColor Green
Write-Host ("   Folders/files : {0}" -f @($script:Items | Where-Object { $_.Type -in @('file','folder') -and $_.Status -eq 'ok' }).Count) -ForegroundColor Green
Write-Host ("   State files   : {0}" -f @($script:Items | Where-Object { $_.Type -eq 'state' -and $_.Status -eq 'ok' }).Count) -ForegroundColor Green
Write-Host ("   Total size    : {0}" -f $sizeText) -ForegroundColor Gray
Write-Host ("   Location      : {0}" -f $dest) -ForegroundColor White
Write-Host ("   Undo script   : {0}" -f $undoPath) -ForegroundColor White
Write-Host ''
Write-Host '   To roll back everything: run UNDO.ps1 as Administrator.' -ForegroundColor Yellow
Write-Host ''
