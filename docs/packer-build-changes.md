# Packer speed and simplification changes

Disposition of the 2026-09-15 build-speed/simplification audit. Timing estimates
in that audit are hypotheses; this PR has not measured new cloud build times.
No production image versions or ronin_puppet pins are bumped here.

## Speed changes

| Item | Change / remaining validation |
| --- | --- |
| W1 | Production parallel Packer jobs publish in the build region, then `replicate` jobs expand coverage and wait for every target. Only those jobs emit `deployment-ready-*`. Single-image production builds remain synchronous. Shallow replication is enabled only for win2025 alpha: its pool and builder both use eastus2. Other alpha configs still require multiple regions, or their builder differs from their target. |
| W2 / #14 | Replace the audit's proposed blanket nine-region list with per-image coverage generated from current fxci-config pool variants and image aliases. Pool overrides still require several regions the audit called unused; no active pool currently requires westeurope. Every alpha/production config now covers its actual consumers plus the mandatory build region. |
| W3 | Runner-created Bootstrap/tests ZIPs replace per-file WinRM uploads. Only the selected config and defaults YAML are uploaded. Prerequisite versions arrive through environment variables. |
| W4 / #17 | Remove Az PowerShell initialization and the tceng no-op removal step. Azure CLI login is now needed for the requested SKU preflight, as well as the replication job; it is not an unused step anymore. Packer still performs its own OIDC exchange. |
| W5 | The temporary SIG builder uses Premium_LRS. Measure Puppet and Sysprep timings in alpha. |
| W6 | Remove whole-build retries entirely. One failed Puppet/Pester/Packer run fails the job; manually rerun transient failures. Download retries remain at the transfer layer. |
| W7 | Cache Packer plugins using cloud, OS, architecture and template hashes; pin the FXCI plugins to Azure 2.5.0 and Google Compute 1.2.4. |
| W8 | **Not implemented.** A monthly base image needs a separate provenance and trust design before it can safely replace marketplace sources; see below. |
| G1 | Install container toolkit before a single reboot; retain disconnect/reconnect handling and a 30-second post-reboot pause. Remove the extra 90-second test/CoT pauses. |
| G2 | Use Ubuntu's 580 driver and signed GCP kernel modules; remove the ineffective NVIDIA 570 repository. Post-reboot tests reject wrong branches, unsigned modules and NVIDIA DKMS builds. Requires an alpha build against the current GCP kernel and GPU-owner review. |
| G3 | Default amd64 builders to e2-standard-8; the existing YAML machine_type override now works for FXCI. Confirm regional quota before building. |
| G4 | Install only the cuDNN 9 CUDA 12 runtime. GPU owners must confirm tasks do not rely on headers, samples or static libraries baked into the image. |
| G5 | Replace Linux PowerShell/Pester setup with a shell version/executable check. Keep Docker validation. |
| G6 | All five GCP builders use pd-ssd. |
| G7 | Install powershell-yaml only when absent. A single metadata helper parses GCP config once per step. |

## Simplification changes

- Delete the audited orphan Windows tests and Bootstrap functions, obsolete Linux
  scripts, old Windows bootstrap entrypoints,
  unused arm64 NVIDIA placeholder, and two unreferenced `-alpha-v6` configs.
  Keep the old Windows 11 2009 galleries and active hardware Puppet settings.
  Two audit false positives are retained: `Get-LiveLogVersion` is called by
  `Show-TaskclusterBinaries`, and `Show-VCC2019` by the active
  `microsoft_tools_tester.tests.ps1`. Their callers differ in capitalization;
  PowerShell names are case-insensitive.
- Keep the Linux SBOM generator test and run it in PR CI instead of deleting it.
- Remove the unused root Azure nonsig source/variables/provisioner. tceng retains
  its own templates. New-AzWorkerImage rejects the removed root nonsig route.
- Replace copied Linux retry functions with native apt/curl retry options. Curl
  writes downloads to named files so a retry can rewind partial output. Docker
  validation fails immediately rather than retrying a broken daemon.
- Consolidate workflow authorization, Azure build invocation, successful-build
  filtering, GCP metadata and integration log formatting. Empty filtered matrices
  skip downstream jobs rather than attempting to expand an empty matrix.
- Merge Puppet success/failure handlers without changing CoT key or firewall
  behavior; remove duplicated function-level stopwatches, retaining Puppet apply
  timing. Simplify release-note sorting and write UTF-8/LF directly to the final
  path, including a Windows Server 2025 header. Do not rewrite old SBOMs.
- Replace Windows `"default"` sentinels with omission and a recursive merge. Arrays
  replace defaults; explicit null/false/empty values remain explicit overrides.
- Replace dispatch config choice lists with validated strings. Consolidate GCP
  one-off build/promotion workflows into optional `config` inputs on their parallel
  workflows. The old workflow filenames are intentionally removed.

## Other correctness/security findings

