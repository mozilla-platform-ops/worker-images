# Windows Hardware Bootstrapping

`OS-deploy.ps1` stages `Get-Bootstrap.ps1`, `bootstrap-installers.ps1`, and
`bootstrap-installers.json` from the same resolved worker-images commit onto
`D:\scripts`. The existing deployment ACL restricts D: to SYSTEM and
Administrators. First boot and `bootstrap.ps1` load that staged helper; the WIM
bake receives the same helper and manifest through Packer file provisioners.

## Git and OpenSSH installer integrity (RELOPS-2588)

`bootstrap-installers.json` is the reviewed allowlist of installer filenames,
SHA-256 hashes, and ordered HTTPS download URLs. It covers Git 2.50.0, 2.54.0,
and 2.56.0.2 (x64 and ARM64), plus the existing x64 OpenSSH 9.8.3.0 MSI.
This change does not upgrade installed versions or replace already baked tools.

Git prefers the RelOps assets Blob mirror, then its versioned upstream GitHub
release asset. OpenSSH retains its versioned upstream GitHub URL; add a controlled
mirror URL first only after staging and verifying the identical MSI there.
Downloads use partial files and three attempts per URL. Transport failures may
fall back to the next URL. A SHA-256 mismatch stops immediately, reports the URL
and expected/actual hashes, removes the partial file, and never executes the
payload or falls back to another source. Cached installers never bypass the
check: every installation downloads and verifies fresh bytes. Installers are
awaited, and only exit codes 0 and 3010 (reboot required) are accepted.

Hash provenance for the initial manifest:

- Git: each release asset's `digest` from the upstream GitHub Releases API:
  `repos/git-for-windows/git/releases/tags/v2.50.0.windows.1`,
  `v2.54.0.windows.1`, and `v2.56.0.windows.2`.
- OpenSSH: downloaded `OpenSSH-Win64-v9.8.3.0.msi` from the upstream
  `PowerShell/Win32-OpenSSH` release `v9.8.3.0p2-Preview`. On 2026-10-28,
  Windows `Get-AuthenticodeSignature` reported `Valid`, signed by Microsoft
  Corporation (certificate thumbprint
  `8F985BE8FD256085C90A95D3C74580511A1DB975`). Its SHA-256 was calculated with
  `Get-FileHash -Algorithm SHA256`; this older asset has no API digest.

To update an installer, obtain the new versioned upstream asset, verify its
upstream digest and/or Authenticode publisher, and update the filename, URL, and
SHA-256 together in a reviewed PR. Update the pool/WIM Git version settings as
needed. An unknown installer filename fails before downloading or running it.
Do not fetch expected hashes from the installer mirror at runtime. Run:

```powershell
# From the repository root; no network or real installer execution.
./ci/test-bootstrap-installers.ps1
```

Rebuild a WIM and validate a hardware canary before rollout: existing WIMs retain
whatever installers were used when they were built. WinPE must use the updated
`OS-deploy.ps1` to stage the new files; do not mix old deployment scripts with
new bootstrap scripts. Branches that retain the old scripts remain unhardened.

## Remaining bootstrap trust boundaries

Puppet/OpenVox and other prerequisite payloads under
`https://roninpuppetassets.blob.core.windows.net/binaries/` continue to trust
HTTPS plus control of the RelOps-owned Azure Blob account. Approved writers
can replace those payloads; a hash sidecar stored alongside them would not
protect against a compromised writer. This PR does not audit Azure role
assignments or add independent pins for those other payloads.

Worker-images scripts and the new installer policy trust the resolved GitHub
commit and privileged staging directories. The WIM bake still reads SSH
configuration/keys from worker-images `main`. The Chocolatey bootstrap ZIP is
served separately from the existing RelOps S3 bucket, and PowerShell modules
have their existing distribution trust. These are outside the Git/OpenSSH
installer pins; this is not verification of the entire bootstrap supply chain.
