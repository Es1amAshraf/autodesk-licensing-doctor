<#
    AdskDoctor.Tests.ps1
    ---------------------------------------------------------------------------
    Guards the promises the toolkit makes to a reseller's machine:

      1. PREVIEW really changes nothing      (read-only by default)
      2. The backup is a complete safety net (manifest + runnable UNDO.ps1)
      3. UNDO.ps1 really rolls back
      4. The diagnostic stays read-only, produces a valid report and reports
         the licensing sections it claims to
      5. An old AdskLicensing build is flagged (the cracked-install case)
      6. The two field bugs that reached users cannot come back

    The toolkit itself ships as Windows PowerShell 5.1, so every script under
    test is launched with powershell.exe even when Pester runs on PowerShell 7.

    Run:  Invoke-Pester ./tests
#>

BeforeAll {
    $script:Root  = Split-Path -Parent $PSScriptRoot
    $script:PsExe = 'powershell'
    $script:Tmp   = Join-Path $env:TEMP ('adskdoctor-tests-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $script:Tmp | Out-Null

    $script:Hosts     = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $script:HostsHash = (Get-FileHash -LiteralPath $script:Hosts -Algorithm SHA256).Hash

    # Some checks need an elevated shell (Program Files, ProgramData, hosts).
    # CI runs as administrator; a developer shell may not, so those steps skip.
    $script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)

    # the fake licensing stack this suite may create (removed again in AfterAll)
    $script:CommonFiles = Join-Path ${env:ProgramFiles(x86)} 'Common Files\Autodesk Shared'
    $script:FakeLic     = Join-Path $script:CommonFiles 'AdskLicensing'
    $script:FakeLicMade = $false

    function Invoke-ToolScript {
        param([string]$Name, [string[]]$Arguments = @())
        $path = Join-Path $script:Root $Name
        & $script:PsExe -NoProfile -ExecutionPolicy Bypass -File $path @Arguments 2>&1 | Out-String
    }

    function Get-HostsHash { (Get-FileHash -LiteralPath $script:Hosts -Algorithm SHA256).Hash }
    function Get-HostsText { Get-Content -LiteralPath $script:Hosts -Raw }
}

