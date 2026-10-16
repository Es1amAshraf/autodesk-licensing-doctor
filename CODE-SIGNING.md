# Code signing policy

**UNLOCK DIGITAL — Autodesk Licensing Doctor**

> **Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).**

Every official binary we publish in a GitHub Release is signed with an
Authenticode certificate provided by the *SignPath Foundation*. Signatures are
created from a build of this repository on GitHub-hosted runners — never from a
developer machine — and the signed files are published exactly as produced by
SignPath.

---

## What is signed

| Artifact | Signed | Notes |
|----------|--------|-------|
| `UNLOCK-DIGITAL-AdskDoctor.exe` | yes | the application (inside `-Portable.zip`) |
| `UNLOCK-DIGITAL-AdskDoctor-Setup-<v>.exe` | yes | the Inno Setup installer, built **after** the app exe was signed, so the executable it ships is signed too |
| `AdskDoctor-v<v>-Project.zip` | no | plain source text, nothing to sign |
| `.ps1` / `.cmd` scripts inside the zips | no | not released as executables; they run under the signed app |

The **sha256 of every file is published** next to each release
(`SHA256SUMS.txt`, `RELEASES.md`, and the release notes), so a user can verify
both integrity and provenance.

---

## Signing pipeline

1. GitHub Actions (`Release (Signed)` workflow, `.github/workflows/release-sign.yml`)
   compiles the app exe from this repository on a **GitHub-hosted runner**.
2. The unsigned exe is uploaded as a workflow artifact and submitted to
   **SignPath.io** (artifact configuration `app-exe`).
3. After the app exe comes back signed, the release builder packs it into
   `-Portable.zip` and into the Inno Setup installer.
4. The unsigned installer is uploaded and signed (artifact configuration
   `setup-exe`).
5. The GitHub Release is created with the **signed** installer and the zip
   archives that contain the **signed** application.

Machine-readable artifact configurations live in `.signpath/`.

---

## Roles

| Role | Who |
|------|-----|
| Committers and reviewers | [@Es1amAshraf](https://github.com/Es1amAshraf) — [repository owner](https://github.com/Es1amAshraf/autodesk-licensing-doctor) |
| Approvers (may approve a signing request) | [@Es1amAshraf](https://github.com/Es1amAshraf) — [owner](https://github.com/Es1amAshraf) |

Every change proposed by someone who is not a committer must be reviewed by a
committer before it is merged. Every signing request is approved manually by an
approver.

---

## Privacy

This project collects nothing. See [PRIVACY.md](PRIVACY.md):

> This program will not transfer any information to other networked systems
> unless specifically requested by the user or the person installing or
> operating it.

---

## How to verify a signature

PowerShell (no extra tools needed):

```powershell
Get-AuthenticodeSignature .\UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.9.exe |
    Format-List Status, StatusMessage, @{n='Signer';e={$_.SignerCertificate.Subject}}, TimeStamperCertificate
```

Windows SDK `signtool`:

```cmd
signtool verify /pa /v UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.9.exe
```

Or right-click the file → **Properties** → **Digital Signatures** tab.

- `Status` must be `Valid`
- the signer must be **SignPath Foundation** (OSS certificate)
- the signature must be **timestamped**, so it stays valid after the certificate
  expires

If `Status` is `NotSigned` or `UnknownError`, the file was **not** produced by
our pipeline — do not run it.

---

## Reporting a problem

If you find a file that claims to come from this project, is signed by us, and
looks wrong — or a file signed with our name that we did not publish — please
open an issue:
<https://github.com/Es1amAshraf/autodesk-licensing-doctor/issues>

---

© 2026 UNLOCK DIGITAL
