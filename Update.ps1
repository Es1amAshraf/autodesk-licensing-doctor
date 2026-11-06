<#
    Update.ps1  -  UNLOCK DIGITAL  -  Autodesk Licensing Doctor
    ---------------------------------------------------------------------------
    Checks for the latest official release and, on request, stages it so the
    running copy can be replaced in place (the GUI "Update tool" button uses
    exactly this script).

    Nothing is downloaded except the small manifest/API response unless
    -Download is passed (or the GUI button is used and confirmed). The release
    archive itself is fetched only in -Download mode. Two sources are supported:

      1. update-config.json next to this script, or
         %ProgramData%\UNLOCK DIGITAL\update-config.json:

             { "manifestUrl":  "https://example.com/adskdoctor/update.json" }
             { "manifestPath": "\\\\server\\share\\adskdoctor\\update.json" }

         The manifest is a small JSON file:

             { "version":      "1.5.5",
               "portableUrl":  "AdskDoctor-v1.5.5-Portable.zip",
               "sha256":       "....",
               "downloadPage": "https://example.com/adskdoctor/" }

         portableUrl / sha256Url may be absolute HTTPS URLs, absolute local
         paths, UNC paths, or paths relative to the manifest. A manifest may
         carry the archive hash directly (sha256) or point at SHA256SUMS.txt
         (sha256Url). At least one of them is required.

      2. The fixed GitHub repository's releases/latest feed (the default when
         no manifest is configured). The repository can be overridden with
         "githubRepo" in update-config.json.

    The archive must match the published SHA256 before it is extracted. The
    only URLs used for the archive are the ones in the selected source.

    Modes (default = -Check):
      -Check      print one machine-readable line:
                    UPDATERESULT current=.. latest=.. available=0|1 source=..
      -Download   fetch the latest Portable zip + SHA256SUMS.txt, verify the
                  checksum, extract to %ProgramData%\UNLOCK DIGITAL\update and
                  write apply-update.ps1 (waits for the caller to exit, copies
                  the files over the app folder, relaunches the app):
                    UPDATERESULT staged=<dir> version=.. apply=..

    Errors are reported on the same single line:  UPDATERESULT error=<message>
    Exit codes: 0 = ok, 2 = error.