AfterAll {
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    if ($script:FakeLicMade) {
        Remove-Item -LiteralPath $script:FakeLic -Recurse -Force -ErrorAction SilentlyContinue
        # only remove the parents if we left them behind empty
        foreach ($p in @($script:CommonFiles, (Split-Path -Parent $script:CommonFiles))) {
            if ((Test-Path -LiteralPath $p) -and -not (Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Preview mode' {
    It 'Clean.ps1 without -Apply does not change the machine' {
        # A leftover folder that a cleanup would normally delete. Only an
        # elevated shell may create one under ProgramData.
        $marker = Join-Path $env:ProgramData 'FLEXnet\adskdoctor-preview-marker.txt'
        $markerMade = $false
        if ($script:IsAdmin) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $marker) | Out-Null
            Set-Content -LiteralPath $marker -Value 'preview must not delete me' -Encoding ASCII
            $markerMade = $true
        }

        $out = Invoke-ToolScript 'Clean.ps1'

        $out | Should -Match 'PREVIEW'
        if ($markerMade) {
            Test-Path -LiteralPath $marker | Should -BeTrue -Because 'a preview must not delete leftover folders'
        }
        Get-HostsHash | Should -Be $script:HostsHash -Because 'a preview must not rewrite the hosts file'
    }

    It 'Repair.ps1 without -Apply does not change the machine' {
        $out = Invoke-ToolScript 'Repair.ps1'
        $out | Should -Match 'PREVIEW'
        Get-HostsHash | Should -Be $script:HostsHash
    }
}

Describe 'Layered backup and UNDO' {
    It 'writes a manifest and a runnable UNDO script' {
        $out = Invoke-ToolScript 'Backup.ps1' @('-SkipRestorePoint', '-BackupRoot', $script:Tmp, '-Label', 'ci')
        $out | Should -Match 'BACKUP SUMMARY'

        $dir = Get-ChildItem -LiteralPath $script:Tmp -Directory |
               Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $dir | Should -Not -BeNullOrEmpty -Because 'the backup must create its own folder'
        $script:BackupDir = $dir.FullName

        $manifestPath = Join-Path $script:BackupDir 'manifest.json'
        Test-Path -LiteralPath $manifestPath | Should -BeTrue
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json   # must be valid JSON
        @($manifest.Items).Count | Should -BeGreaterThan 0
        # Compare folder names: a runner reports %TEMP% once as "RUNNER~1" and
        # once as "runneradmin", so the full paths are allowed to differ.
        Split-Path -Leaf $manifest.BackupFolder | Should -Be (Split-Path -Leaf $script:BackupDir)
        Test-Path -LiteralPath $manifest.BackupFolder | Should -BeTrue -Because 'the manifest has to point at the backup folder'

        $undo = Join-Path $script:BackupDir 'UNDO.ps1'
        Test-Path -LiteralPath $undo | Should -BeTrue
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($undo, [ref]$null, [ref]$errors)
        @($errors).Count | Should -Be 0 -Because 'UNDO.ps1 has to be runnable'
        # A service that the clean-up deletes cannot come back from a file copy,
        # so UNDO has to recreate it from the snapshot.
        (Get-Content -LiteralPath $undo -Raw) | Should -Match 'Restoring services'
    }

    It 'keeps a copy of the hosts file' {
        Test-Path -LiteralPath (Join-Path $script:BackupDir 'files\hosts') | Should -BeTrue
    }

    It 'UNDO.ps1 rolls a changed hosts file back' {
        if (-not $script:IsAdmin) {
            Set-ItResult -Skipped -Because 'restoring the hosts file needs an elevated shell'
            return
        }
        Add-Content -LiteralPath $script:Hosts -Value '127.0.0.1 adskdoctor-undo-test.invalid'
        Get-HostsText | Should -Match 'adskdoctor-undo-test'

        [void](& $script:PsExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:BackupDir 'UNDO.ps1') 2>&1)

        Get-HostsText | Should -Not -Match 'adskdoctor-undo-test'
        Get-HostsHash | Should -Be $script:HostsHash -Because 'UNDO has to restore the captured state'
    }
}

Describe 'Diagnostic report' {
    It 'stays read-only and produces a valid report' {
        $json = Join-Path $script:Tmp 'report.json'
        [void](Invoke-ToolScript 'AdskDoctor.ps1' @('-Json', $json))

        Get-HostsHash | Should -Be $script:HostsHash -Because 'the diagnostic is read-only'
        Test-Path -LiteralPath $json | Should -BeTrue
        $report = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        @($report.Findings).Count | Should -BeGreaterThan 5
        @($report.Findings | Select-Object -ExpandProperty Category -Unique) | Should -Contain 'IFEO'
        @($report.Findings | Select-Object -ExpandProperty Category -Unique) | Should -Contain 'Licensing'
    }

    It 'flags an AdskLicensing build older than the named-user baseline' {
        if (-not $script:IsAdmin) {
            Set-ItResult -Skipped -Because 'the licensing stack lives under Program Files (needs elevation)'
            return
        }
        if (Test-Path -LiteralPath $script:FakeLic) {
            Set-ItResult -Skipped -Because 'a real AdskLicensing folder is installed here'
            return
        }
        New-Item -ItemType Directory -Force -Path $script:FakeLic | Out-Null
        Set-Content -LiteralPath (Join-Path $script:FakeLic 'version.ini') -Value 'Version=9.1.0.0' -Encoding ASCII
        $script:FakeLicMade = $true

        $out = Invoke-ToolScript 'AdskDoctor.ps1'

        $out | Should -Match 'AdskLicensing \(ADLS\) is 9\.1\.0\.0'
        $out | Should -Match 'older than the 10\.0\.0\.0 baseline'
    }

    It 'does not report data files as signature failures (this reached a customer as 322 FAILs)' {
        if (-not $script:IsAdmin) {
            Set-ItResult -Skipped -Because 'the licensing stack lives under Program Files (needs elevation)'
            return
        }
        if (Test-Path -LiteralPath $script:FakeLic) { Remove-Item -LiteralPath $script:FakeLic -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path $script:FakeLic | Out-Null
        # Data files carry no Authenticode signature at all: none of them may be
        # reported as invalid, no matter what the signature API answers.
        Set-Content -LiteralPath (Join-Path $script:FakeLic 'version.ini')         -Value 'Version=16.0.3.14414' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:FakeLic 'sdk-msg-en-US.json') -Value '{ }' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:FakeLic 'avatar.png')         -Value 'png' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:FakeLic 'artifakt.ttf')       -Value 'ttf' -Encoding ASCII
        $script:FakeLicMade = $true

        $json = Join-Path $script:Tmp 'sigreport.json'
        [void](Invoke-ToolScript 'AdskDoctor.ps1' @('-Json', $json))
        $rep = Get-Content -LiteralPath $json -Raw | ConvertFrom-Json
        $sigBad = @($rep.Findings | Where-Object { $_.Status -eq 'BAD' -and $_.Category -eq 'Signatures' })
        $sigBad.Count | Should -Be 0 -Because 'a JSON, PNG or font file has no signature to be invalid'
    }
}

