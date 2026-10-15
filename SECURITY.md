# Security policy

**UNLOCK DIGITAL — Autodesk Licensing Doctor**

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Use GitHub's private reporting instead:
**<https://github.com/Es1amAshraf/autodesk-licensing-doctor/security/advisories/new>**

Include:

- what you found and where (file, phase, line if you have it)
- how to reproduce it
- the impact you believe it has
- a way to reach you

You can expect an acknowledgement within a few days. Please give us a
reasonable window to fix and release before publishing details.

## What counts as a vulnerability here

This tool runs **elevated** on machines that were previously modified with
non-genuine software, so we care about:

- anything that lets a **non-administrator** influence what the elevated tool executes
- path/registry handling that could be abused for **privilege escalation** or arbitrary file write/delete
- the generated `UNDO.ps1` being exploitable
- the app executing something from a **non-elevated, user-writable location**
- backdoors, unexpected network transfer or hidden data collection
- a published binary whose signature/hash does not match what our CI produced
  (see [CODE-SIGNING.md](CODE-SIGNING.md))

## Out of scope

- Windows or Autodesk product vulnerabilities (report those to Microsoft / Autodesk)
- the behaviour of software that the tool intentionally removes
- SmartScreen / "Unknown Publisher" warnings — see [CODE-SIGNING.md](CODE-SIGNING.md)
- "the tool asks for administrator rights" — it must, by design

## Supported versions

| Version | Supported |
|---------|-----------|
| latest release | yes |
| anything older | no |

## Supply chain / provenance

- Releases are built on **GitHub-hosted runners** from this repository only.
- Once the SignPath Foundation certificate is in place, the application exe and
  the installer are **signed**; see [CODE-SIGNING.md](CODE-SIGNING.md).
- Every release ships `SHA256SUMS.txt`; verify before running:

```powershell
Get-FileHash .\UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.8.exe -Algorithm SHA256
```
