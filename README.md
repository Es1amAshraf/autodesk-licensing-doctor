# Autodesk Licensing Doctor

[![CI](https://github.com/Es1amAshraf/autodesk-licensing-doctor/actions/workflows/ci.yml/badge.svg)](https://github.com/Es1amAshraf/autodesk-licensing-doctor/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Es1amAshraf/autodesk-licensing-doctor?label=release)](https://github.com/Es1amAshraf/autodesk-licensing-doctor/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue)](#)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE)](https://microsoft.com/powershell)

**UNLOCK DIGITAL** — *By Eng. Eslam Ashraf*

A portable Windows toolkit for Autodesk resellers and IT pros that **removes
leftover cracked ("non-genuine") Autodesk artifacts** and **restores healthy
official single-user subscription licensing** (`ADLS` + `AdSSO`), so genuine
products activate and run normally again.

Windows 10 / 11 · GUI in **Arabic + English** · no installation required.

---

## ⚖️ Legal & ethical notice

This project exists to **clean up** machines that were previously patched with
cracked software and to **restore the official Autodesk licensing stack**.

* It **does not** include, generate, distribute or bypass any license.
* It **does not** patch or crack Autodesk products.
* A valid **Autodesk subscription / license** is still required to use Autodesk
  software.
* It removes non-genuine leftovers and repairs official components so that a
  legitimate sign-in (single-user) subscription works.

You are responsible for complying with the Autodesk Terms of Service and all
applicable laws in your jurisdiction.

---

## How it works — 4 phases

| Phase | Purpose | Changes system? |
|-------|---------|-----------------|
| **1** | Deep read-only diagnostic (~19 checks) | no |
| **2** | Layered backup + generated `UNDO.ps1` | writes backup only |
| **3** | Safe cleanup of crack remains | **preview by default** — needs `-Apply` |
| **4** | Repair / reinstall official licensing components (ADLS, AdSSO) | **preview by default** — needs `-Apply` |

**Safety model:** backup always runs first, cleanup/repair do **nothing** until
you explicitly pass `-Apply`, and every change is reversible through the
backup's `UNDO.ps1`.

---

## Quick start

### Installer (recommended) — single `.exe`

1. Download **`UNLOCK-DIGITAL-AdskDoctor-Setup-<version>.exe`** from the
   [Releases](../../releases) page.
2. Run it and accept the UAC prompt — it installs to
   `%ProgramFiles%\UNLOCK DIGITAL\AdskDoctor` and creates Desktop / Start Menu
   shortcuts, all branded with the **UNLOCK DIGITAL** logo.
3. Launch **Autodesk Licensing Doctor** from the shortcut.
4. Uninstall any time from **Settings → Apps** (or the Start Menu).

### Portable

1. Download `AdskDoctor-v<version>-Portable.zip` from Releases and extract it.
2. Run **`UNLOCK-DIGITAL-AdskDoctor.exe`** (accept the UAC prompt) → bilingual GUI opens.
3. Keep all files in the same folder — the app calls the `.ps1` scripts sitting
   next to the `.exe`.

---

## Command line

The engine is scriptable too (all scripts run read-only/preview unless `-Apply`):

```powershell
# Phase 1 — diagnostic (writes report.html and opens it)
powershell -ExecutionPolicy Bypass -File .\AdskDoctor.ps1 -Html -Export report.html

# Phase 2 — layered backup (restore point + .reg exports + file copies + UNDO.ps1)
powershell -ExecutionPolicy Bypass -File .\Backup.ps1

# Phase 3 — cleanup (preview first!)
powershell -ExecutionPolicy Bypass -File .\Clean.ps1
powershell -ExecutionPolicy Bypass -File .\Clean.ps1 -Apply

# Phase 4 — repair / reinstall official components
powershell -ExecutionPolicy Bypass -File .\Repair.ps1
powershell -ExecutionPolicy Bypass -File .\Repair.ps1 -Apply
```

---

## What Phase 1 checks (read-only)

System readiness · clock / time sync ("Clock Error") · installer health
("Error 1603") · `hosts` hijacking · firewall blocks · Autodesk/FlexNet
services · deep Authenticode scan of `AdskLicensing`/`AdSSO` · legacy
**Network License Manager** · ODIS installer cache, antivirus and logs
("Unable to install") · **ADLS** connection health ("Connection Lost") ·
product binaries · **crack leftovers** (`ProgramData\FLEXnet`,
`ProductInformation.pit`, `crack`/`keygen`/`adskflex`/`lmgrd`) · registry
hijacks · environment variables · scheduled tasks · startup entries · running
processes · fake local license servers (FLEXlm ports) · connectivity to
Autodesk endpoints + DNS hijack detection · WinHTTP proxy.

Every finding is tagged `OK` / `WARN` / `FAIL` / `info` with a final verdict.

---

## Layered backup (does *not* rely on System Restore)

System Restore is often disabled or blocked by group policy on customer
machines, so the backup is layered — layers 2–5 do not depend on VSS:

| Layer | What | Needs VSS? |
|-------|------|-----------|
| 1 | System Restore point (best effort) | yes |
| 2 | `.reg` export of every touched key | no |
| 3 | File/folder copies (hosts, AdskLicensing, AdSSO, FLEXnet, NLM) | no |
| 4 | State snapshots (services, firewall, tasks, env) | no |
| 5 | `UNDO.ps1` that reverses layers 2–4 | no |

---

## Build from source

Requirements: **PowerShell 5.1+**, the [`ps2exe`](https://github.com/MScholtes/PS2EXE)
module and [Inno Setup 6](https://jrsoftware.org/isinfo.php) (for the installer `.exe`).

```powershell
# compile the exe and cut a release (Project.zip + Portable.zip + Setup.exe + record)
.\Build-Release.ps1 -Version 1.2.0 -Notes "..." -Recompile
```

Each release is stored under `releases\v<version>\` in **three forms**:

| Artifact | Contents |
|----------|----------|
| `AdskDoctor-v<ver>-Project.zip` | full source files |
| `AdskDoctor-v<ver>-Portable.zip` | run anywhere, no install |
| `UNLOCK-DIGITAL-AdskDoctor-Setup-<ver>.exe` | real installer (Inno Setup), branded icon |

…plus `RELEASE-RECORD.txt`, `manifest.json` and `SHA256SUMS.txt`, and an entry
appended to `RELEASES.md`. Pass `-LegacySetupZip` to emit the old
`-Setup.zip` script installer instead of the `.exe`.

### Signed releases (CI)

`.github/workflows/release-sign.yml` runs on `windows-latest`, builds the app
exe, signs it, then builds the zips + installer around the **signed** exe,
signs the installer too, and publishes the Release. Signing uses
[SignPath](https://signpath.org), which is **free for open-source projects**.
Repository configuration needed:

| Kind | Name | Value |
|------|------|-------|
| secret | `SIGNPATH_API_TOKEN` | SignPath API token with *submitter* permission |
| variable | `SIGNPATH_ORGANIZATION_ID` | your SignPath organization id |
| variable | `SIGNPATH_PROJECT_SLUG` | e.g. `autodesk-licensing-doctor` |
| variable | `SIGNPATH_SIGNING_POLICY_SLUG` | e.g. `release-signing` |

…plus the two artifact configurations (`app-exe`, `setup-exe`) created in
SignPath from the files in `.signpath/`. Apply for the free OSS certificate at
<https://signpath.org/apply>.

**Alternative — sign locally with your own certificate.** If you hold a code
signing certificate (e.g. Certum Open Source Code Signing, or an OV
certificate), sign the built binaries yourself:

```powershell
.\Sign.ps1 -List                                    # show usable certificates
.\Sign.ps1 -Path .\releases\v1.2.1\*.exe -Thumbprint <sha1>
.\Sign.ps1 -Verify -Path .\releases\v1.2.1\*.exe     # check a release
```

---

## Project layout

| Path | Purpose |
|------|---------|
| `AdskDoctor-GUI.ps1` | WPF bilingual (AR/EN) GUI |
| `AdskDoctor.ps1` | Phase 1 — diagnostic engine |
| `Backup.ps1` | Phase 2 — layered backup + `UNDO.ps1` generator |
| `Clean.ps1` | Phase 3 — cleanup (preview by default) |
| `Repair.ps1` | Phase 4 — repair / reinstall official components |
| `Build-Release.ps1` | release builder (Project/Portable zips + Setup.exe + record) |
| `installer/` | `AdskDoctor.iss` (Inno Setup) + `Install.cmd` / `Install.ps1` / `Uninstall.*` |
| `make-icon.ps1` | generates `AdskDoctor.ico` (app icon) |
| `make-logo-icon.ps1` | generates `unlock-logo.ico` (installer / brand icon) from `unlock-logo.png` |
| `.signpath/` | SignPath artifact configurations (`app-exe`, `setup-exe`) |
| `.github/workflows/release-sign.yml` | CI: build → sign with SignPath → publish release |
| `.github/workflows/ci.yml` | CI: parse + lint + config validation |
| `Publish-Release.ps1` | one-command release: build → commit → push → publish |
| `Sign.ps1` | Authenticode-sign release binaries with your own certificate (local alternative to CI signing) |
| `SIGNPATH-SETUP.md` | step-by-step guide to enabling code signing |
| `CODE-SIGNING.md` | code signing policy |
| `PRIVACY.md` | privacy policy |
| `SECURITY.md` | security policy / how to report a vulnerability |
| `Run-Diagnostic.cmd`, `Run-Backup.cmd` | self-elevating launchers |

---

## Code signing policy

**Code signing policy:** free code signing provided by
[SignPath.io](https://about.signpath.io), certificate by
[SignPath Foundation](https://signpath.org).

Official release binaries (the application `.exe` and the installer `.exe`) are
compiled on GitHub-hosted runners and signed through SignPath before they are
published. Roles, the exact list of signed artifacts, the pipeline and
verification instructions are in **[CODE-SIGNING.md](CODE-SIGNING.md)**.

Verify a downloaded file:

```powershell
Get-AuthenticodeSignature .\UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.0.exe |
    Format-List Status, SignerCertificate
```

---

## Privacy

Nothing is collected and nothing is uploaded — see **[PRIVACY.md](PRIVACY.md)**.

---

## License

[MIT](LICENSE) © 2026 **UNLOCK DIGITAL** — *By Eng. Eslam Ashraf*