Describe 'Regression guards' {
    It 'the Undo picker dialog declares the x namespace (it silently killed the whole dialog)' {
        $gui = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor-GUI.ps1') -Raw
        $gui | Should -Match 'xmlns:x="http://schemas\.microsoft\.com/winfx/2006/xaml"'
    }

    It 'the UI still opens in English' {
        $gui = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor-GUI.ps1') -Raw
        $gui | Should -Match "\[string\]\`$Lang\s*=\s*'en'"
    }

    It 'the release workflow installs ps2exe for Windows PowerShell 5.1 (the build used to fail)' {
        $wf = Get-Content -LiteralPath (Join-Path $script:Root '.github\workflows\release-sign.yml') -Raw
        $wf | Should -Match 'Install-Module ps2exe -Scope CurrentUser -Force'
        $wf | Should -Match 'powershell -NoProfile -ExecutionPolicy Bypass -Command'
    }

    It 'never pairs -Include with -LiteralPath (Get-ChildItem silently ignores the filter)' {
        # A folder scan that used "-LiteralPath ... -Include *.exe" really scanned
        # every file, and every JSON/font/PNG came back as "INVALID signature":
        # 322 of those reached a customer on a healthy machine.
        foreach ($name in @('AdskDoctor.ps1', 'Clean.ps1', 'Purge.ps1', 'Repair.ps1', 'Backup.ps1')) {
            $text = Get-Content -LiteralPath (Join-Path $script:Root $name) -Raw
            $text | Should -Not -Match '-LiteralPath[^\r\n]*-Include' -Because "$name must filter file lists itself"
        }
    }

    It 'the cleanup resets the legacy ADLM licence cache and the backup covers it' {
        # ProductInformation.pit (ProgramData\Autodesk\Adlm) is a classic
        # non-genuine activation leftover, so the cleanup removes it - which is
        # only safe because the backup layer captures it first.
        $clean  = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1')  -Raw
        $backup = Get-Content -LiteralPath (Join-Path $script:Root 'Backup.ps1') -Raw
        $clean  | Should -Match 'Autodesk\\Adlm'
        $backup | Should -Match 'Autodesk\\Adlm'
    }

    It 'removes the Autodesk Network License Manager service (AdskNLM)' {
        # Clean-up used to match only "flexnet|flexlm" and the display name
        # "Network License Manager", so a leftover AdskNLM service pointing at
        # deleted binaries survived on a customer machine.
        $clean = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1') -Raw
        $clean | Should -Match 'adsknlm'
    }

    It 'keeps a genuine Flexera service and removes only dead or suspicious FlexNet ones' {
        # the lab run deleted FNPLicensingService64.exe (Flexera-signed, under
        # Program Files\Common Files\Macrovision Shared) because the service
        # name matched "flexnet". Only a missing binary or a suspicious path is
        # crack tooling - a signed vendor binary in Program Files is genuine.
        $clean = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1') -Raw
        $clean | Should -Match 'Test-CrackFlexService'
        $clean | Should -Match 'Macrovision'
    }

    It 'does not treat its own process as a suspicious Autodesk process' {
        # "UNLOCK-DIGITAL-AdskDoctor" matches the "adsk" pattern and the portable
        # build runs from a user profile, so the toolkit reported itself as FAIL.
        $diag = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $diag | Should -Match "ProcessName -notmatch 'adskdoctor\|unlock-digital'"
    }

    It 'checks the WebView2 runtime that renders the sign-in window' {
        # A product that fails with a licensing error *before* it shows the
        # "Sign in with your Autodesk ID" page usually has no WebView2 runtime.
        $diag = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $diag | Should -Match 'WebView2'
        $diag | Should -Match '\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5\}'
    }

    It 'installs the official WebView2 runtime when given the installer' {
        # the sign-in window cannot render without WebView2, and it is not part
        # of Windows, so Repair has to be able to install it
        $repair = Get-Content -LiteralPath (Join-Path $script:Root 'Repair.ps1') -Raw
        $repair | Should -Match '\[string\]\$WebView2Installer'
        $repair | Should -Match "Invoke-Pkg -Label 'WebView2'"
        $repair | Should -Match '/silent /install'
    }

    It 'never downloads a component (official installers only)' {
        # a licensing tool that pulls binaries off the internet is a security
        # problem, and it is the opposite of what this toolkit promises
        foreach ($name in @('Repair.ps1', 'AdskDoctor.ps1', 'Clean.ps1', 'Purge.ps1', 'Backup.ps1')) {
            $text = Get-Content -LiteralPath (Join-Path $script:Root $name) -Raw
            $text | Should -Not -Match 'Invoke-WebRequest[^\r\n]*\.(exe|msi)' -Because "$name must not download installers"
            $text | Should -Not -Match 'Start-BitsTransfer|DownloadFile|DownloadString'
        }
    }

    It 'resets the sign-in window profile (EBWebView) during a repair' {
        # a stale WebView2 profile makes a product fail before the sign-in page
        $repair = Get-Content -LiteralPath (Join-Path $script:Root 'Repair.ps1') -Raw
        $repair | Should -Match 'EBWebView'
        $repair | Should -Match 'AdskLicensingAgent'
    }

    It 'tells the operator where an official component comes from' {
        # Repair installs only what it is given and never downloads, so a missing
        # component has to come with directions
        $repair = Get-Content -LiteralPath (Join-Path $script:Root 'Repair.ps1') -Raw
        $repair | Should -Match 'manage\.autodesk\.com/products/all'
        $repair | Should -Match 'Show-ComponentSources'
        $repair | Should -Match 'x64\\AdskLicensing'
    }

    It 'checks the other sign-in prerequisites (identity, .NET, TLS, file renames)' {
        $diag = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $diag | Should -Match 'AdskIdentityManager'
        $diag | Should -Match 'NET Framework Setup'
        $diag | Should -Match 'SystemDefaultTlsVersions'
        $diag | Should -Match 'PendingFileRenameOperations'
        $diag | Should -Match 'TLS 1\.2 is disabled'
    }

    It 'collects the licensing logs into a support bundle' {
        # the agent log names the exact licensing failure, and asking a customer
        # to find it by hand does not work
        $diag = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $diag | Should -Match '\[switch\]\$Bundle'
        $diag | Should -Match 'Compress-Archive'
        $diag | Should -Match 'system-info\.txt'
    }

    It 'prints the failure lines of the newest log, with email addresses masked' {
        # "Licensing error - An error occurred" on screen says nothing, and the
        # log holds the reason; the report shows the lines itself. Logs can carry
        # the signed-in account, so addresses are masked.
        $diag = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $diag | Should -Match '-Tail 300'
        $diag | Should -Match '\*\*\*@\*\*\*'
    }

    It 'offers the support bundle and the installer folder in the UI' {
        $gui = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor-GUI.ps1') -Raw
        $gui | Should -Match 'x:Name="BtnBundle"'
        $gui | Should -Match "'-InstallerDir'"
        $gui | Should -Match 'FolderBrowserDialog'
    }

    It 'defines the same UI strings in Arabic and English' {
        # a key that exists in one table only renders as an empty button
        $gui = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor-GUI.ps1') -Raw
        $ar = [regex]::Match($gui, "(?s)ar = @\{(.*?)\n  \}").Groups[1].Value
        $en = [regex]::Match($gui, "(?s)en = @\{(.*?)\n  \}").Groups[1].Value
        $ar | Should -Not -BeNullOrEmpty
        $en | Should -Not -BeNullOrEmpty
        $key = '(?m)^\s{4}([A-Za-z][A-Za-z0-9]*)\s*='
        $arKeys = @([regex]::Matches($ar, $key) | ForEach-Object { $_.Groups[1].Value })
        $enKeys = @([regex]::Matches($en, $key) | ForEach-Object { $_.Groups[1].Value })
        @(Compare-Object $arKeys $enKeys) | Should -BeNullOrEmpty -Because 'both languages need the same keys'
    }

    It 'does not ship a README that carries the hashes of its own archives' {
        # The README travels inside the project / portable / installer payloads,
        # so a hash block in it is one release old for whoever opens the zip and
        # checks. The staged copy points at SHA256SUMS.txt instead, and all three
        # archives must take that copy rather than the file in the repository.
        $build = Get-Content -LiteralPath (Join-Path $script:Root 'Build-Release.ps1') -Raw
        $build | Should -Match '\$readmeShipped'
        @([regex]::Matches($build, [regex]::Escape('Copy-Item $readmeShipped'))).Count |
            Should -Be 3 -Because 'project, portable and installer payload all need it'
        @([regex]::Matches($build, [regex]::Escape("Copy-Item (Join-Path `$root 'README.md')"))).Count |
            Should -Be 0 -Because 'the root README keeps the hash block for the repo only'
    }
}

