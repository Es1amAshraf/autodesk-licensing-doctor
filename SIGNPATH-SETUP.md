# Enabling code signing (SignPath Foundation)

Maintainer checklist for taking the project from the Windows *"Unknown
Publisher"* prompt to properly signed releases. Everything that lives in the
repository is already in place; the remaining steps happen in the SignPath and
GitHub user interfaces.

> **Status (October 2026).** The first application to the SignPath Foundation
> was reviewed and **deferred**: the program requires visible community
> adoption (stars, forks, external references, sustained activity) that a new
> project cannot show yet, and the maintainers were invited to re-apply once
> the project has gained broader recognition. Everything below stays valid and
> unchanged for that re-application — nothing has to be rebuilt. See the
> *Fallback* section at the end for certificates that can sign releases in the
> meantime without the reputation requirement.

Repository files involved:

| File | Purpose |
|------|---------|
| `CODE-SIGNING.md` | code signing policy (linked from the README) |
| `PRIVACY.md` | privacy policy (linked from the policy) |
| `.signpath/app-exe.xml` | SignPath artifact configuration for the application exe |
| `.signpath/setup-exe.xml` | SignPath artifact configuration for the installer |
| `.github/workflows/release-sign.yml` | CI: build, sign, package, publish |

---

## Prerequisites

- Two-factor authentication enabled on the GitHub account. SignPath requires MFA
  for every member of the organization and of the source repository.
  <https://github.com/settings/security>
- The repository is public and carries an OSI license (MIT).
- The project is already released and documented.
- A contact e-mail address for the application.

---

## 1. Apply

Apply at <https://signpath.org/apply>. Reviews are manual; expect a few days
(1–2 weeks in practice). The review weighs **public visibility**, not code
quality — a first application from a freshly published repository can expect a
deferral, which is explicitly an invitation to re-apply later.

```
Repository : https://github.com/Es1amAshraf/autodesk-licensing-doctor
License    : MIT (OSI approved)
Policy     : CODE-SIGNING.md (linked from README.md)
Artifacts  : UNLOCK-DIGITAL-AdskDoctor.exe
             UNLOCK-DIGITAL-AdskDoctor-Setup-<version>.exe
```

The program contains no crack, keygen, patch, license generator or bypass: it
removes leftovers of non-genuine Autodesk patches and restores the official
Autodesk licensing components. It changes nothing unless explicitly asked to, it
takes a backup first, and it ships an uninstaller.

---

## 2. Set up SignPath (after approval)