#>
[CmdletBinding()]
param(
    # Version to compare against. The GUI passes its own; a CLI run falls back
    # to the FileVersion of UNLOCK-DIGITAL-AdskDoctor.exe next to this script.
    [string]$CurrentVersion = '',

    [switch]$Check,
    [switch]$Download,

    # Optional overrides, mainly for testing and for a one-off run.
    [string]$ManifestUrl = '',
    [string]$ManifestPath = ''
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$repo    = 'Es1amAshraf/autodesk-licensing-doctor'
$updRoot = $env:ADSKDOCTOR_UPDATEDIR
if (-not $updRoot) { $updRoot = Join-Path $env:ProgramData 'UNLOCK DIGITAL\update' }

function Protect-DirectoryAcl {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    # Only harden shared system locations under ProgramData when running elevated
    if (-not $env:ProgramData -or -not $Path.StartsWith($env:ProgramData, [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if (-not $isAdmin) { return }

        $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
        if (Test-Path -LiteralPath $icacls) {
            # Strip inherited write perms from unprivileged users; grant Full Control
            # only to Administrators (S-1-5-32-544) and SYSTEM (S-1-5-18), Read to Users (S-1-5-32-545)
            & $icacls $Path /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" >$null 2>&1
        }
    } catch {}
}

function Say { param([string]$m) Write-Host ('  ' + $m) }
function Fail {
    param([string]$m)
    Write-Host ('UPDATERESULT error=' + ($m -replace '[\r\n]+', ' '))
    exit 2
}

function Test-WebLocation {
    param([string]$Location)
    return ($Location -match '^https://')
}

function Resolve-Location {
    param([string]$Location, [string]$Base)
    if (-not $Location) { return '' }
    if (Test-WebLocation $Location) { return $Location }
    if ([System.IO.Path]::IsPathRooted($Location)) { return $Location }

    if ($Base -and (Test-WebLocation $Base)) {
        try { return ([uri]::new([uri]$Base, $Location)).AbsoluteUri } catch {}
    }
    $dir = ''
    if ($Base) { $dir = Split-Path -Parent $Base }
    if (-not $dir) { $dir = (Get-Location).Path }
    return (Join-Path $dir $Location)
}

function Read-JsonLocation {
    param([string]$Location)
    if (-not $Location) { throw 'empty update manifest location' }

    $text = ''
    if (Test-WebLocation $Location) {
        $resp = Invoke-WebRequest -Uri $Location -UseBasicParsing -TimeoutSec 30 -Headers @{
            'User-Agent' = 'UNLOCK-DIGITAL-AdskDoctor-Updater'
            'Accept'     = 'application/json'
        }
        # Decode as UTF-8 ourselves: some static hosts serve JSON without a
        # charset and Windows PowerShell may fall back to the ANSI code page.
        # A UTF-8 BOM is also common on files written by Windows PowerShell;
        # ConvertFrom-Json rejects it, so strip it before parsing.
        if ($resp.RawContentStream) {
            $resp.RawContentStream.Position = 0
            $text = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        } else {
            $text = [string]$resp.Content
        }
    } else {
        if (-not (Test-Path -LiteralPath $Location)) {
            throw ('update manifest not found: ' + $Location)
        }
        $text = Get-Content -LiteralPath $Location -Raw -ErrorAction Stop
    }
    $text = ([string]$text).TrimStart([char]0xFEFF)
    return ($text | ConvertFrom-Json)
}

function Save-Location {
    param([string]$Location, [string]$Destination, [int]$TimeoutSec = 300)
    if (Test-WebLocation $Location) {
        Invoke-WebRequest -Uri $Location -OutFile $Destination -UseBasicParsing -TimeoutSec $TimeoutSec -Headers @{
            'User-Agent' = 'UNLOCK-DIGITAL-AdskDoctor-Updater'
        }
        return
    }
    if (Test-Path -LiteralPath $Location) {
        Copy-Item -LiteralPath $Location -Destination $Destination -Force -ErrorAction Stop
        return
    }
    throw ('file not found: ' + $Location)
}

function Read-UpdateConfig {
    $candidates = @()
    if ($env:ADSKDOCTOR_UPDATE_CONFIG) { $candidates += $env:ADSKDOCTOR_UPDATE_CONFIG }
    $candidates += (Join-Path $PSScriptRoot 'update-config.json')
    if ($env:ProgramData) { $candidates += (Join-Path $env:ProgramData 'UNLOCK DIGITAL\update-config.json') }

    foreach ($c in $candidates) {
        if (-not $c) { continue }
        if (-not (Test-Path -LiteralPath $c)) { continue }
        try {
            $cfg = Get-Content -LiteralPath $c -Raw -ErrorAction Stop | ConvertFrom-Json
            return $cfg
        } catch {
            Fail ('cannot read update config ' + $c + ': ' + $_.Exception.Message)
        }
    }
    return $null
}

function Get-ManifestRelease {
    param([string]$Location)
    $man = Read-JsonLocation -Location $Location
    if (-not $man) { throw 'empty update manifest' }

    $rawVersion = [string]$man.version
    if ($rawVersion -notmatch '^v?(\d+\.\d+\.\d+)$') {
        throw ('unexpected manifest version: ' + $rawVersion)
    }
    $ver = [version]$Matches[1]

    $zip = ''
    foreach ($k in @('portableUrl', 'portable', 'zipUrl', 'url')) {
        if (-not $zip -and $man.$k) { $zip = [string]$man.$k }
    }
    if (-not $zip) { throw 'the update manifest has no portableUrl' }
    $zip = Resolve-Location -Location $zip -Base $Location

    $sums = ''
    foreach ($k in @('sha256Url', 'sumsUrl', 'SHA256SUMS')) {
        if (-not $sums -and $man.$k) { $sums = [string]$man.$k }
    }
    if ($sums) { $sums = Resolve-Location -Location $sums -Base $Location }

    $sha = ''
    if ($man.sha256) { $sha = ([string]$man.sha256).Trim() }
    if (-not $sha -and -not $sums) {
        throw 'the update manifest needs sha256 or sha256Url'
    }

    $page = ''
    if ($man.downloadPage) { $page = [string]$man.downloadPage }

    return [pscustomobject]@{
        Version      = $ver
        ZipLocation  = $zip
        SumsLocation = $sums
        Sha256       = $sha
        PageUrl      = $page
        Source       = 'manifest'
    }
}

function Get-GitHubRelease {
    param([string]$Repository)
    if (-not $Repository) { $Repository = $repo }
    $api = 'https://api.github.com/repos/' + $Repository + '/releases/latest'
    try {
        $rel = Invoke-RestMethod -Uri $api -TimeoutSec 30 -Headers @{
            'User-Agent' = 'UNLOCK-DIGITAL-AdskDoctor-Updater'
            'Accept'     = 'application/vnd.github+json'
        }
    } catch {
        $status = ''
        try { $status = [string]([int]$_.Exception.Response.StatusCode) } catch {}
        if ($status -eq '404') {
            throw ('GitHub release feed returned 404 (repository unavailable or suspended)')
        }
        if ($status -eq '403') {
            throw ('GitHub release feed returned 403 (rate limit or access denied)')
        }
        throw ('cannot reach GitHub: ' + $_.Exception.Message)
    }

    $tag = [string]$rel.tag_name
    if ($tag -notmatch '^v(\d+\.\d+\.\d+)$') { throw ('unexpected release tag: ' + $tag) }
    $ver = [version]$Matches[1]

    $zip = ''; $sums = ''
    foreach ($a in @($rel.assets)) {
        $n = [string]$a.name
        if ($n -match '^AdskDoctor-v[\d.]+-Portable\.zip$') { $zip  = [string]$a.browser_download_url }
        elseif ($n -eq 'SHA256SUMS.txt')                       { $sums = [string]$a.browser_download_url }
    }
    if (-not $zip -or -not $sums) {
        throw 'the release is missing its Portable zip / SHA256SUMS.txt assets'
    }

    $page = [string]$rel.html_url
    if (-not $page) { $page = 'https://github.com/' + $Repository + '/releases/tag/' + $tag }

    return [pscustomobject]@{
        Version      = $ver
        ZipLocation  = $zip
        SumsLocation = $sums
        Sha256       = ''
        PageUrl      = $page
        Source       = 'github'
    }
}

# --- which version are we updating FROM --------------------------------------
if (-not $CurrentVersion) {
    $exe = Join-Path $PSScriptRoot 'UNLOCK-DIGITAL-AdskDoctor.exe'
    if (Test-Path -LiteralPath $exe) {
        try { $CurrentVersion = [string](Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch {}
    }
}
$cur        = [version]'0.0.0'
$curDisplay = 'dev'
if ($CurrentVersion -match '^\d+(\.\d+){1,3}$') {
    try {
        $raw = [version]$CurrentVersion
        # The compiled exe has a four-part FileVersion (1.5.2.0) while release
        # tags have three parts (1.5.2). Compare three parts so an up-to-date
        # install is not reported as older than its own release.
        $cur = [version]($raw.Major.ToString() + '.' + $raw.Minor.ToString() + '.' +
                          ([math]::Max($raw.Build, 0)).ToString())
        $curDisplay = $cur.ToString(3)
    } catch {}
}

# --- configuration ------------------------------------------------------------
$config = Read-UpdateConfig
$manifestLocation = ''
if ($ManifestUrl)       { $manifestLocation = $ManifestUrl }
elseif ($ManifestPath)  { $manifestLocation = $ManifestPath }
elseif ($config) {
    if ($config.manifestUrl)  { $manifestLocation = [string]$config.manifestUrl }
    elseif ($config.manifestPath) { $manifestLocation = [string]$config.manifestPath }
}

$githubRepo = $repo
if ($config -and $config.githubRepo) { $githubRepo = [string]$config.githubRepo }

$downloadPage = ''
if ($config -and $config.downloadPage) { $downloadPage = [string]$config.downloadPage }

# --- resolve the release ------------------------------------------------------
$release = $null
$errors  = @()

if ($manifestLocation) {
    try {
        $release = Get-ManifestRelease -Location $manifestLocation
    } catch {
        $errors += ('manifest: ' + $_.Exception.Message)
    }
}
if (-not $release) {
    try {
        $release = Get-GitHubRelease -Repository $githubRepo
    } catch {
        $errors += ('github: ' + $_.Exception.Message)
    }
}
if (-not $release) {
    $msg = ($errors -join ' | ')
    $msg += '. Configure update-config.json (manifestUrl or manifestPath) or download the latest release manually'
    if ($downloadPage) { $msg += ': ' + $downloadPage }
    Fail $msg
}
if ($errors.Count) { Say ('warning: ' + ($errors -join ' | ')) }
if (-not $downloadPage -and $release.PageUrl) { $downloadPage = $release.PageUrl }

$latest = $release.Version
$latest = [version]($latest.Major.ToString() + '.' + $latest.Minor.ToString() + '.' + $latest.Build.ToString())

Say ('source:  ' + $release.Source)
Say ('current: v' + $curDisplay)
Say ('latest:  v' + $latest)
$available = ($latest -gt $cur)

if (-not $Download) {
    if ($available) { Say 'a newer release is available' } else { Say 'you are on the latest release' }
    Write-Host ('UPDATERESULT current=' + $curDisplay + ' latest=' + $latest +
                ' available=' + [int]$available + ' source=' + $release.Source)
    exit 0
}

if (-not $available) {
    Write-Host ('UPDATERESULT current=' + $curDisplay + ' latest=' + $latest +
                ' available=0 source=' + $release.Source)
    exit 0
}

if (-not $release.ZipLocation) { Fail 'the update source has no Portable zip' }
if (-not $release.Sha256 -and -not $release.SumsLocation) {
    Fail 'the update source has no SHA256 (sha256 or sha256Url)'
}

# --- download to a private folder ---------------------------------------------
$dlDir = Join-Path $updRoot 'downloads'
New-Item -ItemType Directory -Force -Path $dlDir | Out-Null
Protect-DirectoryAcl -Path $updRoot
Protect-DirectoryAcl -Path $dlDir
$zipName  = 'AdskDoctor-v' + $latest + '-Portable.zip'
$zipPath  = Join-Path $dlDir $zipName
$sumsPath = Join-Path $dlDir 'SHA256SUMS.txt'

try {
    Say ('downloading ' + $zipName)
    Save-Location -Location $release.ZipLocation -Destination $zipPath -TimeoutSec 300
} catch {
    Fail ('download failed: ' + $_.Exception.Message)
}

# --- checksum gate -------------------------------------------------------------
$expected = ''
if ($release.Sha256) {
    $expected = $release.Sha256
    if ($expected -notmatch '^[0-9A-Fa-f]{64}$') {
        Fail ('the manifest sha256 is not a SHA256: ' + $expected)
    }
} else {
    try {
        Say 'downloading SHA256SUMS.txt'
        Save-Location -Location $release.SumsLocation -Destination $sumsPath -TimeoutSec 60
    } catch {
        Fail ('download failed: ' + $_.Exception.Message)
    }
    foreach ($line in @(Get-Content -LiteralPath $sumsPath -ErrorAction SilentlyContinue)) {
        $s = ([string]$line).Trim()
        if ($s -match ('^([0-9A-Fa-f]{64})\s+\*?' + [regex]::Escape($zipName) + '$')) {
            $expected = $Matches[1]; break
        }
    }
    if (-not $expected) { Fail ('SHA256SUMS.txt has no entry for ' + $zipName) }
}
$actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
if ($actual -ne $expected) {
    Fail ('SHA256 mismatch for ' + $zipName + ' (expected ' + $expected + ', got ' + $actual + ')')
}
Say ('SHA256 ok: ' + $actual)

# --- extract + layout check -----------------------------------------------------
$stage = Join-Path $updRoot ('staging\v' + $latest)
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Protect-DirectoryAcl -Path $stage
Add-Type -AssemblyName System.IO.Compression.FileSystem
try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    foreach ($e in $zip.Entries) {
        if ($e.FullName -match '(^|[\\/])\.\.($|[\\/])' -or $e.FullName -match '^[\\/]') {
            throw ('unsafe archive entry: ' + $e.FullName)
        }
    }
    $zip.Dispose()
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $stage)
} catch {
    Fail ('extract failed: ' + $_.Exception.Message)
}
$exeName = 'UNLOCK-DIGITAL-AdskDoctor.exe'
if (-not (Test-Path -LiteralPath (Join-Path $stage $exeName))) {
    Fail 'the archive does not contain the app (unexpected layout)'
}

# --- hand-off script: runs after the app exits, copies, relaunches --------------
$apply = Join-Path $updRoot 'apply-update.ps1'
$applyBody = @'
<#
    apply-update.ps1  -  generated by Update.ps1 (UNLOCK DIGITAL - Autodesk Licensing Doctor)
    Waits for the running app to exit, copies the staged files over the app
    folder and relaunches the app. Runs hidden; progress goes to apply.log.
#>
param(
    [Parameter(Mandatory=$true)][int]$WaitPid,
    [Parameter(Mandatory=$true)][string]$StagingDir,
    [Parameter(Mandatory=$true)][string]$TargetDir,
    [Parameter(Mandatory=$true)][string]$ExeName
)
$ErrorActionPreference = 'Continue'

$logDir = Join-Path $env:ProgramData 'UNLOCK DIGITAL\update'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log = Join-Path $logDir 'apply.log'
function Log {
    param([string]$m)
    try { Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $m) } catch {}
}

Log ('apply-update started: waitpid=' + $WaitPid + ' staging=' + $StagingDir + ' target=' + $TargetDir)
try { Wait-Process -Id $WaitPid -Timeout 300 -ErrorAction Stop } catch { Log ('wait: ' + $_.Exception.Message) }
Start-Sleep -Seconds 3

if (-not (Test-Path -LiteralPath (Join-Path $StagingDir $ExeName))) { Log 'staging exe missing - abort'; exit 1 }

$ok = 0; $failed = 0
foreach ($f in @(Get-ChildItem -LiteralPath $StagingDir -Recurse -File -Force)) {
    $rel = $f.FullName.Substring($StagingDir.Length).TrimStart('\')
    $dst = Join-Path $TargetDir $rel
    $dir = Split-Path -Parent $dst
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $done = $false
    for ($i = 1; $i -le 5 -and -not $done; $i++) {
        try { Copy-Item -LiteralPath $f.FullName -Destination $dst -Force -ErrorAction Stop; $done = $true }
        catch { Start-Sleep -Seconds 2 }
    }
    if ($done) { $ok++ } else { $failed++; Log ('  FAILED ' + $rel) }
}
Log ('copied ' + $ok + ' file(s), failed ' + $failed)

$exe = Join-Path $TargetDir $ExeName
if (Test-Path -LiteralPath $exe) {
    try { Start-Process -FilePath $exe; Log 'relaunched the app' } catch { Log ('relaunch failed: ' + $_.Exception.Message) }
} else {
    Log 'target exe missing after copy'
}
Log 'apply-update finished'
'@
$enc = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($apply, $applyBody, $enc)
Protect-DirectoryAcl -Path $apply

Say ('staged in ' + $stage)
Write-Host ('UPDATERESULT staged=' + $stage + ' version=' + $latest + ' apply=' + $apply + ' source=' + $release.Source)
exit 0