Describe 'Field-gap guards' {
    # Gaps found by comparing a real non-genuine install with the toolkit: the
    # RunOnce keys, the blocked time servers and the Defender exclusions a
    # crack leaves behind, plus the backup/undo coverage for them.

    It 'watches RunOnce as well as Run under Startup entries' {
        $diag = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $diag | Should -Match 'CurrentVersion\\RunOnce'
    }

    It 'reports the Defender exclusions that hide patched files' {
        $diag = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $diag | Should -Match '\.ExclusionPath'
        $diag | Should -Match '\.ExclusionProcess'
        $diag | Should -Match 'crack-related path'
    }

    It 'removes crack startup entries (Run / RunOnce) during the clean-up' {
        $clean = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1') -Raw
        $clean | Should -Match 'CurrentVersion\\RunOnce'
        $clean | Should -Match 'Remove-ItemProperty'
    }

    It 'removes crack-related Defender exclusions, and the backup can restore them' {
        $clean  = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1')  -Raw
        $backup = Get-Content -LiteralPath (Join-Path $script:Root 'Backup.ps1') -Raw
        $clean  | Should -Match 'Remove-MpPreference'
        $backup | Should -Match 'defender-exclusions'
        $backup | Should -Match 'Add-MpPreference'
        $backup | Should -Match 'CurrentVersion\\RunOnce'
    }

    It 'removes hosts lines that block the Windows time servers' {
        # the diagnostic saw these since 1.2.x; the clean-up used to keep them
        $clean = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1') -Raw
        $clean | Should -Match 'time\\\.windows'
        $clean | Should -Match 'Test-BadHostsLine'
    }

    It 'covers the C:\FlexLM crack folder in diagnose, clean and backup' {
        # the fake FLEXlm server folder is the classic crack drop, but the
        # clean-up left it behind and no backup layer captured it
        $diag   = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $clean  = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1')  -Raw
        $backup = Get-Content -LiteralPath (Join-Path $script:Root 'Backup.ps1') -Raw
        $diag   | Should -Match 'C:\\FlexLM'
        $clean  | Should -Match 'C:\\FlexLM'
        $backup | Should -Match 'C:\\FlexLM'
    }

    It 'treats FlexLM-style paths as suspicious wherever they appear' {
        # a crack task / Run value / env var pointing at C:\FlexLM was listed
        # as plain INFO (the real-machine test caught this on 2026-10-16):
        # the path classifier only knew AppData/Temp/ProgramData
        $diag = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $diag | Should -Match 'flexlm\|adskflex\|lmgrd'
        $diag | Should -Match 'envHits'
    }

    It 'scans for patched copies and licpath files, and clears a renamed profile' {
        $diag   = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $clean  = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1')  -Raw
        $repair = Get-Content -LiteralPath (Join-Path $script:Root 'Repair.ps1') -Raw
        $diag   | Should -Match '_orig\|patched\|licpath'
        $clean  | Should -Match '_orig\|patched\|licpath'
        $repair | Should -Match 'EBWebView\*'
    }

    It 'resolves unquoted paths with spaces so the genuine Genuine-Service entry is kept' {
        # the real-machine run removed the genuine "Autodesk Genuine Service"
        # Run value: its unquoted path was not resolved to an exe, so it
        # looked like a dead leftover
        $clean = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1')  -Raw
        $diag  = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $clean | Should -Match '\.\+\?\\\.exe'
        $diag  | Should -Match '\.\+\?\\\.exe'
    }

    It 'removes a scheduled task whose action is a crack path (the C:\FlexLM case)' {
        # the real-machine run left the crack task behind: the task check only
        # knew the user folders, so C:\FlexLM\adskflex.exe was not suspicious
        $clean = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1') -Raw
        $clean | Should -Match 'Test-SuspiciousExecPath'
    }

    It 'verifies and retries the hosts write when an antivirus locks the file' {
        $clean = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1') -Raw
        $clean | Should -Match 'stayed locked'
    }

    It 're-points the licensing Current junction at the newest genuine build (the real-machine case)' {
        # the real-machine run re-pointed Current at a fake 8.1.2.0 stub build:
        # Repair.ps1 only restarted the service, so the doctor kept reporting
        # the tampered junction after the repair. The repair now fixes it.
        $repair = Get-Content -LiteralPath (Join-Path $script:Root 'Repair.ps1') -Raw
        $repair | Should -Match 'mklink /J'
        $repair | Should -Match 'Test-GenuineAdlsBuild'
        $repair | Should -Match 'Remove non-genuine licensing build folder'
    }

    It 'skips components that are already present and can never hang on an installer' {
        # the lab run passed a whole product image to -InstallerDir: the Edge
        # WebView2 bootstrapper then stayed alive forever in a background
        # session and held the whole repair. Components that are present are
        # skipped, and an installer that does not exit is killed at the timeout.
        $repair = Get-Content -LiteralPath (Join-Path $script:Root 'Repair.ps1') -Raw
        $repair | Should -Match 'already present - install skipped'
        $repair | Should -Match 'WaitForExit\('
        $repair | Should -Match 'still running after'
    }

    It 'the backup captures the loose crack files the clean-up deletes' {
        # the lab clean-up deleted Common Files\Autodesk Shared\adskflex.exe and
        # the product-tree leftovers (_orig / .bak / licpath / patched); nothing
        # had captured them, so the toolkit UNDO could not bring them back
        $backup = Get-Content -LiteralPath (Join-Path $script:Root 'Backup.ps1') -Raw
        $backup | Should -Match 'loose crack files backed up'
        $backup | Should -Match 'adskflex'
    }

    It 'never follows the licensing Current junction while backing up or restoring' {
        # robocopy /E follows junctions: the lab backup stored the doctored
        # 8.1.2.0 build under a real "Current" folder, and UNDO then copied its
        # files through the junction into the genuine 17.0.0.16519 build
        $backup = Get-Content -LiteralPath (Join-Path $script:Root 'Backup.ps1') -Raw
        $backup | Should -Match '/XJ'
    }

    It 'does not walk through junctions while scanning licensing folders' {
        # Windows PowerShell 5.1 Get-ChildItem -Recurse follows junctions: the
        # dummy behind AdskLicensing\Current was counted once through the
        # junction and once in the real build ("2 unsigned" for one file)
        $diag = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor.ps1') -Raw
        $diag | Should -Match 'Get-TreeFilesQuiet'
        $diag | Should -Match 'ReparsePoint'
    }

    It 'clears the ODIS cache quietly, noting files a running process locks' {
        # the lab clean-up sprayed raw Remove-Item errors while the cache
        # database was still locked during shutdown of an Autodesk process
        $clean = Get-Content -LiteralPath (Join-Path $script:Root 'Clean.ps1') -Raw
        $clean | Should -Match 'they clear after reboot'
    }

    It 'installs the licensing service with its official unattended parameters' {
        # from the package manifest itself (x86\Licensing\pkg.licensing.xml):
        # installParams="--mode unattended --unattendedmodeui none".
        # The '/S' style was silently ignored by this InstallBuilder package.
        $repair = Get-Content -LiteralPath (Join-Path $script:Root 'Repair.ps1') -Raw
        $repair | Should -Match '--mode unattended --unattendedmodeui none'
    }
}

