# WIM storage design (Azure Blob, Entra-only)

Store both the base and captured WIMs in an **Azure Blob** account
(`hardwareimaging`, Central US). Access is **Entra-only**: the account has a public
endpoint open to all networks, but no anonymous access and **no shared account
keys** — every caller must present an Entra identity holding a Storage Blob Data
RBAC role. This avoids building an Azure↔MDC1 VPN (which does not exist today).

> History: this started as a Tier-1 IP-firewalled account, but split-tunnel VPN
> made per-workstation IP allow-listing unworkable, so it moved to Entra-only
> (RBAC gates access regardless of source network).

## Why not reuse `roninpuppetassets`
It's fully public (`container_access_type = "blob"`, anonymous read). WIMs must
not be anonymously downloadable, so we use a **separate, Entra-gated** account.

## What is provisioned (Terraform)
`relops_infra_as_code/terraform/azure_fxci/nuc-wim-storage.tf` (branch
`nuc-wim-storage`, **PR #313**) — applied to the FXCI DevTest subscription:
- RG `rg-central-us-hardware-imaging`, VNet `vn-central-us-hardware-imaging` + subnet
  `sn-central-us-hardware-imaging-packer` (retained; not required for access now).
- Storage account **`hardwareimaging`** (StorageV2, LRS): `network_rules.default_action
  = Allow` (no IP firewall), `shared_access_key_enabled = false` (no key/SAS),
  `allow_nested_items_to_be_public = false`, TLS1.2, HTTPS-only. Managed via an
  aliased `azurerm` provider with `storage_use_azuread = true` (keys disabled).
- Containers: `resources` (sources: WIMs/, ISOs/, drivers/, tools/), `captured` (outputs: WIMs/, ISOs/), and `legacy-images` (old previously-built images) — all private.
- RBAC: Packer/`worker_images` SP = **Blob Data Contributor**; MDC1 downloader SP
  = **Blob Data Reader** on `captured` only; **Relops group** = Blob Data
  Owner + Contributor (+ Queue/File Data roles so Terraform can read service
  properties via AAD).

`relops_infra_as_code/terraform/azure_ad/sp_nuc_wim_downloader.tf`:
- Entra app/SP `sp-relops-nuc-wim-downloader` for the on-site MDC1 server + a
  client secret. **Not** stored in Key Vault (MDC1 isn't Entra-joined) — kept as a
  local file on the box; lives only in Terraform state.

## Access paths (all Entra `--auth-mode login`, any network)
- **Azure build VM**: authenticates with its **system-assigned managed identity**
  (granted Blob Data Contributor by `New-WinHwWimBuildVm.ps1`) — reads `resources`,
  writes `captured`. No secret on the box.
- **On-site MDC1 server**: `az login --service-principal` with the downloader SP
  (needs outbound reach to `login.microsoftonline.com`), reads `captured`.
- **Operators**: their own Entra identity via the Relops group.

## Pipeline wiring
- Build host, before build: `download-wim.ps1` pulls the base WIM from `resources/WIMs/` →
  `prepare-base-vhdx.ps1`.
- Build host, after capture: `upload-wim.ps1` pushes the WIM (+ `.sha256`) to
  `captured/WIMs/<image>/`.
- Deploy: MDC1 server `download-wim.ps1` pulls from `captured/WIMs/` to the MDT share,
  then the existing PXE dance applies it.

## Notes
- Verified: anonymous → `PublicAccessNotPermitted`; account-key → `KeyBasedAuthenticationNotPermitted`;
  Entra identity + Blob Data role → works from any network.
- Resources rebranded `nuc-wim` → `hardware-imaging` (RG/VNet/subnet/UAMI/account) for
  prod prep; the pipeline tooling uses the generic `win-hw-wim` naming. The downloader SP
  `sp-relops-nuc-wim-downloader` keeps its name (renaming would rotate its secret).
