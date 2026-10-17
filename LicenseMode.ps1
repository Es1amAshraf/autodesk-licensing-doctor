<#
    LicenseMode.ps1  -  License mode: list products, switch the licensing type
    ---------------------------------------------------------------------------
    Part of UNLOCK DIGITAL - Autodesk Licensing Doctor.

    This is the fix for "the product opens on the license server screen while
    the customer has a single-user (sign-in) subscription": the registered
    license method of that product is switched back to USER.

    It drives the official Autodesk Licensing Installer Helper that ships with
    every 2020+ product (AdskLicensingInstHelper.exe):

        list    - every product registered with the licensing service and its
                  current license method
        change  - switch one product between:
                    USER        single-user sign-in (subscription)
                    NETWORK     multi-user network (NLM / license server)
                    STANDALONE  legacy serial
                    RESET       no method registered; the product asks the
                                user to choose at the next launch

    Preview by default; add -Apply to make the change. It never downloads
    anything.

    Usage:
      .\LicenseMode.ps1 -List
      .\LicenseMode.ps1 -List -Json
      .\LicenseMode.ps1 -ProductKey 001Q1 -ProductVersion 2025.0.0.F -LicenseType USER
      .\LicenseMode.ps1 -ProductKey 001Q1 -ProductVersion 2025.0.0.F -LicenseType USER -Apply
      .\LicenseMode.ps1 -ProductKey 829Q1 -ProductVersion 2025.0.0.F -LicenseType NETWORK `
                        -LicServers "@10.0.0.5" -Apply
      .\LicenseMode.ps1 -ProductKey 001Q1 -ProductVersion 2025.0.0.F -LicenseType RESET -Apply
#>

[CmdletBinding()]
param(
    [switch]$List,
    [switch]$Json,
    [string]$ProductKey,
    [string]$ProductVersion,
    [ValidateSet('USER','NETWORK','STANDALONE','RESET')]
    [string]$LicenseType,
    [ValidateSet('SINGLE','REDUNDANT','DISTRIBUTED')]
    [string]$LicServerType,
    [string]$LicServers,
    [switch]$Apply,
    [switch]$NoProcessStop,   # never touch a running process (used by the test suite)
    [string]$HelperPath       # explicit AdskLicensingInstHelper path (tests / advanced)
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$script:Apply    = [bool]$Apply
$script:ListMode = [bool]($List -or $Json)
$script:Errors   = 0

# ---------------------------------------------------------------------------
# Operation log: every switch run (preview or apply) lands in
# %ProgramData%\UNLOCK DIGITAL\logs (or the folder in ADSKDOCTOR_LOGDIR) so a
# support request can carry it. A plain product listing is read-only and does
# not write one. ADSKDOCTOR_NOLOG=1 turns logging off (the test suite sets it).
# ---------------------------------------------------------------------------
$script:LogPath = $null
if (-not $script:ListMode -and -not $env:ADSKDOCTOR_NOLOG) {
    try {
        $logRoot = if ($env:ADSKDOCTOR_LOGDIR) { $env:ADSKDOCTOR_LOGDIR } else { Join-Path $env:ProgramData 'UNLOCK DIGITAL\logs' }
        New-Item -ItemType Directory -Force -Path $logRoot | Out-Null
        $script:LogPath = Join-Path $logRoot ('licensemode-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Start-Transcript -LiteralPath $script:LogPath -Force | Out-Null
    } catch { $script:LogPath = $null }
}

# ---------------------------------------------------------------------------
# Product names by the three-character product-key prefix (Autodesk's published
# product key tables). Everything is offline; an unknown prefix is shown as-is
# and never guessed.
# ---------------------------------------------------------------------------
$script:ProductNames = @{
    '001' = 'AutoCAD';                    '057' = 'AutoCAD LT'
    '129' = 'AutoCAD Map 3D';             '185' = 'AutoCAD Architecture'
    '206' = 'AutoCAD Mechanical';         '225' = 'AutoCAD Electrical'
    '235' = 'AutoCAD MEP';                '240' = 'AutoCAD Revit Architecture Suite'
    '256' = 'AutoCAD Revit Structure Suite'; '262' = 'Showcase'
    '340' = 'AutoCAD Raster Design';      '426' = 'AutoCAD Plant 3D'
    '448' = 'AutoCAD P&ID';               '545' = 'AutoCAD LT Civil Suite'
    '547' = 'Robot Structural Analysis Professional'
    '555' = 'Vault Office';               '559' = 'Vault Workgroup'
    '569' = 'Vault Professional';         '571' = 'Moldflow Adviser Premium'
    '572' = 'Moldflow Adviser Ultimate';  '573' = 'Moldflow Insight Standard'
    '574' = 'Moldflow Insight Premium';   '575' = 'Moldflow Insight Ultimate'
    '579' = 'Moldflow Synergy';           '596' = 'AutoCAD Inventor LT Suite'
    '657' = 'Maya';                       '712' = 'Alias Design'
    '727' = 'MotionBuilder';              '736' = 'Alias Surface'
    '752' = 'Inventor Engineer-to-Order Server'
    '760' = 'Factory Design Suite Ultimate'
    '763' = 'Plant Design Suite Premium'; '764' = 'Plant Design Suite Ultimate'
    '765' = 'Building Design Suite Premium'
    '766' = 'Building Design Suite Ultimate'
    '785' = 'Infrastructure Design Suite Ultimate'
    '797' = 'Inventor Professional';      '798' = 'Inventor OEM'
    '805' = 'Inventor Engineer-to-Order Series'
    '810' = 'CFD Premium';                '811' = 'CFD Ultimate'
    '812' = 'CFD Design Study Environment'
    '828' = 'Revit LT';                   '829' = 'Revit'
    '834' = 'AutoCAD Revit LT Suite';     '837' = 'Moldflow Design'
    '839' = 'Fabrication CADmep';         '841' = 'Fabrication ESTmep'
    '842' = 'Fabrication CAMduct';        '871' = 'SketchBook'
    '872' = 'HSMWorks Ultimate';          '873' = 'HSMWorks Premium'
    '884' = 'VRED';                       '885' = 'VRED Design'
    '886' = 'VRED Professional';          '887' = 'VRED Server'
    '888' = 'VRED Presenter';             '890' = 'VRED Render Node'
    '919' = 'ReCap Pro';                  '925' = 'Point Layout'
    '927' = 'InfraWorks';                 '955' = 'Vehicle Tracking'
    '959' = 'Advance Steel';              '966' = 'Alias AutoStudio'
    '969' = 'Inventor HSM Premium';       '970' = 'Inventor HSM Ultimate'
    '977' = 'Maya with Softimage';        '978' = '3ds Max with Softimage'
    '986' = 'Nastran';                    '987' = 'Nastran In-CAD'
    '996' = 'Inventor Engineer-to-Order Distribution'
    'A62' = 'Alias SpeedForm';            'A63' = 'Alias Concept'
    'A9A' = 'PowerMill Premium';          'A9E' = 'FeatureCAM Ultimate'
    'A9F' = 'FeatureCAM Premium';         'A9G' = 'FeatureCAM Standard'
    'A9H' = 'PowerInspect Ultimate';      'A9J' = 'PowerInspect Premium'
    'A9L' = 'PowerShape Ultimate';        'A9M' = 'PowerShape Premium'
    'A9N' = 'PowerShape Standard';        'A9P' = 'PowerMill Ultimate'
    'A9Q' = 'PowerMill Standard';         'C0T' = 'Flame'
    'C0U' = 'Lustre';                     'C0X' = 'Flame Premium'
    'C12' = 'HSM Premium';                'C13' = 'HSM Ultimate'
    '128' = '3ds Max';                    '208' = 'Inventor'
    '237' = 'Civil 3D';                   '498' = 'Mudbox'
    '506' = 'Navisworks Simulate';        '507' = 'Navisworks Manage'
    '529' = 'Inventor LT'
}

# The year letter inside a product key: 001L1 = AutoCAD 2020 ... 001R1 = 2026.
$script:YearLetters = @{
    'I' = 2017; 'J' = 2018; 'K' = 2019; 'L' = 2020; 'M' = 2021; 'N' = 2022
    'O' = 2023; 'P' = 2024; 'Q' = 2025; 'R' = 2026; 'S' = 2027
}

# ---------------------------------------------------------------------------
# Output helpers (same style as the other phase scripts)
# ---------------------------------------------------------------------------
function Section  { param([string]$t) Write-Host ''; Write-Host ("== {0} ==" -f $t) -ForegroundColor Cyan }
function Info     { param([string]$t) Write-Host ("  " + $t) -ForegroundColor DarkGray }
function Warn-Line { param([string]$t) Write-Host ("  " + $t) -ForegroundColor Yellow }
function Step {
    param([string]$Desc, [scriptblock]$Do)
    if ($script:Apply) {
        try { & $Do; Write-Host ("  [ done ] {0}" -f $Desc) -ForegroundColor Green }
        catch { Write-Host ("  [ FAIL ] {0} -> {1}" -f $Desc, $_.Exception.Message) -ForegroundColor Red; $script:Errors++ }
    } else { Write-Host ("  [preview] {0}" -f $Desc) -ForegroundColor DarkGray }
}
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------------------
# AdskLicensingInstHelper: locate it and run it
# ---------------------------------------------------------------------------
function Get-HelperPath {
    if ($HelperPath) {
        if (Test-Path -LiteralPath $HelperPath) { return (Get-Item -LiteralPath $HelperPath).FullName }
        throw ('AdskLicensingInstHelper was not found at: ' + $HelperPath)
    }
    $commonFiles = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared'
    $standard = Join-Path $commonFiles 'AdskLicensing\Current\helper\AdskLicensingInstHelper.exe'
    if (Test-Path -LiteralPath $standard) { return $standard }
    # A build that was not linked through 'Current' still counts (same search
    # Repair.ps1 uses).
    $root = Join-Path $commonFiles 'AdskLicensing'
    if (Test-Path -LiteralPath $root) {
        $found = Get-ChildItem -LiteralPath $root -Recurse -Filter 'AdskLicensingInstHelper.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

# Runs the licensing helper with an explicit, hand-built command line.
#
# Why not '& helper @args': Windows PowerShell 5.1 silently DROPS empty
# string arguments passed to an executable, so the RESET line
# 'change ... -lm "" -lt "" -ls ""' would reach the helper as
# 'change ... -lm -lt -ls' and change the wrong thing. The line is
# therefore assembled by hand and handed to ProcessStartInfo verbatim.
# A .ps1 helper (test suite / -HelperPath) is started through powershell.exe.
function Start-Helper {
    param([string]$ArgLine, [int]$TimeoutSec = 60)

    $fileName  = $script:Helper
    $arguments = $ArgLine
    if ($script:Helper -like '*.ps1') {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $script:Helper, $ArgLine
        $fileName  = Join-Path $PSHOME 'powershell.exe'
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $fileName
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    try { $proc = [System.Diagnostics.Process]::Start($psi) }
    catch { return [pscustomobject]@{ Code = -1; Output = ('Could not start ' + $fileName + ': ' + $_.Exception.Message) } }

    # read both streams while the helper runs (no deadlock on full buffers)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        return [pscustomobject]@{ Code = -1; Output = ('The licensing helper did not answer within ' + $TimeoutSec + ' seconds.') }
    }
    return [pscustomobject]@{ Code = $proc.ExitCode; Output = ($outTask.Result + $errTask.Result) }
}

function Get-MethodName {
    param([int]$Code)
    switch ($Code) {
        1 { 'NETWORK' }
        2 { 'STANDALONE' }
        3 { 'MSSA' }
        4 { 'USER' }
        default { 'UNKNOWN' }
    }
}

function Format-MethodLabel {
    param([string]$Method)
    switch ($Method) {
        'USER'       { 'single-user (sign-in)' }
        'NETWORK'    { 'network (NLM)' }
        'STANDALONE' { 'standalone (serial)' }
        'RESET'      { 'no method (the product asks at launch)' }
        'MSSA'       { 'MSSA' }
        default      { 'unknown' }
    }
}

function Get-ProductNameFromKey {
    param([string]$Key)
    if ($Key -and $Key -match '^([A-Z0-9]{3})[A-Z][0-9]+$') {
        $prefix = $Matches[1]
        if ($script:ProductNames.ContainsKey($prefix)) { return $script:ProductNames[$prefix] }
    }
    return $null
}

function Get-ProductYear {
    param([string]$Key, [string]$Version)
    if ($Version -and $Version -match '^\s*(\d{4})\.') { return [int]$Matches[1] }
    if ($Key -and $Key -match '^[A-Z0-9]{3}([A-Z])[0-9]+$') {
        $letter = $Matches[1]
        if ($script:YearLetters.ContainsKey($letter)) { return $script:YearLetters[$letter] }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Registered products: 'AdskLicensingInstHelper list' returns a JSON array of
# registered features (their format, not ours):
#   [ { "feature_id": "ACD", "sel_prod_key": "001Q1", "sel_prod_ver": "2025.0.0.F",
#       "lic_method": 4, "lic_server_type": 1, "lic_servers": ["@1.1.1.1"] , ... } ]
# lic_method: 1=Network 2=Standalone 3=MSSA 4=User (0=unknown).
# NOTE: every task below talks to the helper as a child process and reads its
# stdout; the tool itself never writes to the Autodesk configuration directly.
# ---------------------------------------------------------------------------
function Get-RegisteredProducts {
    $r = Start-Helper -ArgLine 'list'
    $text = [string]$r.Output
    if ($r.Code -ne 0) {
        throw ('AdskLicensingInstHelper list failed (exit {0}): {1}' -f $r.Code, $text.Trim())
    }
    if (-not $text.Trim()) { return @() }

    $raw = $null
    try { $raw = $text | ConvertFrom-Json -ErrorAction Stop } catch { $raw = $null }
    if ($null -eq $raw) {
        $m = [regex]::Match($text, '(?s)\[.*\]')
        if ($m.Success) { try { $raw = $m.Value | ConvertFrom-Json -ErrorAction Stop } catch { $raw = $null } }
    }
    if ($null -eq $raw) {
        $m = [regex]::Match($text, '(?s)\{.*\}')
        if ($m.Success) { try { $raw = $m.Value | ConvertFrom-Json -ErrorAction Stop } catch { $raw = $null } }
    }
    if ($null -eq $raw) {
        throw ('Could not read the product list from AdskLicensingInstHelper. Output: ' + $text.Trim())
    }

    $features = @()
    if ($raw -is [System.Array]) { $features = @($raw) }
    elseif ($raw.PSObject.Properties['products']) { $features = @($raw.products) }
    else { $features = @($raw) }

    $products = New-Object System.Collections.Generic.List[object]
    foreach ($f in $features) {
        if (-not $f) { continue }
        $key = [string]$f.sel_prod_key
        if (-not $key) { $key = [string]$f.def_prod_key }
        $ver = [string]$f.sel_prod_ver
        if (-not $ver) { $ver = [string]$f.def_prod_ver }
        if (-not ($key -and $ver)) { continue }

        $code = 0
        try { $code = [int]$f.lic_method } catch { $code = 0 }

        $servers = @()
        if ($f.lic_servers) { $servers = @($f.lic_servers | Where-Object { $_ -and ([string]$_).Trim() } | ForEach-Object { ([string]$_).Trim() }) }

        $serverType = $null
        $st = 0
        try { $st = [int]$f.lic_server_type } catch { $st = 0 }
        if ($st -eq 1) { $serverType = 'SINGLE' }
        elseif ($st -eq 2) { $serverType = 'REDUNDANT' }
        elseif ($st -eq 3) { $serverType = 'DISTRIBUTED' }

        $products.Add([pscustomobject]@{
            FeatureId      = [string]$f.feature_id
            ProductKey     = $key
            ProductVersion = $ver
            Name           = (Get-ProductNameFromKey $key)
            Year           = (Get-ProductYear -Key $key -Version $ver)
            Method         = (Get-MethodName $code)
            MethodCode     = $code
            ServerType     = $serverType
            Servers        = $servers
        })
    }

    # one line per product key+version (verticals can register twice)
    $seen = @{}
    $result = foreach ($p in $products) {
        $id = ($p.ProductKey + '|' + $p.ProductVersion)
        if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $p }
    }
    return @($result | Sort-Object Name, ProductKey)
}

function Format-ProductLabel {
    param($P)
    if ($P.Name) {
        if ($P.Year) { return ('{0} {1}' -f $P.Name, $P.Year) }
        return $P.Name
    }
    return ('Autodesk product ' + $P.ProductKey)
}

function Write-ProductList {
    param($Products)
    foreach ($p in $Products) {
        $extra = ''
        if ($p.Method -eq 'NETWORK' -and @($p.Servers).Count -gt 0) { $extra = '   servers: ' + (@($p.Servers) -join ', ') }
        Write-Host ("  {0,-36} {1,-6} {2,-14} {3}{4}" -f (Format-ProductLabel $p), $p.ProductKey, $p.ProductVersion, (Format-MethodLabel $p.Method), $extra)
    }
}

function ConvertTo-ProductJson {
    param($Products)
    $items = @()
    foreach ($p in $Products) {
        $items += [pscustomobject]@{
            featureId      = $p.FeatureId
            productKey     = $p.ProductKey
            productVersion = $p.ProductVersion
            name           = $p.Name
            year           = $p.Year
            method         = $p.Method
            methodCode     = $p.MethodCode
            serverType     = $p.ServerType
            servers        = @($p.Servers)
        }
    }
    return ([pscustomobject]@{
        ok       = $true
        helper   = $script:Helper
        count    = $items.Count
        products = $items
    } | ConvertTo-Json -Depth 6 -Compress)
}

function Write-JsonError {
    param([string]$Code, [string]$Message)
    Write-Output ([pscustomobject]@{ ok = $false; code = $Code; error = $Message } | ConvertTo-Json -Compress)
}

# ===========================================================================
# Main
# ===========================================================================
$isAdmin = Test-IsAdmin

if (-not $script:ListMode) {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host '   Autodesk Licensing Doctor  -  License mode' -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ("   Mode  : {0}" -f $(if ($Apply) { 'APPLY (will change the license type)' } else { 'PREVIEW (nothing changes)' })) -ForegroundColor $(if ($Apply) { 'Yellow' } else { 'Green' })
    Write-Host ("   Admin : {0}" -f $isAdmin)
    if ($script:LogPath) { Write-Host ("   Log   : {0}" -f $script:LogPath) -ForegroundColor DarkGray }
    if ($Apply -and -not $isAdmin) { Write-Host '   ERROR: -Apply needs an administrator shell.' -ForegroundColor Red; exit 1 }
}

# --- locate the helper -----------------------------------------------------
try { $script:Helper = Get-HelperPath } catch { $script:Helper = $null; $helperError = $_.Exception.Message }
if (-not $script:Helper) {
    $msg = 'AdskLicensingInstHelper.exe was not found. The Autodesk licensing service (ADLS) is not installed on this PC - no 2020+ Autodesk product is.'
    if ($Json) { Write-JsonError 'no-helper' $msg; exit 1 }
    Write-Host ''
    Warn-Line $msg
    exit 1
}

# --- listing ---------------------------------------------------------------
if ($script:ListMode) {
    try { $products = @(Get-RegisteredProducts) }
    catch {
        if ($Json) { Write-JsonError 'list-failed' $_.Exception.Message; exit 1 }
        Warn-Line $_.Exception.Message
        exit 1
    }
    if ($Json) { Write-Output (ConvertTo-ProductJson $products); exit 0 }
    Write-Host ''
    Write-Host '== Registered Autodesk products ==' -ForegroundColor Cyan
    Info ('Helper: ' + $script:Helper)
    if ($products.Count -eq 0) {
        Warn-Line 'No products are registered with the Autodesk licensing service.'
        Warn-Line 'Either nothing from 2020 on is installed, or the registration is missing - the Repair step re-registers the official components.'
        exit 0
    }
    Write-Host ''
    Write-ProductList $products
    Write-Host ''
    Info 'Switch one with: -ProductKey <key> -ProductVersion <version> -LicenseType USER|NETWORK|STANDALONE|RESET  (add -Apply to make the change)'
    exit 0
}

# --- switch ----------------------------------------------------------------
if (-not $ProductKey -or -not $LicenseType) {
    Write-Host ''
    Write-Host '   ERROR: -ProductKey and -LicenseType are required (see the examples at the top of this script).' -ForegroundColor Red
    exit 1
}

try { $all = @(Get-RegisteredProducts) }
catch { Write-Host ''; Warn-Line $_.Exception.Message; exit 1 }

if ($all.Count -eq 0) {
    Write-Host ''
    Warn-Line 'No products are registered with the Autodesk licensing service - nothing to switch.'
    Warn-Line 'Run the Repair step first if a product is installed but does not show up here.'
    exit 1
}

$match = @($all | Where-Object { $_.ProductKey -eq $ProductKey })
if ($ProductVersion) { $match = @($match | Where-Object { $_.ProductVersion -eq $ProductVersion }) }
if ($match.Count -eq 0) {
    Write-Host ''
    Warn-Line ('Product ' + $ProductKey + ' is not registered on this PC. Registered products:')
    Write-ProductList $all
    exit 1
}
if ($match.Count -gt 1) {
    Write-Host ''
    Warn-Line ('More than one registered version matches ' + $ProductKey + ' - add -ProductVersion <version>:')
    Write-ProductList $match
    exit 1
}
$target = $match[0]

Section 'Requested change'
Info ('Product : {0}   ({1} / {2})' -f (Format-ProductLabel $target), $target.ProductKey, $target.ProductVersion)
Info ('Current : {0}' -f (Format-MethodLabel $target.Method))
Info ('New     : {0}' -f (Format-MethodLabel $LicenseType))

$effectiveServerType = $null
$effectiveServers = $null
if ($LicenseType -eq 'NETWORK') {
    if ($LicServers) {
        # Accept plain names/IPs and prefix them with '@' (the helper's format);
        # entries that already carry '@' or 'port@host' are kept as typed.
        $entries = @(@($LicServers -split ',') | ForEach-Object {
            $s = ([string]$_).Trim()
            if ($s -and ($s -notmatch '@')) { $s = '@' + $s }
            $s
        } | Where-Object { $_ })
        if (-not $LicServerType) {
            # one address = Single; two or three = a Redundant pool
            $LicServerType = if ($entries.Count -ge 2 -and $entries.Count -le 3) { 'REDUNDANT' } else { 'SINGLE' }
        }
        $effectiveServerType = $LicServerType
        $effectiveServers = ($entries -join ',')
        Info ('Servers : {0}   (server type: {1})' -f $effectiveServers, $effectiveServerType)
    } else {
        Warn-Line 'No license server was given - the method is switched, but the product will still ask for a server until one is configured.'
    }
} elseif ($LicenseType -eq 'RESET') {
    Info 'RESET: no method is registered, so the product asks the user to choose at the next launch.'
}
if ($target.Method -eq $LicenseType) {
    Warn-Line ('The product is already ' + (Format-MethodLabel $LicenseType) + ' - this re-applies it (and updates the server info if given).')
}

if (-not $Apply) {
    Write-Host ''
    Write-Host '  PREVIEW - nothing was changed. Run again with -Apply to switch the license type.' -ForegroundColor Green
    exit 0
}

# --- apply -----------------------------------------------------------------
Section 'Apply'

# The legacy HKCU override (left behind by old installs and non-genuine
# activators) wins over what the helper writes for network licensing, so it
# has to go before the server info can change.
if ($LicenseType -eq 'NETWORK') {
    try {
        $flexKey = 'HKCU:\Software\FLEXlm License Manager'
        if (Get-ItemProperty -Path $flexKey -Name 'ADSKFLEX_LICENSE_FILE' -ErrorAction SilentlyContinue) {
            Step 'Remove the legacy ADSKFLEX_LICENSE_FILE override (it blocks license-server changes)' {
                Remove-ItemProperty -Path $flexKey -Name 'ADSKFLEX_LICENSE_FILE' -Force
            }
        }
    } catch { Warn-Line ('Could not check ADSKFLEX_LICENSE_FILE: ' + $_.Exception.Message) }
}

# The sign-in broker must not be running while the license type changes.
if (-not $NoProcessStop) {
    $sso = @(Get-Process -Name 'AdSSO' -ErrorAction SilentlyContinue)
    if ($sso.Count -gt 0) {
        Step 'Stop AdSSO while the license type changes (it restarts on demand)' { Stop-Process -InputObject $sso -Force }
    }
}

$prodProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -match '^(acad|acadlt|revit|inventor|3dsmax|maya|motionbuilder|mudbox|navisworks|infraworks|recap|robot|advancesteel|vault)'
})
if ($prodProcs.Count -gt 0) {
    Warn-Line ('These Autodesk products are running: ' + (($prodProcs | Select-Object -ExpandProperty ProcessName -Unique) -join ', '))
    Warn-Line 'The new license type applies after the product is closed and reopened.'
}

Section 'Change license type'
$changeLine = 'change -pk "{0}" -pv "{1}"' -f $target.ProductKey, $target.ProductVersion
switch ($LicenseType) {
    'RESET' {
        # explicit empty values reset the method and the stored server info;
        # they must appear as literal "" tokens on the command line
        $changeLine += ' -lm "" -lt "" -ls ""'
    }
    'NETWORK' {
        $changeLine += ' -lm NETWORK'
        if ($effectiveServers) {
            $changeLine += (' -lt "{0}" -ls "{1}"' -f $effectiveServerType, $effectiveServers)
        }
    }
    default { $changeLine += (' -lm ' + $LicenseType) }
}

Info ('Running: ' + (Split-Path -Leaf $script:Helper) + ' ' + $changeLine)
$change = Start-Helper -ArgLine $changeLine
$changeText = ([string]$change.Output).Trim()
if ($changeText) { foreach ($line in ($changeText -split "\r?\n")) { if ($line.Trim()) { Info $line.Trim() } } }
if ($change.Code -ne 0) {
    Write-Host ''
    Write-Host ('  [FAIL] AdskLicensingInstHelper change exited {0} - the license type was NOT changed.' -f $change.Code) -ForegroundColor Red
    exit 1
}

Section 'Verify'
$expected = switch ($LicenseType) { 'USER' { 4 } 'NETWORK' { 1 } 'STANDALONE' { 2 } default { -1 } }
$after = @()
try { $after = @(Get-RegisteredProducts) } catch { Warn-Line ('Could not re-read the product list to verify: ' + $_.Exception.Message) }
$now = @($after | Where-Object { $_.ProductKey -eq $target.ProductKey -and $_.ProductVersion -eq $target.ProductVersion } | Select-Object -First 1)
if (-not $now) { $now = @($after | Where-Object { $_.ProductKey -eq $target.ProductKey } | Select-Object -First 1) }

if ($now) {
    if ($LicenseType -eq 'RESET') {
        Info ('The service now reports: ' + (Format-MethodLabel $now.Method))
        Write-Host '  [ done ] License mode reset - the product asks at the next launch' -ForegroundColor Green
    } elseif ($now.MethodCode -eq $expected) {
        Write-Host ('  [ done ] Verified: {0} is now {1}' -f (Format-ProductLabel $target), (Format-MethodLabel $LicenseType)) -ForegroundColor Green
    } else {
        Warn-Line ('The change command succeeded, but the service still reports ' + (Format-MethodLabel $now.Method) + ' for this product.')
        Warn-Line 'Close the product completely, then re-run this with -Apply; if it still shows the old type, run the Repair step.'
        $script:Errors++
    }
} else {
    Warn-Line 'Could not re-read the registration to verify the change.'
}

Write-Host ''
if ($LicenseType -eq 'USER') {
    Write-Host '  Next: open the product and sign in with the Autodesk account (close and reopen it first if it was running).' -ForegroundColor Cyan
} elseif ($LicenseType -eq 'NETWORK') {
    Write-Host '  Next: make sure the license server is reachable (NLM, TCP 2080/27000), then reopen the product.' -ForegroundColor Cyan
}
if ($script:Errors -gt 0) { exit 1 }
exit 0