Describe 'Full removal (Purge.ps1)' {
    # Phase 5 answers the customer case "I do not want a repair - take
    # everything Autodesk off this machine so I can install a clean copy".

    It 'without -Apply changes nothing and lists what would be removed' {
        $out = Invoke-ToolScript 'Purge.ps1'
        $out | Should -Match 'Phase 5'
        $out | Should -Match 'PREVIEW only - nothing was changed'
        $out | Should -Not -Match '\[ done \]'
        Get-HostsHash | Should -Be $script:HostsHash -Because 'a preview must not rewrite the hosts file'
    }

    It 'keeps the mandatory backup gate and never touches its own process' {
        $purge = Get-Content -LiteralPath (Join-Path $script:Root 'Purge.ps1') -Raw
        $purge | Should -Match 'mandatory backup \(Phase 2\)'
        $purge | Should -Match 'AdskDoctor\|UNLOCK'
        $purge | Should -Match 'Backup\.ps1'
    }

    It 'uninstalls officially first, then sweeps every known Autodesk area' {
        $purge = Get-Content -LiteralPath (Join-Path $script:Root 'Purge.ps1') -Raw
        $purge | Should -Match 'bundleManifest\.xml'
        $purge | Should -Match 'msiexec'
        $purge | Should -Match 'sc\.exe delete'
        $purge | Should -Match 'FLEXlm License Manager'
        $purge | Should -Match 'FlexLM'
        $purge | Should -Match 'Autodesk Shared'
        $purge | Should -Match 'Broken MSI registrations'
    }

    It 'verifies afterwards that nothing Autodesk survived' {
        $purge = Get-Content -LiteralPath (Join-Path $script:Root 'Purge.ps1') -Raw
        $purge | Should -Match 'VERIFIED: no Autodesk components remain'
        $purge | Should -Match 'locked files usually clear after a reboot'
    }

    It 'the UI carries the two top-bar buttons: download and full removal' {
        $gui = Get-Content -LiteralPath (Join-Path $script:Root 'AdskDoctor-GUI.ps1') -Raw
        $gui | Should -Match 'x:Name="BtnPurge"'
        $gui | Should -Match "T 'purgeText'"
        $gui | Should -Match "T 'purgeWarn'"
        # the download button used to sit in the action panel (Height 38);
        # it now lives in the header, in front of the language toggle
        $gui | Should -Not -Match 'BtnDownload[^>]*Height="38"'
        $gui | Should -Match 'BtnDownload[\s\S]{0,600}BtnPurge[\s\S]{0,600}BtnLang'
    }
}
