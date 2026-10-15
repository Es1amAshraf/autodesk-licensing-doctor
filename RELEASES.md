# UNLOCK DIGITAL - Autodesk Licensing Doctor - Releases

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

