# Privacy policy

**UNLOCK DIGITAL — Autodesk Licensing Doctor** · © 2026 UNLOCK DIGITAL — *By Eng. Eslam Ashraf*

> **This program will not transfer any information to other networked systems
> unless specifically requested by the user or the person installing or
> operating it.**

---

## Short version

There is **no telemetry, no analytics, no phone-home, no account, no license
check** of any kind. The tool has no server. Nothing about you, your machine or
your clients is ever sent anywhere.

## What the program does locally

Everything the tool does happens **on the machine it runs on**:

| Phase | Touches the network? | What happens |
|-------|---------------------|--------------|
| 1 · Diagnostic | **read-only probes only** | Performs read-only checks and, to diagnose *"Connection Lost"* / DNS failures, opens ordinary TCP/TLS connections to well-known **Autodesk** endpoints (e.g. `*.autodesk.com`, `*.autodesk360.com`) and resolves a few host names. These requests contain no personal data — no identifiers, no analytics payload — they merely test reachability. Results stay in a local `report.html` / `report.json` file. |
| 2 · Backup | **no** | Writes `.reg` exports, file copies, state snapshots and a generated `UNDO.ps1` to a folder you choose, on the local disk. |
| 3 · Cleanup | **no** | Removes leftover non-genuine Autodesk artifacts from the local file system, registry, services and tasks. |
| 4 · Repair | **_yes, only when you ask_** | Reinstalls/repairs the official Autodesk components. This downloads from **Autodesk's own servers** using the official installers/`AdskLicensingInstaller`, i.e. the transfer is between the machine and Autodesk — not us. |

## The Autodesk download button

The GUI's **Download from Autodesk** button simply opens
<https://manage.autodesk.com/products/all> in your default browser. Nothing is
transferred by the application itself.

## Files the program creates

All of them stay on the local machine:

- `report.html` / `report.json` / `report.txt` — diagnostic output
- a backup folder with `.reg` exports, copies of `hosts`, `AdskLicensing`,
  `AdSSO`, `FLEXnet` state, and `UNDO.ps1`
- a log file

Nothing is uploaded. You delete them whenever you like.

## Third parties

- **Autodesk** — network endpoints are contacted for diagnostics and for the
  official component downloads. See Autodesk's own privacy statement.
- **GitHub** — this repository and its releases are hosted by GitHub, and CI
  builds run on GitHub Actions. See GitHub's privacy statement.
- **SignPath.io / SignPath Foundation** — code signing of released binaries
  (see [CODE-SIGNING.md](CODE-SIGNING.md)). Build inputs are our own source
  code; no user data is involved.

## Children / personal data

The tool is a system administration utility. It does not collect personal data
from anyone, including children.

## Contact

Questions or concerns → open an issue:
<https://github.com/Es1amAshraf/autodesk-licensing-doctor/issues>
