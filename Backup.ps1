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
    & robocopy $Source $DestPath /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
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
    'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
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

# folders (recursive copies)
$folderTargets = @(
    (Join-Path $commonFiles 'AdskLicensing'),
    (Join-Path $commonFiles 'AdSSO'),
    (Join-Path $commonFiles 'Network License Manager'),
    (Join-Path $env:ProgramData 'FLEXnet'),
    'C:\Autodesk\Network License Manager'
)
foreach ($src in $folderTargets) {
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $leaf = Split-Path -Leaf $src
    $out  = Join-Path $filesDir $leaf
    if (Copy-Tree -Source $src -DestPath $out) { Add-Item 'folder' $src $out 'ok'; Say ("  backed up: {0}" -f $src) 'Gray' }
    else { Add-Item 'folder' $src $out 'failed'; Say ("  FAILED: {0}" -f $src) 'Yellow' }
}

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
    ForEach-Object { 'robocopy "{0}" "{1}" /E /R:1 /W:1 | Out-Null' -f $_.Backup, $_.Source }) -join "`n")

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

`$fw = Join-Path `$PSScriptRoot 'state\firewall.wfw'
if (Test-Path -LiteralPath `$fw) {
    Write-Host 'Restoring firewall policy...' -ForegroundColor Cyan
    netsh advfirewall import `"`$fw`"
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
