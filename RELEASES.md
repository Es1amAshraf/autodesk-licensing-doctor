# UNLOCK DIGITAL - Autodesk Licensing Doctor - Releases

## v1.2.6  (2026-10-15 21:48:56)

Everything a sign-in failure needs, in one pass.

New checks (read-only):
- Microsoft Edge WebView2 runtime. Autodesk renders the "Sign in with your
  Autodesk ID" window with it, and without it a product fails with "Licensing
  error - An error occurred" BEFORE the sign-in page ever appears.
- The identity component (AdskIdentityManager). Products from 2020 on sign in
  through it, and it is a separate component from the licensing service.
- .NET Framework 4.8+, which the licensing and sign-in interface is built on.
- TLS 1.2 / strong crypto settings that block HTTPS to accounts.autodesk.com
  (the old "harden TLS" tweak breaks sign-in), plus the SCHANNEL client entry.
- Pending file renames: the third reboot flag, and the one that makes installers
  fail with error 1603.
- The newest licensing logs are listed, because the agent log names the exact
  licensing failure.

New: support bundle
- AdskDoctor.ps1 ... -Bundle (or the Support bundle button) collects the report,
  the licensing logs and system-info.txt into one zip to send with a support
  request.

Repair:
- -WebView2Installer installs the official Microsoft WebView2 runtime quietly.
- The sign-in window profile (EBWebView) is reset: a stale session there makes a
  product fail before the window opens.
- The product's own install image is searched for the official components
  (x64\AdskLicensing, x64\AdSSO, x64\Components\*\Genuine*).
- If a component is missing and no installer was supplied, it now prints exactly
  where to get the official one. It still never downloads anything.

UI:
- New Support bundle button, a folder picker so Repair can be pointed at the
  official installers you already have, and the app version in the header.

Tests: 21 Pester tests in CI, including two policy guards - no script downloads a
component, and both UI languages must define the same strings.

Includes everything from v1.2.5 and v1.2.4: the toolkit no longer reports itself
as a suspicious process, only real binaries are signature-scanned (a healthy
machine used to show 322 false failures), the leftover AdskNLM service and the
legacy ADLM licence cache are removed, UNDO.ps1 recreates deleted services, and
the report groups problems by area with a verdict that names the fixing step.

- `AdskDoctor-v1.2.6-Project.zip`  -  0.13 MB  -  SHA256 `74DD03EA9D29596397E97E395862C3F92872C656F9B2923C4A386BF24C8209DA`
- `AdskDoctor-v1.2.6-Portable.zip`  -  0.14 MB  -  SHA256 `7A0F6A6CC21BA60848DF9ABA0643E7DB5055CDF1FD038481EE1A1DB5B5FE5CE7`
- `UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.6.exe`  -  2.11 MB  -  SHA256 `6B537C2E29DC398A86416164E1744E103FA48BA4F729C98861B6CE4310E5C934`

## v1.2.5  (2026-10-15 21:27:13)

Report accuracy follow-up (v1.2.4 stopped the false signature failures; this
build removes the last false failure and one leftover the cleanup missed).

Fixed:
- The toolkit no longer reports *itself* as a suspicious running process. Its
  name contains "adsk" and the portable build runs from a user profile, so its
  own process showed up as a red FAIL row in its own report.
- The running-process check now decides by the signature of the binary instead
  of the folder it lives in: Autodesk ships genuine per-user products (Access,
  Fusion) under %LOCALAPPDATA%, and their processes are no longer suspicious.
  A patched (broken signature) or unsigned Autodesk-named process still fails.
- Cleanup now removes the Autodesk Network License Manager service (AdskNLM).
  It matched only "flexnet|flexlm" and the display name "Network License
  Manager" before, so on a customer machine the service survived pointing at
  deleted binaries.

Improved:
- UNDO.ps1 recreates services that the cleanup removed. A deleted service cannot
  be restored from a file copy, so the rollback promise did not hold for them.

Includes everything from v1.2.4: only real binaries are signature-scanned (data
files are no longer reported as patched), no false license-server / AdSSO /
AdskLicensingAgent warnings, new ADLS + IFEO + stale-service checks, the legacy
ADLM licence cache is reset, and the verdict names the step to run.

- `AdskDoctor-v1.2.5-Project.zip`  -  0.13 MB  -  SHA256 `295265925696916C3C71DA0E1F9FD7DA7C726EB32EAAA5367EE15F636965C777`
- `AdskDoctor-v1.2.5-Portable.zip`  -  0.14 MB  -  SHA256 `7FE7653D4B97B4594D5C6223EEE7F884C06BC50F880D97F3DDCE5C39163C73CC`
- `UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.5.exe`  -  2.1 MB  -  SHA256 `4D897959749BE2E23B1E6A1D72D632620203A030FBB928D0F1322FB13C612935`

## v1.2.4  (2026-10-15 21:04:19)

Diagnostic accuracy release.

Fixed (a customer machine reported 322 failures that were not real):
- The signature scan asked Windows for the signature of *every* file in the
  licensing folders, including JSON, fonts and images, and reported each one as
  "INVALID signature - patched/cracked". Data files carry no signature at all,
  so a healthy machine showed hundreds of failures. Only real binaries are
  scanned now, and only a broken signature counts as patched.
- The same PowerShell pitfall produced false "license-server binary found"
  warnings for normal folders (Adlm, VBAServer, AdskLicensing...).
- "AdSSO component not found" no longer warns on machines where the sign-in
  client lives inside AdskLicensing (current ADLS releases).
- "AdskLicensingAgent not found" was wrong: the agent is not a Windows service.

New checks:
- AdskLicensing (ADLS) and AdSSO build reporting.
- ADLS "Current" link: warns when it points at an older build than the one
  installed (a known cause of "Licensing error - An error occurred").
