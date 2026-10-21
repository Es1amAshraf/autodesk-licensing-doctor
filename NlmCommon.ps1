<#
    NlmCommon.ps1 - shared logic for the AutoCAD 2027 "Network License
    Manager version is too old" installer blocker.

    Dot-source this file. It defines functions only and changes nothing.

    The cleanup is deliberately narrower than Clean.ps1: it removes stale
    local NLM pointers that the AutoCAD 2027 installer reads. It never removes
    the NLM installation or its service. If this PC is a license server, the
    correct fix is to update NLM to 11.19.9.0 or newer, not to run this.
#>

$script:NlmMinimumVersion = [version]'11.19.9.0'
$script:NlmEnvNames = @('ADSKFLEX_LICENSE_FILE', 'ADSK_LICENSE_FILE', 'LICPATH', 'ACADSERVER')

$script:NlmRegistryTargets = @(
    [pscustomobject]@{
        Path    = 'HKLM:\SOFTWARE\Autodesk\Network License Manager'
        RegPath = 'HKLM\SOFTWARE\Autodesk\Network License Manager'
        Label   = 'HKLM-Autodesk-NetworkLicenseManager'
    },
    [pscustomobject]@{
        Path    = 'HKLM:\SOFTWARE\WOW6432Node\Autodesk\Network License Manager'
        RegPath = 'HKLM\SOFTWARE\WOW6432Node\Autodesk\Network License Manager'
        Label   = 'HKLM-WOW6432Node-Autodesk-NetworkLicenseManager'
    }
)

$script:NlmEnvTargets = @(
    [pscustomobject]@{
        Scope   = 'Machine'
        Key     = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        RegPath = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        Label   = 'Machine-Environment'
    },
    [pscustomobject]@{
        Scope   = 'User'
        Key     = 'HKCU:\Environment'
        RegPath = 'HKCU\Environment'
        Label   = 'User-Environment'
    }
)

function Test-NlmAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-NlmExeFromCommandLine {
    param([string]$CommandLine)
    if (-not $CommandLine) { return $null }
    if ($CommandLine -match '^\s*"([^"]+\.exe)"') { return $matches[1] }
    if ($CommandLine -match '^\s*(.+?\.exe)\b') { return $matches[1].Trim('"') }
    return $null
}