- Secrets in the audited build workflows are passed through `env`, not embedded
  in PowerShell source. Config strings are validated and passed as data.
- Checkouts disable credential persistence except the release-note publisher,
  which pushes commits and still needs it.
- Wiz CLI is pinned to 1.75.0 and its release object's SHA-256. Update both together.
- Remove undefined `TARGET_BRANCH` checkout refs in gcp-tceng. Use the triggering ref.
- Standardize the root Azure tag on `sourceOrganization`, matching config/runner.
- Waiting for alpha integration results remains the default. An explicit
  `wait_for_results: false` submits tests without waiting; it is not a test pass.
- **#699:** enable pinned PSScriptAnalyzer 1.25.0 checks for all tracked production
  PowerShell, not only Pester files. Fix aliases, automatic-variable assignments,
  null comparisons, unused parameters/variables, empty catches, WMI calls, module
  exports, UTF-8 BOMs for Windows PowerShell, and Get-InstalledSoftware pipeline
  handling. Remove the unused SecureString/credential construction and duplicate
  plaintext password parameter from OS-deploy; forward its development script
  in-process instead of putting credentials in another PowerShell command line.
  The legacy MDT/net-use credential input remains; this is not a credential-store
  redesign. Execute the official Chocolatey HTTPS installer as a downloaded file,
  not Invoke-Expression; vendor installer trust remains necessary.
- Analyzer policy deliberately permits transcript Write-Host, unattended
  provisioning without partial WhatIf behavior, and existing API names. Narrow,
  named suppressions preserve the repository's Write-Log API and parameters used
  in nested/runspace helpers that the analyzer cannot follow. Other warnings and
  errors fail CI. The root settings file is now live and is therefore retained.
- **#17:** the shared Azure build functions query `az vm list-skus` before Packer
  initialization. Require exact SKU/region matches, reject subscription location
  restrictions, and check Spot support when requested. Zone-only restrictions do
  not prohibit these non-zonal builders. This checks the temporary builder in its
  build region, not an assumption that its SKU is needed in every replica region;
  it cannot reserve live capacity or prove quota will remain available.
- **#14:** the region check reuses fxci-config's own variant/alias resolver under
  that repository's locked dependencies. It runs on relevant PRs, daily, and as
  a prerequisite of FXCI Azure builds. The report records the source revision,
  required regions, missing replicas and unused replicas, including pool-specific
  overrides and trusted/untrusted image separation. Inactive pools are excluded.
- **External blocker:** feature-branch Azure OIDC subjects need identity-owner
  approval/configuration outside this repo. This PR neither grants access nor
  bypasses federation checks.
- **tceng follow-up:** `config/tceng/image _development.yaml` still contains a space.
  The validated input deliberately does not accept that filename; the tceng owner
  must choose its supported name and update any external callers before renaming.

## Before merge / before deployment

1. Obtain an approved Azure branch-build identity subject. Do not weaken the
   authorization or trusted/untrusted subscription separation to test this PR.
2. Build representative Windows x64, arm64, server and trusted images. Check ZIP
   extraction, exact prerequisite versions, Pester, UTF-8 release notes, Sysprep,
   and trusted key/firewall behavior without exposing key contents in logs.
3. Validate shallow win2025 alpha creation and boot. Validate a production-style
   replication run: all configured regional states must become Completed. Exercise a
   failed/timeout replication; it must not emit a readiness artifact.
4. Build GCP headless amd64, GUI and arm64, including trusted variants. Confirm
   reconnect after reboot, desktop/audio/video devices and Docker readiness.
   Get GPU-owner signoff on the Ubuntu 580 module and runtime-only cuDNN; run real
   GPU/container/cuDNN tasks. The Packer builder has no GPU.
5. Compare per-phase timings with the audit's baselines, including replication
   and integration time separately. No speedup is accepted solely from estimates.
6. Before an fxci-config bump, require every production `replicate` job and its
   `deployment-ready-*` artifact for the exact image IDs, plus passing integration
   results. This repository cannot enforce a merge gate in fxci-config by itself.
7. Smoke-test the lint-driven MDT development-script handoff and pipeline software
   inventory changes on Windows. No hardware deployment is performed by the local
   tests or analyzer.
   Tier-1 Firefox CI health remains the production release bar.

## Monthly base images: unresolved W8 design

Do not silently build level-3 images from level-1 alpha artifacts. A safe base
scheme needs separate trusted/untrusted galleries, immutable base version IDs,
a base SBOM and hash recorded in each incremental SBOM, and an explicit rule for
how the base ronin_puppet pin relates to the incremental `deploymentId`. Base
creation must not bake a production CoT key, worker identity or caches into a
reusable image. It also needs ownership for monthly OS servicing, gallery
retention, rollback, and testing that profiles can converge from an older base.
Those resources and rules are not defined in this repo today. W8 remains open;
the existing marketplace-source build remains the supported fallback.
