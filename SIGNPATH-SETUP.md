# Enabling code signing (SignPath Foundation — free for open source)

This is the checklist to go from **"Unknown Publisher"** to a properly signed
release. Everything that can be prepared in the repository is already done —
what follows is only the account/UI part.

Repository files involved:

| File | Purpose |
|------|---------|
| `CODE-SIGNING.md` | the code signing policy (required by SignPath) |
| `PRIVACY.md` | privacy policy (linked from the policy) |
| `.signpath/app-exe.xml` | artifact configuration — signs the app exe |
| `.signpath/setup-exe.xml` | artifact configuration — signs the installer |
| `.github/workflows/release-sign.yml` | CI: build → sign → sign → publish |

---

## Stage 0 — prerequisites (you)

- [ ] **Turn on two-factor authentication on GitHub.** SignPath's conditions
      require MFA for every team member on both SignPath and the source
      repository. <https://github.com/settings/security>
- [ ] The repository is **public** and licensed with an **OSI license** — ✅ MIT.
- [ ] The project is already **released** and **documented** — ✅ v1.2.0 + README.
- [ ] Nothing about the project is proprietary — ✅ pure PowerShell.
- [ ] A **contact e-mail** you want to use for the application.

---

## Stage 1 — apply (you)

Apply at **<https://signpath.org/apply>** (they review manually, expect a few
days). Point them at:

```
Repository : https://github.com/Es1amAshraf/autodesk-licensing-doctor
License    : MIT (OSI approved)
Policy     : CODE-SIGNING.md   (linked from README.md)
Artifacts  : UNLOCK-DIGITAL-AdskDoctor.exe
             UNLOCK-DIGITAL-AdskDoctor-Setup-<version>.exe
```

**How to describe the project if they ask.** The tool **detects and removes
traces of pirated/patched Autodesk software** and **restores the official
Autodesk licensing components** so a genuine subscription works again. It
contains no crack, keygen, bypass or license generator. This matters because of
their *"No hacking tools"* clause, which explicitly **does** allow:

> features that detect *actual* security breaches, e.g. traces of being hacked,
> presence of malware or potentially unwanted programs

Also relevant (all in our favour): the tool warns before changing anything,
runs read-only by default, takes a backup first and ships an uninstaller.

---

## Stage 2 — set up SignPath (you, after approval)

1. **Trusted build system** — add the predefined *GitHub.com* connector to your
   organization, and (optional but recommended) install the
   [SignPath GitHub App](https://github.com/apps/signpath) on the repo.
2. **Project** — create a project, slug: `autodesk-licensing-doctor`.
   Link the GitHub.com trusted build system to it.
3. **Signing policy** — create one, slug: `release-signing`, with an
   *Authenticode* certificate and the **SignPath Foundation** certificate.
4. **Artifact configurations** — create two, by pasting the contents of:
   - slug `app-exe` ← `.signpath/app-exe.xml`
   - slug `setup-exe` ← `.signpath/setup-exe.xml`
5. **API token** — create a token for a user with **submitter** permission on
   that project/policy; copy it (shown once).
6. **Note your Organization ID** (a GUID in the organization settings).

> If SignPath configures **pipeline policies** for your project (branch ruleset
> constraints), you must satisfy them on GitHub — typically a branch ruleset on
> `main` with *require a pull request* and/or *block force pushes*. Ask them, or
> keep the default (no extra constraints).

---

## Stage 3 — configure GitHub (you; 2 minutes)

Settings → **Secrets and variables → Actions**:

| Kind | Name | Value |
|------|------|-------|
| Secret | `SIGNPATH_API_TOKEN` | the API token from Stage 2.5 |
| Variable | `SIGNPATH_ORGANIZATION_ID` | your SignPath organization GUID |
| Variable | `SIGNPATH_PROJECT_SLUG` | `autodesk-licensing-doctor` |
| Variable | `SIGNPATH_SIGNING_POLICY_SLUG` | `release-signing` |

---

## Stage 4 — cut the first signed release

**Option A — from GitHub UI:** Actions → **Release (Signed)** → *Run workflow* →
version `1.2.1`.

**Option B — from the command line:**

```powershell
.\Publish-Release.ps1 -Version 1.2.1 -Notes "Signed release" -Recompile -ViaGitHubActions
```

Both paths: CI compiles the exe, SignPath signs it, the zips + installer are
built around the **signed** exe, the installer is signed, and the Release is
published.

### ⚠️ Approve the signing request

**Every signing request must be approved manually** — that is a SignPath
Foundation rule, not an option.

1. Start the workflow (or push the tag).
2. Within a few minutes SignPath shows a *pending signing request* — you get a
   notification e-mail, and the request also appears in the SignPath UI
   (*Signing Requests*).
3. **Approve it.** The workflow is sitting there waiting; it is configured to
   wait up to **1 hour** (`wait-for-completion-timeout-in-seconds: 3600`).
4. Signing then completes and the release is published automatically.

If you don't approve in time, the job fails after the timeout — just re-run it
and approve faster. (There are **two** requests per release: the app exe first,
then the installer. Approve both; the second one appears only after the first
completes.)

---

## Stage 5 — verify

Download the published installer and run:

```powershell
Get-AuthenticodeSignature .\UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.1.exe |
    Format-List Status, @{n='Signer';e={$_.SignerCertificate.Subject}}
```

Expected: `Status = Valid`, signer = **SignPath Foundation**.

Then install it — the UAC prompt must show **SignPath Foundation**, not
*Unknown Publisher*.

> **SmartScreen is separate.** A correct signature removes *Unknown Publisher*
> immediately, but the *"Windows protected your PC"* full-screen warning fades
> away only as the certificate builds download reputation. Downloads accumulate
> it; nothing else to configure.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Signing request failed: artifact configuration not found` | the slug in the workflow doesn't match the one in SignPath |
| `Metadata restriction violated` | the exe's file/product version or company/product name doesn't match the artifact config — check the `parameters:` block sends `1.2.1.0` for `app-exe` and `1.2.1` for `setup-exe` |
| `Artifact was not uploaded with actions/upload-artifact` | the upload step must run **before** the signing step, and its `artifact-id` output must be passed |
| Workflow blocked by a policy | SignPath enabled pipeline policies — satisfy the GitHub branch ruleset they require |
| Signature valid but SmartScreen still warns | expected at first; it decays with downloads |
| Certificate expiry | the SignPath Foundation certificate is managed by SignPath; nothing to renew on your side |

---

© 2026 **UNLOCK DIGITAL** — *By Eng. Eslam Ashraf*
