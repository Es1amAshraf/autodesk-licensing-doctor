<#
  Sign.ps1  -  UNLOCK DIGITAL  -  Autodesk Licensing Doctor
  ---------------------------------------------------------
  Authenticode-sign release binaries with Microsoft signtool, with RFC-3161
  timestamping (so a signature stays valid after the certificate expires).

  This is the ALTERNATIVE to the CI / SignPath flow. Use it when you hold your
  own code signing certificate - e.g. Certum Open Source Code Signing, an OV
  certificate, or a certificate in your local store. See SIGNPATH-SETUP.md.

  Examples
  ---------
    # what certificates can I sign with?
    .\Sign.ps1 -List

    # sign every exe of a release, by certificate thumbprint
    .\Sign.ps1 -Path .\releases\v1.2.4\*.exe -Thumbprint A1B2C3D4...

    # sign from a .pfx (only if your CA still allows software-protected keys)
    .\Sign.ps1 -Path .\UNLOCK-DIGITAL-AdskDoctor.exe -PfxFile .\cert.pfx

    # verify what is in a release folder
    .\Sign.ps1 -Verify -Path .\releases\v1.2.4\*.exe
#>
[CmdletBinding()]
param(
    # List the code signing certificates available in the store, then exit
    [switch]$List,

    # Verify signatures instead of creating them
    [switch]$Verify,

    # Files to sign / verify. Wildcards allowed ("unresolved" wildcards, i.e. in
    # a literal file name, are reserved for signing).
    [Parameter(Position = 0)]
    [string[]]$Path,

    # Certificate thumbprint (SHA-1) - from the user/machine My store
    [string]$Thumbprint,

    # .pfx / .p12 file
    [string]$PfxFile,

    # Password for -PfxFile
    [securestring]$PfxPassword,

    # Look in the LocalMachine store instead of CurrentUser
    [switch]$MachineStore,

    # RFC-3161 timestamp server
    [string]$TimestampServer = 'http://timestamp.digicert.com',

    # Also sign a file's own signature (double signing) - rarely needed
    [switch]$AppendSignature
)

$ErrorActionPreference = 'Stop'

function Write-Step($m) { Write-Host ("  [*] " + $m) -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host ("  [v] " + $m) -ForegroundColor Green }
function Write-Bad($m)  { Write-Host ("  [x] " + $m) -ForegroundColor Red }
function Write-Warn2($m){ Write-Host ("  [!] " + $m) -ForegroundColor Yellow }

function Get-SignToolPath {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin") |
        Where-Object { $_ -and (Test-Path $_) }
    if (-not $roots) { throw "Windows SDK not found. Install 'Windows SDK Signing Tools' or put signtool.exe on PATH." }

    $found = Get-ChildItem -Path $roots -Filter signtool.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\signtool\.exe$' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
    if (-not $found) { throw "signtool.exe (x64) not found under the Windows Kits folder." }
    return $found.FullName
}

function Resolve-TargetFiles {
    param([string[]]$Paths, [switch]$Recurse)
    $out = @()
    foreach ($p in $Paths) {
        $items = @(Get-Item -Path $p -ErrorAction SilentlyContinue)
        if (-not $items.Count) { Write-Bad "not found: $p"; continue }
        foreach ($i in $items) {
            if ($i.PSIsContainer) { $out += @(Get-ChildItem -LiteralPath $i.FullName -File -Recurse:$Recurse) }
            else { $out += $i }
        }
    }
    return @($out)
}

# ---------------------------------------------------------------------------
# 1) -List : show usable signing certificates
# ---------------------------------------------------------------------------
if ($List) {
    $store = if ($MachineStore) { 'LocalMachine' } else { 'CurrentUser' }
    Write-Host ""
    Write-Host "Code signing certificates in Cert:\$store\My" -ForegroundColor White
    Write-Host ""
    $certs = Get-ChildItem "Cert:\$store\My" -ErrorAction SilentlyContinue |
        Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date) }
    if (-not $certs) { Write-Bad "none found (a certificate with a private key is required)" }
    foreach ($c in $certs) {
        Write-Host ("  {0}" -f $c.Subject)
        Write-Host ("      thumbprint : {0}" -f $c.Thumbprint) -ForegroundColor Gray
        Write-Host ("      expires    : {0:yyyy-MM-dd}" -f $c.NotAfter) -ForegroundColor Gray
        Write-Host ("      issuer     : {0}" -f $c.Issuer) -ForegroundColor Gray
        Write-Host ""
    }
    return
}