1. **Trusted build system** — add the predefined *GitHub.com* connector to the
   organization. Optionally install the
   [SignPath GitHub App](https://github.com/apps/signpath) on the repository.
2. **Project** — create one with slug `autodesk-licensing-doctor` and link the
   GitHub.com trusted build system to it.
3. **Signing policy** — create one with slug `release-signing`, using an
   *Authenticode* certificate and the **SignPath Foundation** certificate.
4. **Artifact configurations** — create two, pasting the contents of:
   - slug `app-exe` from `.signpath/app-exe.xml`
   - slug `setup-exe` from `.signpath/setup-exe.xml`
5. **API token** — create a token for a user with *submitter* permission on that
   project and policy, and copy it (it is shown once).
6. **Organization ID** — copy the GUID from the organization settings.

Note: if SignPath configures *pipeline policies* for the project (branch ruleset
constraints), those have to be satisfied on GitHub as well — typically a branch
ruleset on `main`.

---

## 3. Configure GitHub

Settings → Secrets and variables → Actions:

| Kind | Name | Value |
|------|------|-------|
| Secret | `SIGNPATH_API_TOKEN` | the API token from step 2.5 |
| Variable | `SIGNPATH_ORGANIZATION_ID` | the SignPath organization GUID |
| Variable | `SIGNPATH_PROJECT_SLUG` | `autodesk-licensing-doctor` |
| Variable | `SIGNPATH_SIGNING_POLICY_SLUG` | `release-signing` |

Until `SIGNPATH_ORGANIZATION_ID` is set, the *Release (Signed)* workflow skips
itself instead of failing, so release tags stay green while the SignPath account
is being approved. Setting the variable is what turns the signing on.

---

## 4. Cut the first signed release

From the GitHub UI: Actions → **Release (Signed)** → *Run workflow* → version
`x.y.z`. Or from a shell:

```powershell
.\Publish-Release.ps1 -Version x.y.z -Notes "Signed release" -Recompile -ViaGitHubActions
```

Either way, CI compiles the application exe, has it signed, builds the archives
and the installer around the **signed** exe, has the installer signed, and
publishes the release.

### Approve the signing requests

Every signing request must be approved manually; this is a SignPath Foundation
rule, not an option.

1. Start the workflow (or push the tag).
2. Within a few minutes the request appears in the SignPath UI under *Signing
   Requests*, and a notification e-mail is sent.
3. Approve it. The workflow waits for up to one hour
   (`wait-for-completion-timeout-in-seconds: 3600`).
4. Signing completes and the release is published.

There are two requests per release — the application exe first, then the
installer; the second appears only after the first has completed. If a request
is not approved before the timeout the job fails; simply re-run it.

---

## 5. Verify

```powershell
Get-AuthenticodeSignature .\UNLOCK-DIGITAL-AdskDoctor-Setup-1.2.9.exe |
    Format-List Status, @{n='Signer';e={$_.SignerCertificate.Subject}}
```

Expected: `Status = Valid` and signer **SignPath Foundation**. The UAC prompt of
the installer must then read **SignPath Foundation** instead of *Unknown
Publisher*.

*SmartScreen is a separate mechanism:* a valid signature removes the *Unknown
Publisher* prompt immediately, while the full-screen *"Windows protected your
PC"* warning fades only as the certificate builds download reputation.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `Signing request failed: artifact configuration not found` | the slug in the workflow does not match the one in SignPath |
| `Metadata restriction violated` | the exe's file/product version or company/product name does not match the artifact configuration — check that the `parameters:` block sends `<version>.0` for `app-exe` and `<version>` for `setup-exe` |
| `Artifact was not uploaded with actions/upload-artifact` | the upload step must run **before** the signing step, and its `artifact-id` output must be passed |
| Workflow blocked by a policy | SignPath enabled pipeline policies — satisfy the GitHub branch ruleset they require |
| Signature valid but SmartScreen still warns | expected at first; it fades with downloads |
| Certificate expiry | the SignPath Foundation certificate is managed by SignPath; nothing to renew |

---

## Fallback — sign locally with your own certificate

If SignPath declines the project (as happened in October 2026), a certificate
you own can be used instead. No workflow changes are needed:

```powershell
.\Build-Release.ps1 -Version 1.2.9 -Recompile     # build first
.\Sign.ps1 -List                                  # list usable certificates
.\Sign.ps1 -Path .\releases\v1.2.9\*.exe -Thumbprint <sha1>
.\Sign.ps1 -Verify -Path .\releases\v1.2.9\*.exe
```

Always sign the **application exe before** building the installer, so the
installer embeds the signed exe, and sign the **installer** afterwards.

Signing options reviewed in October 2026 for a young open-source project:

| Option | Cost | Notes |
|--------|------|-------|
| Certum — **Open Source Code Signing in the Cloud** | from ~€49 / $58 per year | individual certificate (*"Open Source Developer"* + your name), no hardware token, 5000 signatures/month; requires identity verification, a utility bill and a public open-source project; must not be used for commercially distributed software |
| SignPath — paid subscription | from $500/year | certificates are EV and can only be issued to a **legally registered organization** (GlobalSign policy) |
| Azure Artifact Signing (formerly Trusted Signing) | ~$9.99/month | individuals only in the USA and Canada; organizations in the USA, Canada, EU, UK |

(The *"code"-only* Certum product at ~$29 applies only if a `cryptoCertum`
card and reader are already owned; the cloud product above needs neither.)

Unlike SignPath Foundation, the Certum certificate has no reputation
requirement — but it is not free, and identity verification is per person.

---

© 2026 UNLOCK DIGITAL