- Services whose binaries no longer exist (leftover Network License Manager).
- IFEO execution blockers (a Debugger value that stops Autodesk executables).

Cleanup:
- The legacy ADLM licence cache (ProgramData\Autodesk\Adlm with
  ProductInformation.pit) is now reset, and the backup layer captures it first,
  so UNDO still restores the previous state.

Reporting:
- The verdict now names the step that fixes the machine (cleanup / repair /
  product reinstall) instead of calling everything "needs cleaning".
- Problems and warnings are grouped by area in the console, the text and the
  HTML report, and a machine without Autodesk installed is no longer reported as
  broken.

Tests:
- A Pester suite (preview purity, backup + UNDO, report validity, ADLS baseline,
  regression guards for the bugs above) runs on every push.

- `AdskDoctor-v1.2.4-Project.zip`  -  0.12 MB  -  SHA256 `CB84238FE20AF05935BEF0F739F47DC55E2363CB25D51BF8AE8AD1634AF6C45D`
- `AdskDoctor-v1.2.4-Portable.zip`  -  0.13 MB  -  SHA256 `E9FCB9BCE1B03042A294AEBED5F26F5E0ACF2A3BB188E503AA5CCCB86BC7E142`
- `UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.4.exe`  -  2.1 MB  -  SHA256 `03610B0E51E075775B934CAE8DC662BFFEE01F32576322249647DDCA257F263D`

## v1.2.3  (2026-10-15 20:05:06)

Fixed the Roll back (Undo) picker, which failed to open and showed a cascade of
errors instead of listing the backups. English is now the default UI language;
the in-app toggle still switches to Arabic. The installer now also removes
`report.html` / `report.json` on uninstall.

- `AdskDoctor-v1.2.3-Project.zip`  -  0.12 MB  -  SHA256 `1C760829D4B79FCA25A19F941CF7DEF72D3A9327AF2E8E166D59BF5B77F261A5`
- `AdskDoctor-v1.2.3-Portable.zip`  -  0.13 MB  -  SHA256 `398AB4D70D120BD295447759EAEA79061FFE3BED73EE63E9EB511FD2BA9DB439`
- `UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.3.exe`  -  2.1 MB  -  SHA256 `C81072D329427B3428D0E51F61A68E3DF8C844B7C2E60CA1A5C65AF0FB043075`

## v1.2.2  (2026-10-15 19:20:35)  — WITHDRAWN, use v1.2.3

Fixes the crash when the cleanup actually changed the machine: the process step matched the toolkit's own executable (UNLOCK-DIGITAL-AdskDoctor) and stopped it. The toolkit's process tree is now excluded.

**Withdrawn:** the Roll back (Undo) picker in this build never opened - it failed
with a series of errors. The published binaries were removed from the GitHub
release; the local copies below were kept for the record. Use v1.2.3.

- `AdskDoctor-v1.2.2-Project.zip`  -  0.12 MB  -  SHA256 `5315C7B629F6F72D21883ACF5B9E4E367D5BCEDFD472BD58941A4BD5077AC168`
- `AdskDoctor-v1.2.2-Portable.zip`  -  0.13 MB  -  SHA256 `55BCFA05D6653C5EE2307ED94051784368C1EB2AEFFBB02A8954073822CC52BC`
- `UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.2.exe`  -  2.1 MB  -  SHA256 `8B7D46B0E3D9C4D7C7DE051FC4C40D80EF87D23A169B1FECF35FDD5694361E03`

## v1.2.1  (2026-10-15 19:02:23)  — WITHDRAWN, use v1.2.3

Fixes a crash that closed the application as soon as a task started in the compiled build (installer and portable package). The bilingual AR/EN GUI is unchanged.

**Withdrawn:** this build still stopped its own process when the cleanup was applied.
The published binaries were removed from the GitHub release; the local copies below
were kept for the record. Use v1.2.3.

- `AdskDoctor-v1.2.1-Project.zip`  -  0.12 MB  -  SHA256 `3329E85CDBE9D8097C893E0B7C9D081BFE110E704A8172228D2A7245192BDA66`
- `AdskDoctor-v1.2.1-Portable.zip`  -  0.13 MB  -  SHA256 `E59EC55E4217CB2D31E7C79209669D1A1D9EDB7E308ECEA8016AE4CC32408EB9`
- `UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.1.exe`  -  2.1 MB  -  SHA256 `A9A28A00DE02F48A4396E37CF060CCC00EFFB62879887C834187F40A1D16DD0E`

## v1.2.0  (2026-10-15 17:50:01)  — WITHDRAWN, use v1.2.3

Initial release. Phases 1-4 (Diagnostic, Layered Backup, Cleanup, Repair). Bilingual AR/EN WPF GUI. Real .exe installer (Inno Setup) branded with the UNLOCK DIGITAL logo. MIT.

**Withdrawn:** in this build the application closed itself as soon as a task started
(Scan, Backup, Cleanup, Repair). The published binaries were removed from the GitHub
release; the local copies below were kept for the record. Use v1.2.3.

- `AdskDoctor-v1.2.0-Project.zip`  -  0.11 MB  -  SHA256 `6BC7007D124F151D10A056757CD05ACE1970552EE34C044F14AE47E8A4692CBF`
- `AdskDoctor-v1.2.0-Portable.zip`  -  0.13 MB  -  SHA256 `3BDB50C4A5D8FBC76F5460C991EE8D472E789503329220B61AD7D5D8116C6562`
- `UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.0.exe`  -  2.1 MB  -  SHA256 `E9E8D659EA3FD862174325B75635BA321F07578B4FF8A38EAAEABF5DF8C928AD`

