# Windows Hardware Bootstrapping

Pools in `pools.yml` use Ronin by default. Set `ronin: false` and
`bootstrap_script: <filename>.ps1` to stage a first-boot script from
`non-ronin/` instead of `Get-Bootstrap.ps1`. Scripts come from the same pinned
worker-images revision as the deployment. Non-Ronin pools need no Puppet/Git
versions or Ronin repository/role settings.
The existing deployment functions and Ronin pool matching/fallback logic are
preserved; only explicitly non-Ronin pools use the new helpers. Ronin bootstrap
still runs at its original point after formatting Windows.

The `win11-26h2-a11y` pool uses plain Windows media with a single-edition WIM at index
1. Extract the staged `resources/ISOs/Windows11_Client_x64_en-us_26300_9457.iso`
using `win-hw-wim/scripts/extract-wim-from-iso.ps1`, inspect its editions with
`Get-WindowsImage`, and export the required KMS-capable edition using
`Export-WindowsImage`. This does not use the Ronin WIM bake. Verify the actual
release and edition before deployment; the pool name records the source build.

Stage the extracted ISO media under
`\\mdt2022.ad.mozilla.com\deployments\Images\win11-26h2-a11y`, replacing
`sources\install.wim` with the single-edition export and removing
`sources\install.esd` if present. Alternatively, the existing direct-DISM path
accepts `win11-26h2-a11y.wim` and its `.sha256` sidecar in that folder.
The WIM artifact has not been created by adding the pool entry.

To create it with the **Windows HW WIM Build** workflow, select image
`win11-26h2-a11y` and set `pipeline_ref` to
`relops-2612-non-ronin-pools` while testing the implementation branch. This uses
`win-hw-wim/config/win11-26h2-a11y.yaml`. Its `wim.plain: true` selects
ISO extraction and single-edition export, followed by upload to
`captured/WIMs/win11-26h2-a11y/<image>-<buildid>.wim` plus SHA-256.
The edition selection is `Windows 11 Pro`, confirmed in the staged ISO by the
build logs. Enterprise media is available separately; the staged consumer ISO
does not include Enterprise. This export retains the ISO's patch
level and does not run Ronin or Windows Update. At PXE deployment, the pool's
existing `dev` flag selects the implementation branch.

Stage `secrets\win11-26h2-a11y-10-05-2026.yaml` on the deployment share with
`win_adminpw` and `win_kms_server` (hostname, optionally `:1688`). Keep these
deployment values out of Git. The public Pro KMS client setup key is stored in
the pool YAML under `ronin.win_kms_key`; `ronin.enabled: false` requires a valid
key, checked before deployment touches any disks.
The existing share `secrets\pat.txt` is still needed to fetch pinned scripts.
WinPE injects the administrator password into the answer file and stages
only KMS settings and provenance in `D:\scripts\non-ronin.json`. First boot
installs the KMS key, sets the server, activates Windows, verifies the license
state, and removes provisioning secrets/answer files after success. Failures
retain the protected provisioning files for diagnosis and retry.

Non-Ronin provisioning skips the Ronin vault copy, Chocolatey/Puppet install,
Ronin catalog, and Taskcluster registration. Additional a11y software and
management tooling belong in `non-ronin/a11y-win.ps1` once specified.

Local verification (no disks, activation, or registry changes):

```powershell
powershell.exe -NoProfile -File ci/test-non-ronin-pools.ps1
```
