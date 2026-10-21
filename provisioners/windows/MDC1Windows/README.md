# Windows Hardware Bootstrapping

Pools in `pools.yml` use Ronin by default. Set `ronin.enabled: false` to select
`non-ronin/<pool-name>.ps1`, such as `non-ronin/win11-26h2-a11y.ps1`.
The selected script is staged as `D:\scripts\Get-Bootstrap.ps1` for Windows
FirstLogonCommands. Scripts come from the same pinned
worker-images revision as the deployment. Non-Ronin pools need no Puppet/Git
versions or Ronin repository/role settings.
Pool nodes must match the reverse-DNS shortname exactly. The accessibility pool
accepts `a11y` and `a11y-win`. When PXE starts from `main`, its pool configuration
must also match the hostname before the `dev` branch handoff can occur.
The existing deployment functions and Ronin pool matching/fallback logic are
preserved; only explicitly non-Ronin pools use the new helpers. Ronin bootstrap
still runs at its original point after formatting Windows.

For another plain Windows pool, copy this entry and set its name, image, node,
and secret date:

```yaml
- name: "win11-lab"
  ronin:
    enabled: false
  image: "win11-lab"
  secret_date: "10-06-2026"
  domain_suffix: "corpdmz.mdc1.mozilla.com"
  nodes:
    - lab-win
```

Stage the pool's single-edition WIM/media and `<name>-<secret_date>.yaml` secrets
with the settings required by its pool-specific first-boot script. The a11y
script requires `win_kms_key` and `win_kms_server`, plus optional `win_adminpw`.
Use `dev` to test a deployment branch. For an ISO export, copy the a11y WIM
config under the new image name and set its ISO/edition; add the image to the
existing workflow choices. WIM builds select their branch through `pipeline_ref`.

The `win11-26h2-a11y` pool uses plain Windows media with a single-edition WIM at index
1. Extract the staged `resources/ISOs/Windows11_Client_x64_en-us_26300_9457.iso`
using `win-hw-wim/scripts/extract-wim-from-iso.ps1`, inspect its editions with
`Get-WindowsImage`, and export the required KMS-capable edition using
`Export-WindowsImage`. This does not use the Ronin WIM bake. Verify the actual
release and edition before deployment; the pool name records the source build.

Stage the extracted ISO media under
`\\mdt2022.ad.mozilla.com\deployments\Images\win11-26h2-a11y-20261006-045741`, replacing
`sources\install.wim` with the single-edition export and removing
`sources\install.esd` if present. Alternatively, the existing direct-DISM path
accepts `win11-26h2-a11y-20261006-045741.wim` and its `.sha256` sidecar in that folder.
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

Stage `secrets\win11-26h2-a11y-10-05-2026.yaml` on the deployment share:

```yaml
win_kms_server: "<your-kms-host>:1688"
win_kms_key: "W269N-WFGWX-YVC9B-4J6C9-T83GX"
```

Replace `<your-kms-host>` with the actual KMS hostname. The key above is the
public Windows 11 Pro KMS client setup key, appropriate for this Pro image.
Both KMS values are validated before deployment touches disks. Keep deployment
configuration in the share file rather than the pool YAML.

Omit `win_adminpw` to leave account/password setup to interactive Windows OOBE.
The generated answer file then contains neither account creation nor automatic
logon; first-logon provisioning runs after an administrator signs in. Supplying
`win_adminpw` retains the existing password/autologon behavior. Ronin pools still
require their administrator password. Omitting `secret_date` skips copying the
pool YAML, but this KMS bootstrap still requires KMS configuration before it
can deploy.

The existing share `secrets\pat.txt` is still needed to fetch pinned scripts.
WinPE injects the administrator password only when supplied and stages
only KMS settings and provenance in `D:\scripts\non-ronin.json`. First boot
installs the KMS key, sets the server, activates Windows, verifies the license
state, then downloads MozillaBuild from the official
[`MozillaBuildSetup-Latest.exe`](https://ftp.mozilla.org/pub/mozilla/libraries/win32/MozillaBuildSetup-Latest.exe)
link in the [Windows build instructions](https://firefox-source-docs.mozilla.org/setup/windows_build.html).
It requires a valid Mozilla Corporation Authenticode signature, installs silently
with `/S` into the default `C:\mozilla-build` location, and checks the shell and
version file. This installs the latest release at provisioning time; it does not
clone Firefox or run `mach bootstrap`. Provisioning secrets/answer files are
removed only after activation and MozillaBuild installation succeed. Failures
retain the protected provisioning files for diagnosis and retry.

Non-Ronin provisioning skips the Ronin vault copy, Chocolatey/Puppet install,
Ronin catalog, and Taskcluster registration. Add a11y-specific provisioning to
`non-ronin/win11-26h2-a11y.ps1`. Another non-Ronin pool must provide its own
`non-ronin/<pool-name>.ps1`; an unavailable script stops deployment before the
Windows volume is formatted on the existing-partition path. Initial disk
partitioning currently precedes script staging.

Local verification (no disks, activation, or registry changes):

```powershell
powershell.exe -NoProfile -File ci/test-non-ronin-pools.ps1
```