if (-not $Path) { throw "Nothing to do. Pass -Path <files>, or -List to see certificates." }
$files = Resolve-TargetFiles -Paths $Path -Recurse:$Recurse
if (-not $files.Count) { throw "No files matched." }

# signtool is only needed for signing; verification uses Get-AuthenticodeSignature
$signtool = $null
if (-not $Verify) { $signtool = Get-SignToolPath }

# ---------------------------------------------------------------------------
# 2) -Verify
# ---------------------------------------------------------------------------
if ($Verify) {
    Write-Host ""
    Write-Host "Verifying $($files.Count) file(s)" -ForegroundColor White
    Write-Host ""
    $bad = 0
    foreach ($f in $files) {
        $sig = Get-AuthenticodeSignature $f.FullName
        $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '-' }
        $line = "{0,-12} {1}" -f $sig.Status, $f.Name
        if ($sig.Status -eq 'Valid') { Write-Host ("  [v] " + $line) -ForegroundColor Green }
        else { Write-Host ("  [x] " + $line) -ForegroundColor Red; $bad++ }
        Write-Host ("      signer : " + $signer) -ForegroundColor Gray
        if ($sig.TimeStamperCertificate) {
            Write-Host ("      stamped: " + $sig.TimeStamperCertificate.Subject) -ForegroundColor Gray
        }
    }
    Write-Host ""
    if ($bad) { throw "$bad file(s) are not validly signed." }
    Write-Ok "All signatures are valid."
    return
}

# ---------------------------------------------------------------------------
# 3) signing
# ---------------------------------------------------------------------------
if ($Thumbprint) {
    $store = if ($MachineStore) { 'LocalMachine' } else { 'CurrentUser' }
    $cert = Get-ChildItem "Cert:\$store\My\$Thumbprint" -ErrorAction SilentlyContinue
    if (-not $cert) { throw "No certificate with thumbprint $Thumbprint in Cert:\$store\My" }
    Write-Step ("Certificate: " + $cert.Subject)
    Write-Step ("Expires    : " + $cert.NotAfter.ToString('yyyy-MM-dd'))
    Write-Step ("signtool   : " + $signtool)
    Write-Host ""
    foreach ($f in $files) {
        Write-Step ("signing " + $f.Name)
        $sa = @('sign', '/fd', 'SHA256', '/tr', $TimestampServer, '/td', 'SHA256')
        if ($MachineStore) { $sa += '/sm' }
        if ($AppendSignature) { $sa += '/as' }
        $sa += @('/sha1', $cert.Thumbprint, $f.FullName)
        & $signtool @sa
        if ($LASTEXITCODE -ne 0) { throw ("signtool failed for " + $f.Name + " (exit " + $LASTEXITCODE + ")") }
    }
}
elseif ($PfxFile) {
    if (-not (Test-Path -LiteralPath $PfxFile)) { throw "PFX not found: $PfxFile" }
    Write-Step ("signtool : " + $signtool)
    Write-Warn2 "Using a .pfx - most CAs no longer allow software-protected code signing keys."
    Write-Host ""
    foreach ($f in $files) {
        Write-Step ("signing " + $f.Name)
        $sa = @('sign', '/fd', 'SHA256', '/tr', $TimestampServer, '/td', 'SHA256', '/f', (Resolve-Path $PfxFile).Path)
        if ($PfxPassword) { $sa += @('/p', $PfxPassword) }
        if ($AppendSignature) { $sa += '/as' }
        $sa += $f.FullName
        & $signtool @sa
        if ($LASTEXITCODE -ne 0) { throw ("signtool failed for " + $f.Name + " (exit " + $LASTEXITCODE + ")") }
    }
}
else {
    throw "Choose how to sign: -Thumbprint <sha1> or -PfxFile <file>. (Use -List to see certificates.)"
}

# ---------------------------------------------------------------------------
# 4) verify what we just signed
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Result" -ForegroundColor White
$bad = 0
foreach ($f in $files) {
    $sig = Get-AuthenticodeSignature $f.FullName
    if ($sig.Status -eq 'Valid') { Write-Host ("  [v] " + $f.Name + "  ->  " + $sig.SignerCertificate.Subject) -ForegroundColor Green }
    else { Write-Host ("  [x] " + $f.Name + "  ->  " + $sig.Status) -ForegroundColor Red; $bad++ }
}
Write-Host ""
if ($bad) { throw "$bad file(s) failed verification after signing." }
Write-Ok "Done."
