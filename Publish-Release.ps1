<#
  Publish-Release.ps1  -  UNLOCK DIGITAL  -  Autodesk Licensing Doctor
  --------------------------------------------------------------------
  One command that cuts a release end to end:

    build  ->  commit  ->  push  ->  publish

  Two modes:

    Default                : builds locally and publishes the release straight to
                             GitHub with `gh release create` (unsigned binaries).
                             Use this until code signing is enabled.

    -ViaGitHubActions      : commits + pushes and creates the version tag. The
                             "Release (Signed)" workflow then builds on GitHub,
                             signs the binaries with SignPath and publishes the
                             release. Use this once SignPath is set up.
                             See SIGNPATH-SETUP.md.

  Examples
    .\Publish-Release.ps1 -Version 1.2.1 -Notes "Fixed ADLS reset" -Recompile
    .\Publish-Release.ps1 -Version 1.2.1 -Notes "Signed release" -Recompile -ViaGitHubActions
    .\Publish-Release.ps1 -Version 1.2.1 -Notes "Just build it" -NoGit
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [string]$Notes = '',

    # Re-encode the GUI (UTF-8 BOM) and recompile the exe before building
    [switch]$Recompile,

    # Commit + push + tag, and let the signed CI workflow publish the release
    [switch]$ViaGitHubActions,

    # Build only; do not touch git or GitHub
    [switch]$NoGit
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

function Write-Step($m) { Write-Host ("  [*] " + $m) -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host ("  [v] " + $m) -ForegroundColor Green }
function Write-Warn2($m){ Write-Host ("  [!] " + $m) -ForegroundColor Yellow }

# git / gh are not always on PATH in a fresh session
$env:Path = $env:Path + ';C:\Program Files\Git\cmd;C:\Program Files\GitHub CLI'

function Invoke-Git {
    param([string[]]$GitArgs)
    $out = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
    if ($out) { $out | ForEach-Object { if ($_ -is [string]) { Write-Host ("      " + $_) -ForegroundColor DarkGray } } }
    if ($code -ne 0) { throw ("git " + ($GitArgs -join ' ') + " failed (exit $code)") }
}

Set-Location $root
$tag = "v$Version"

Write-Host ""
Write-Host "UNLOCK DIGITAL - publish release $tag" -ForegroundColor White
Write-Host ""

# ---------------------------------------------------------------------------
# 0) pre-flight
# ---------------------------------------------------------------------------
if (-not $NoGit) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git not found." }
    $existing = (& git tag --list $tag)
    if ($existing) { throw "Tag $tag already exists. Pick another version or delete the tag first." }
    if ($ViaGitHubActions -and -not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "gh (GitHub CLI) not found - required for -ViaGitHubActions."
    }
}

# ---------------------------------------------------------------------------
# 1) build
# ---------------------------------------------------------------------------
Write-Step "Building release artifacts (Build-Release.ps1) ..."
# NOTE: hashtable splatting (not an array) - an array would pass the elements
# positionally and bind "-Version" as the *value* of -Version.
$buildScript = Join-Path $root 'Build-Release.ps1'
$buildParams = @{ Version = $Version; Notes = $Notes }
if ($Recompile) { $buildParams['Recompile'] = $true }
& $buildScript @buildParams
if (-not $?) { throw "Build failed." }

$relDir    = Join-Path $root ("releases\v" + $Version)
$setupExe  = Join-Path $relDir ("UNLOCK-DIGITAL-AdskDoctor-Setup-$Version.exe")
$zipPort   = Join-Path $relDir ("AdskDoctor-v$Version-Portable.zip")
$zipProj   = Join-Path $relDir ("AdskDoctor-v$Version-Project.zip")
foreach ($f in @($setupExe, $zipPort, $zipProj)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing release artifact: $f" }
}
Write-Ok "Artifacts built."

if ($NoGit) {
    Write-Host ""
    Write-Ok "Done (no git). Files are in $relDir"
    return
}

# ---------------------------------------------------------------------------
# 2) release notes (file, so quoting never breaks)
# ---------------------------------------------------------------------------
$notesFile = Join-Path $env:TEMP ("adsk_notes_" + $Version + ".md")
$notesText = @"
## UNLOCK DIGITAL - Autodesk Licensing Doctor v$Version

$Notes

### Artifacts

| Asset | Use |
|-------|-----|
| ``UNLOCK-DIGITAL-AdskDoctor-Setup-$Version.exe`` | installer (recommended) |
| ``AdskDoctor-v$Version-Portable.zip`` | portable, no install |
| ``AdskDoctor-v$Version-Project.zip`` | full source |

Bilingual **Arabic / English** GUI. MIT licensed - see [CODE-SIGNING.md](CODE-SIGNING.md) for the code signing policy.
"@
[System.IO.File]::WriteAllText($notesFile, $notesText, (New-Object System.Text.UTF8Encoding($false)))

$msgFile = Join-Path $env:TEMP ("adsk_msg_" + $Version + ".txt")
[System.IO.File]::WriteAllText($msgFile, "Release v$Version`r`n`r`n$Notes`r`n", (New-Object System.Text.UTF8Encoding($false)))

# ---------------------------------------------------------------------------
# 3) commit + push
# ---------------------------------------------------------------------------
Write-Step "Committing and pushing ..."
Invoke-Git @('add', '-A')
$staged = (& git diff --cached --name-only)
if ($staged) {
    Invoke-Git @('commit', '-F', $msgFile)
    Write-Ok "Committed."
} else {
    Write-Warn2 "Nothing to commit (working tree clean)."
}
Invoke-Git @('push')
Write-Ok "Pushed to origin."

# ---------------------------------------------------------------------------
# 4) publish
# ---------------------------------------------------------------------------
if ($ViaGitHubActions) {
    Write-Step "Tagging $tag and pushing it (this triggers the signed CI build) ..."
    Invoke-Git @('tag', '-a', $tag, '-m', "Release $tag")
    Invoke-Git @('push', 'origin', $tag)
    Write-Host ""
    Write-Ok "Tag $tag pushed."
    Write-Host "      The 'Release (Signed)' workflow is now building and signing." -ForegroundColor Gray
    Write-Host "      Watch it at: https://github.com/Es1amAshraf/autodesk-licensing-doctor/actions" -ForegroundColor Gray
    return
}

Write-Step "Creating the GitHub release ..."
$ghOut = & gh release create $tag $setupExe $zipPort $zipProj `
    --title "$tag" --notes-file $notesFile 2>&1
$code = $LASTEXITCODE
$ghOut | ForEach-Object { if ($_ -is [string]) { Write-Host ("      " + $_) -ForegroundColor DarkGray } }
if ($code -ne 0) { throw "gh release create failed (exit $code)." }

Write-Host ""
Write-Ok "Released: https://github.com/Es1amAshraf/autodesk-licensing-doctor/releases/tag/$tag"