function ConvertTo-NlmVersion {
    param([string]$Text)
    if (-not $Text) { return $null }
    $m = [regex]::Match($Text, '(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?')
    if (-not $m.Success) { return $null }
    $revision = 0
    if ($m.Groups[4].Success) { $revision = [int]$m.Groups[4].Value }
    try {
        return [version]('{0}.{1}.{2}.{3}' -f `
            [int]$m.Groups[1].Value, [int]$m.Groups[2].Value,
            [int]$m.Groups[3].Value, $revision)
    } catch { return $null }
}

function Get-NlmVersionInfo {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $vi = $null
    try { $vi = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo } catch { return $null }
    $text = [string]$vi.FileVersion
    if (-not $text) { $text = [string]$vi.ProductVersion }
    $parsed = ConvertTo-NlmVersion $text
    return [pscustomobject]@{
        Path        = $Path
        VersionText = $text
        Version     = $parsed
        IsOld       = [bool]($parsed -and $parsed -lt $script:NlmMinimumVersion)
    }
}

function Get-NlmInstallBlockers {
    param(
        [string]$ProgramDataRoot = $env:ProgramData,
        [switch]$SkipRegistry,
        [switch]$SkipEnvironment,
        [switch]$SkipService
    )

    if (-not $ProgramDataRoot) { $ProgramDataRoot = $env:ProgramData }
    $files = New-Object System.Collections.Generic.List[object]
    $regs  = New-Object System.Collections.Generic.List[object]
    $envs  = New-Object System.Collections.Generic.List[object]
    $nlm   = New-Object System.Collections.Generic.List[object]
    $seen  = @{}

    # --- stale files under the licensing service's data folder ---------------
    $licDir = Join-Path $ProgramDataRoot 'Autodesk\AdskLicensingService'
    $serverInfo = Join-Path $licDir 'nlm-server-info.json'
    if (Test-Path -LiteralPath $serverInfo) {
        $files.Add([pscustomobject]@{
            Path = $serverInfo
            Name = 'nlm-server-info.json'
        })
    }
    if (Test-Path -LiteralPath $licDir) {
        $licpaths = @(Get-ChildItem -LiteralPath $licDir -Recurse -File -Filter 'licpath.lic' -ErrorAction SilentlyContinue)
        foreach ($f in $licpaths) {
            $files.Add([pscustomobject]@{
                Path = $f.FullName
                Name = $f.Name
            })
        }
    }

    # --- stale NLM registry keys --------------------------------------------
    if (-not $SkipRegistry) {
        foreach ($target in $script:NlmRegistryTargets) {
            if (Test-Path -LiteralPath $target.Path) {
                $regs.Add([pscustomobject]@{
                    Path    = $target.Path
                    RegPath = $target.RegPath
                    Label   = $target.Label
                })
            }
        }
    }

    # --- stale NLM environment variables ------------------------------------
    if (-not $SkipEnvironment) {
        foreach ($target in $script:NlmEnvTargets) {
            $props = Get-ItemProperty -LiteralPath $target.Key -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            foreach ($name in $script:NlmEnvNames) {
                $prop = @($props.PSObject.Properties | Where-Object { $_.Name -ieq $name }) | Select-Object -First 1
                if (-not $prop) { continue }
                $envs.Add([pscustomobject]@{
                    Scope   = $target.Scope
                    Key     = $target.Key
                    RegPath = $target.RegPath
                    Label   = $target.Label
                    Name    = $name
                    Value   = [string]$prop.Value
                })
            }
        }
    }

    # --- NLM installations, services and processes (warnings, never deleted) -
    $knownRoots = @()
    if (${env:ProgramFiles(x86)}) { $knownRoots += (Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared\Network License Manager') }
    if ($env:ProgramFiles)        { $knownRoots += (Join-Path $env:ProgramFiles 'Common Files\Autodesk Shared\Network License Manager') }
    $knownRoots += 'C:\Autodesk\Network License Manager'
    if ($env:ProgramFiles)        { $knownRoots += (Join-Path $env:ProgramFiles 'Autodesk\Network License Manager') }
    if (${env:ProgramFiles(x86)}) { $knownRoots += (Join-Path ${env:ProgramFiles(x86)} 'Autodesk\Network License Manager') }
    $knownRoots = @($knownRoots | Select-Object -Unique)

    foreach ($root in $knownRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($exeName in @('adskflex.exe', 'lmgrd.exe')) {
            $exe = Join-Path $root $exeName
            if (-not (Test-Path -LiteralPath $exe)) { continue }
            $vi = Get-NlmVersionInfo $exe
            $key = ('file|' + $exe).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $nlm.Add([pscustomobject]@{
                Kind        = 'NLM file'
                Name        = $exeName
                Path        = $exe
                VersionText = if ($vi) { $vi.VersionText } else { '' }
                Version     = if ($vi) { $vi.Version } else { $null }
                IsOld       = [bool]($vi -and $vi.IsOld)
            })
        }
    }

    if (-not $SkipService) {
        $services = @()
        $services += @(Get-Service -Name 'AdskNLM' -ErrorAction SilentlyContinue)
        try {
            $services += @(Get-Service -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -match 'Network License Manager' })
        } catch { }
        $services = @($services | Sort-Object -Property Name -Unique)

        foreach ($svc in $services) {
            $cim = Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $svc.Name.Replace("'", "''")) -ErrorAction SilentlyContinue
            $path = Get-NlmExeFromCommandLine ([string]$cim.PathName)
            $vi = if ($path) { Get-NlmVersionInfo $path } else { $null }
            $key = ('service|' + $svc.Name).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $nlm.Add([pscustomobject]@{
                Kind        = 'NLM service'
                Name        = $svc.Name
                Path        = $path
                VersionText = if ($vi) { $vi.VersionText } else { '' }
                Version     = if ($vi) { $vi.Version } else { $null }
                IsOld       = [bool]($vi -and $vi.IsOld)
            })
        }

        foreach ($p in @(Get-Process -Name 'lmgrd', 'adskflex' -ErrorAction SilentlyContinue)) {
            $path = $null
            try { $path = $p.Path } catch { }
            $vi = if ($path) { Get-NlmVersionInfo $path } else { $null }
            $key = ('process|' + $p.ProcessName + '|' + $p.Id).ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $nlm.Add([pscustomobject]@{
                Kind        = 'NLM process'
                Name        = $p.ProcessName
                Path        = $path
                VersionText = if ($vi) { $vi.VersionText } else { '' }
                Version     = if ($vi) { $vi.Version } else { $null }
                IsOld       = [bool]($vi -and $vi.IsOld)
            })
        }
    }

    $licSvc = Get-Service -Name 'AdskLicensingService' -ErrorAction SilentlyContinue
    $licState = 'Missing'
    if ($licSvc) { $licState = [string]$licSvc.Status }
    $licRunning = [bool]($licSvc -and $licSvc.Status -eq 'Running')

    $oldNlm = @($nlm | Where-Object { $_.IsOld })
    return [pscustomobject]@{
        Files                    = $files.ToArray()
        Registry                 = $regs.ToArray()
        Environment              = $envs.ToArray()
        Nlm                      = $nlm.ToArray()
        Count                    = $files.Count + $regs.Count + $envs.Count
        OldNlm                   = @($oldNlm)
        NetworkLikely            = [bool]($nlm.Count -gt 0 -or $envs.Count -gt 0 -or $regs.Count -gt 0)
        LicensingServiceState    = $licState
        LicensingServiceWasRunning = $licRunning
        MinimumVersion           = $script:NlmMinimumVersion.ToString()
        ProgramDataRoot          = $ProgramDataRoot
    }
}

function Backup-NlmScan {
    param(
        [Parameter(Mandatory = $true)]$Scan,
        [string]$BackupRoot
    )

    if (-not $BackupRoot) { $BackupRoot = Join-Path $env:ProgramData 'UNLOCK DIGITAL\backups' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeComputer = ($env:COMPUTERNAME -replace '[^\w.-]', '_')
    $dest = Join-Path $BackupRoot ('nlmfix_{0}_{1}_{2}' -f $safeComputer, $stamp, (Get-Random -Minimum 1000 -Maximum 9999))
    $filesDir = Join-Path $dest 'files'
    $regDir = Join-Path $dest 'registry'
    New-Item -ItemType Directory -Force -Path $filesDir | Out-Null
    New-Item -ItemType Directory -Force -Path $regDir | Out-Null

    $manifestFiles = @()
    $i = 0
    foreach ($f in @($Scan.Files)) {
        $i++
        $leaf = [IO.Path]::GetFileName([string]$f.Path)
        if (-not $leaf) { $leaf = 'file' }
        $safeLeaf = ($leaf -replace '[^\w.-]', '_')
        $backupName = '{0:D2}_{1}' -f $i, $safeLeaf
        $target = Join-Path $filesDir $backupName
        Copy-Item -LiteralPath $f.Path -Destination $target -Force -ErrorAction Stop
        $manifestFiles += [pscustomobject]@{
            Original = [string]$f.Path
            Backup   = $backupName
            Sha256   = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        }
    }

    $manifestRegistry = @()
    $i = 0
    foreach ($r in @($Scan.Registry)) {
        $i++
        $safeLabel = ($r.Label -replace '[^\w.-]', '_')
        $backupName = '{0:D2}_{1}.reg' -f $i, $safeLabel
        $target = Join-Path $regDir $backupName
        & reg.exe export $r.RegPath $target /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $target)) {
            throw ("Could not export registry key: " + $r.RegPath)
        }
        $manifestRegistry += [pscustomobject]@{
            Original = [string]$r.RegPath
            PsPath   = [string]$r.Path
            Backup   = ('registry\' + $backupName)
            Label    = [string]$r.Label
        }
    }

    $envGroups = @($Scan.Environment | Group-Object -Property Key)
    $i = 0
    foreach ($g in $envGroups) {
        $i++
        $first = @($g.Group)[0]
        $safeLabel = ($first.Label -replace '[^\w.-]', '_')
        $backupName = '{0:D2}_{1}.reg' -f $i, $safeLabel
        $target = Join-Path $regDir $backupName
        & reg.exe export $first.RegPath $target /y 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $target)) {
            throw ("Could not export registry key: " + $first.RegPath)
        }
        $manifestRegistry += [pscustomobject]@{
            Original = [string]$first.RegPath
            PsPath   = [string]$first.Key
            Backup   = ('registry\' + $backupName)
            Label    = [string]$first.Label
        }
    }

    $manifestEnv = @()
    foreach ($e in @($Scan.Environment)) {
        $manifestEnv += [pscustomobject]@{
            Name  = [string]$e.Name
            Value = [string]$e.Value
            Scope = [string]$e.Scope
            Key   = [string]$e.Key
        }
    }

    $manifestNlm = @()
    foreach ($n in @($Scan.Nlm)) {
        $manifestNlm += [pscustomobject]@{
            Kind        = [string]$n.Kind
            Name        = [string]$n.Name
            Path        = [string]$n.Path
            VersionText = [string]$n.VersionText
            IsOld       = [bool]$n.IsOld
        }
    }

    $manifest = [pscustomobject]@{
        Created           = (Get-Date).ToString('o')
        Computer          = $env:COMPUTERNAME
        MinimumVersion    = [string]$Scan.MinimumVersion
        ServiceWasRunning = [bool]$Scan.LicensingServiceWasRunning
        Files             = @($manifestFiles)
        Registry          = @($manifestRegistry)
        Environment       = @($manifestEnv)
        Nlm               = @($manifestNlm)
    }
    $manifestPath = Join-Path $dest 'manifest.json'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    $undo = @'
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $here 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw 'manifest.json is missing' }
$m = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json

foreach ($f in @($m.Files)) {
    if ($null -eq $f) { continue }
    $src = Join-Path $here ('files\' + [string]$f.Backup)
    if (-not (Test-Path -LiteralPath $src)) { continue }
    $parent = Split-Path -Parent ([string]$f.Original)
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    Copy-Item -LiteralPath $src -Destination ([string]$f.Original) -Force
}

foreach ($r in @($m.Registry)) {
    if ($null -eq $r) { continue }
    $src = Join-Path $here ([string]$r.Backup)
    if (-not (Test-Path -LiteralPath $src)) { continue }
    & reg.exe import $src | Out-Null
    if ($LASTEXITCODE -ne 0) { throw ('reg import failed: ' + $src) }
}

foreach ($e in @($m.Environment)) {
    if ($null -eq $e) { continue }
    [Environment]::SetEnvironmentVariable([string]$e.Name, [string]$e.Value, [string]$e.Scope)
}

if ($m.ServiceWasRunning) {
    Start-Service 'AdskLicensingService' -ErrorAction SilentlyContinue
}

Write-Host 'NLM pointer backup restored.'
'@
    Set-Content -LiteralPath (Join-Path $dest 'UNDO.ps1') -Value $undo -Encoding UTF8

    return $dest
}

function Clear-NlmScan {
    param(
        [Parameter(Mandatory = $true)]$Scan,
        [switch]$SkipService,
        [switch]$NoServiceRestart
    )

    $removed = 0
    $errors = New-Object System.Collections.Generic.List[string]
    $wasRunning = $false

    if (-not $SkipService) {
        $svc = Get-Service -Name 'AdskLicensingService' -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            try {
                Stop-Service -Name 'AdskLicensingService' -Force -ErrorAction Stop
                $wasRunning = $true
            } catch {
                $errors.Add('Could not stop AdskLicensingService: ' + $_.Exception.Message)
            }
        }
    }

    foreach ($f in @($Scan.Files)) {
        try {
            Remove-Item -LiteralPath $f.Path -Force -ErrorAction Stop
            $removed++
        } catch {
            $errors.Add(('Could not remove {0}: {1}' -f $f.Path, $_.Exception.Message))
        }
    }

    foreach ($r in @($Scan.Registry)) {
        try {
            Remove-Item -LiteralPath $r.Path -Recurse -Force -ErrorAction Stop
            $removed++
        } catch {
            $errors.Add(('Could not remove registry key {0}: {1}' -f $r.RegPath, $_.Exception.Message))
        }
    }

    foreach ($e in @($Scan.Environment)) {
        $ok = $false
        try {
            Remove-ItemProperty -LiteralPath $e.Key -Name $e.Name -Force -ErrorAction Stop
            $ok = $true
        } catch { }
        try {
            [Environment]::SetEnvironmentVariable($e.Name, $null, $e.Scope)
            $ok = $true
        } catch { }
        if ($ok) { $removed++ }
        else { $errors.Add(('Could not remove environment variable {0} ({1})' -f $e.Name, $e.Scope)) }
    }

    if ($wasRunning -and -not $NoServiceRestart -and -not $SkipService) {
        try { Start-Service -Name 'AdskLicensingService' -ErrorAction Stop }
        catch { $errors.Add('Could not restart AdskLicensingService: ' + $_.Exception.Message) }
    }

    return [pscustomobject]@{
        Removed            = $removed
        Errors             = @($errors)
        ServiceWasRunning  = $wasRunning
    }
}

function Invoke-NlmBlockerFix {
    param(
        [switch]$Apply,
        [switch]$SkipBackup,
        [string]$BackupRoot,
        [switch]$KeepNetworkSettings,
        [switch]$NoServiceRestart,
        [string]$ProgramDataRoot = $env:ProgramData,
        [switch]$SkipRegistry,
        [switch]$SkipEnvironment,
        [switch]$SkipService,
        [switch]$NoHeader
    )

    $scanArgs = @{
        ProgramDataRoot = $ProgramDataRoot
        SkipRegistry    = $SkipRegistry
        SkipEnvironment = $SkipEnvironment
        SkipService     = $SkipService
    }
    $scan = Get-NlmInstallBlockers @scanArgs
    $initialCount = [int]$scan.Count
    $initialOld = @($scan.OldNlm).Count
    $initialNetwork = [bool]$scan.NetworkLikely

    Write-Host ''
    if (-not $NoHeader) {
        Write-Host '== AutoCAD 2027 NLM installer blocker ==' -ForegroundColor Cyan
    }
    Write-Host ('   Minimum NLM : {0}' -f $scan.MinimumVersion)
    Write-Host ('   Stale pointers: {0}' -f $scan.Count)
    Write-Host ('   Licensing service: {0}' -f $scan.LicensingServiceState)

    foreach ($n in @($scan.OldNlm)) {
        $where = if ($n.Path) { $n.Path } else { $n.Name }
        Write-Host ('  [warn] NLM {0} at {1} is older than {2}' -f $n.VersionText, $where, $scan.MinimumVersion) -ForegroundColor Yellow
    }
    if ($scan.NetworkLikely) {
        Write-Host '  [warn] Network licensing was detected. This clears stale local pointers; it does not update a license server.' -ForegroundColor Yellow
        Write-Host '         If this PC is the license server, update NLM to 11.19.9.0+ instead.' -ForegroundColor Yellow
    }

    if ($KeepNetworkSettings) {
        Write-Host '  Keeping registry and environment network settings; clearing only stale files.' -ForegroundColor Yellow
        $scan.Registry = @()
        $scan.Environment = @()
        $scan.Count = @($scan.Files).Count
    }

    foreach ($f in @($scan.Files)) {
        $tag = if ($Apply) { '[remove]' } else { '[preview]' }
        Write-Host ('  {0} stale file: {1}' -f $tag, $f.Path)
    }
    foreach ($r in @($scan.Registry)) {
        $tag = if ($Apply) { '[remove]' } else { '[preview]' }
        Write-Host ('  {0} stale registry key: {1}' -f $tag, $r.RegPath)
    }
    foreach ($e in @($scan.Environment)) {
        $tag = if ($Apply) { '[remove]' } else { '[preview]' }
        Write-Host ('  {0} stale environment variable: {1} ({2})' -f $tag, $e.Name, $e.Scope)
    }

    if ($scan.Count -eq 0) {
        Write-Host '  No stale NLM pointers to remove.' -ForegroundColor Green
        if ($initialOld -gt 0) {
            Write-Host '  The installed NLM is old: update it to 11.19.9.0+ before installing AutoCAD 2027.' -ForegroundColor Yellow
        }
        return [pscustomobject]@{
            InitialCount   = $initialCount
            InitialOld     = $initialOld
            InitialNetwork = $initialNetwork
            Applied        = 0
            Remaining      = 0
            Backup         = $null
            Errors         = @()
            RemainingScan  = $scan
        }
    }

    if (-not $Apply) {
        Write-Host '  Preview only. Run with -Apply (or Repair) to back up and clear these pointers.' -ForegroundColor DarkGray
        return [pscustomobject]@{
            InitialCount   = $initialCount
            InitialOld     = $initialOld
            InitialNetwork = $initialNetwork
            Applied        = 0
            Remaining      = $initialCount
            Backup         = $null
            Errors         = @()
            RemainingScan  = $scan
        }
    }

    $needsAdmin = -not ($SkipRegistry -and $SkipEnvironment -and $SkipService)
    if ($needsAdmin -and -not (Test-NlmAdmin)) {
        Write-Host '  [FAIL] -Apply needs an administrator shell.' -ForegroundColor Red
        return [pscustomobject]@{
            InitialCount   = $initialCount
            InitialOld     = $initialOld
            InitialNetwork = $initialNetwork
            Applied        = 0
            Remaining      = $initialCount
            Backup         = $null
            Errors         = @('Apply needs an administrator shell')
            RemainingScan  = $scan
        }
    }

    $backup = $null
    if (-not $SkipBackup) {
        try {
            $backup = Backup-NlmScan -Scan $scan -BackupRoot $BackupRoot
            Write-Host ('  Backup: {0}' -f $backup) -ForegroundColor Green
        } catch {
            $message = 'Backup failed; nothing was removed: ' + $_.Exception.Message
            Write-Host ('  [FAIL] ' + $message) -ForegroundColor Red
            return [pscustomobject]@{
                InitialCount   = $initialCount
                InitialOld     = $initialOld
                InitialNetwork = $initialNetwork
                Applied        = 0
                Remaining      = $initialCount
                Backup         = $null
                Errors         = @($message)
                RemainingScan  = $scan
            }
        }
    } else {
        Write-Host '  [warn] -SkipBackup was used. No undo copy was made.' -ForegroundColor Yellow
    }

    $clear = Clear-NlmScan -Scan $scan -SkipService:$SkipService -NoServiceRestart:$NoServiceRestart
    $afterSkipRegistry = [bool]($SkipRegistry -or $KeepNetworkSettings)
    $afterSkipEnvironment = [bool]($SkipEnvironment -or $KeepNetworkSettings)
    $after = Get-NlmInstallBlockers -ProgramDataRoot $ProgramDataRoot `
        -SkipRegistry:$afterSkipRegistry -SkipEnvironment:$afterSkipEnvironment -SkipService:$SkipService
    $errors = @($clear.Errors)

    foreach ($e in $errors) { Write-Host ('  [FAIL] ' + $e) -ForegroundColor Red }
    Write-Host ('  Removed {0} item(s); {1} stale pointer(s) remain.' -f $clear.Removed, $after.Count) -ForegroundColor $(if ($after.Count -eq 0) { 'Green' } else { 'Yellow' })
    if ($after.Count -eq 0) {
        Write-Host '  Restart Windows, then run the AutoCAD 2027 setup again.' -ForegroundColor Green
    }

    return [pscustomobject]@{
        InitialCount   = $initialCount
        InitialOld     = $initialOld
        InitialNetwork = $initialNetwork
        Applied        = [int]$clear.Removed
        Remaining      = [int]$after.Count
        Backup         = $backup
        Errors         = $errors
        RemainingScan  = $after
    }
}
