<#
    NlmFix.ps1 - clear the stale local NLM pointers that block AutoCAD 2027
    setup with:
      "The Network License Manager version you use does not meet the minimum
       requirements for this product."

    PREVIEW by default. Add -Apply to back up and remove the pointers.
    It never removes the NLM installation or its service. If this PC is the
    license server, update NLM to 11.19.9.0+ instead.

    This is the same logic Repair.ps1 runs as its first repair step.
#>

[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$CheckOnly,
    [switch]$SkipBackup,
    [string]$BackupRoot,
    [switch]$KeepNetworkSettings,
    [switch]$NoServiceRestart,
    [string]$ProgramDataRoot = $env:ProgramData,
    [switch]$SkipRegistry,
    [switch]$SkipEnvironment,
    [switch]$SkipService
)

$ErrorActionPreference = 'Continue'

# -CheckOnly is always read-only, even if -Apply was also passed.
if ($CheckOnly) { $Apply = $false }

$common = Join-Path $PSScriptRoot 'NlmCommon.ps1'
if (-not (Test-Path -LiteralPath $common)) {
    Write-Host 'NlmCommon.ps1 is missing - cannot run the NLM check.' -ForegroundColor Red
    return
}
. $common

$script:LogPath = $null
if (-not $env:ADSKDOCTOR_NOLOG) {
    try {
        $logRoot = if ($env:ADSKDOCTOR_LOGDIR) { $env:ADSKDOCTOR_LOGDIR } else { Join-Path $env:ProgramData 'UNLOCK DIGITAL\logs' }
        New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
        $script:LogPath = Join-Path $logRoot ('nlmfix-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -LiteralPath $script:LogPath -Force | Out-Null
    } catch { $script:LogPath = $null }
}

try {
    $result = Invoke-NlmBlockerFix -Apply:$Apply -SkipBackup:$SkipBackup -BackupRoot $BackupRoot `
        -KeepNetworkSettings:$KeepNetworkSettings -NoServiceRestart:$NoServiceRestart `
        -ProgramDataRoot $ProgramDataRoot -SkipRegistry:$SkipRegistry `
        -SkipEnvironment:$SkipEnvironment -SkipService:$SkipService

    $backupText = if ($result.Backup) { [string]$result.Backup } else { '-' }
    Write-Host ('NLMCHECK blockers={0} old={1} network={2}' -f `
        $result.InitialCount, $result.InitialOld, [int]$result.InitialNetwork)
    Write-Host ('NLMRESULT applied={0} remaining={1} backup={2} errors={3}' -f `
        $result.Applied, $result.Remaining, $backupText, @($result.Errors).Count)
    if ($script:LogPath) { Write-Host ('Log: {0}' -f $script:LogPath) -ForegroundColor DarkGray }
} finally {
    if ($script:LogPath) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
