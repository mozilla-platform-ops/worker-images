# WIM storage design (Azure Blob, Tier-1 private)

Decision (2026-07-21): store both the base and captured WIMs in **Azure Blob**,
locked down as a **Tier-1 private** account — public endpoint retained but
**deny-by-default firewall + required auth**, which the user confirmed is
acceptable ("as long as there is an auth method"). This avoids building an
Azure↔MDC1 VPN, which does not exist today.

## Why not reuse `roninpuppetassets`
It's fully public (`container_access_type = "blob"`, anonymous read). WIMs must
not be anonymously downloadable, so we use a **new, network-restricted** account.

## What was provisioned (Terraform, branch `nuc-wim-storage`, NOT pushed)
`relops_infra_as_code/terraform/azure_fxci/nuc-wim-storage.tf`:
- RG `rg-central-us-nuc-wim`, VNet `vn-central-us-nuc-wim` (10.20.0.0/24), Packer
  subnet `sn-central-us-nuc-wim-packer` (10.20.0.0/26) with the
  `Microsoft.Storage` **service endpoint**.
- Storage account **`nucwimfxci`** (Central US, StorageV2, LRS):
  `public_network_access_enabled = true` but `network_rules.default_action = Deny`,
  allowing only the Packer subnet + `var.mdc1_egress_cidrs`; no anonymous access
  (`allow_nested_items_to_be_public = false`); TLS1.2; HTTPS-only.
- Containers `base` (BYO starting WIM) and `captured` (baked output), both private.
- RBAC: Packer SP (`worker_images` object id) = **Storage Blob Data Contributor**;
  MDC1 downloader SP = **Storage Blob Data Reader** on `captured` only.

`relops_infra_as_code/terraform/azure_ad/sp_nuc_wim_downloader.tf`:
- Entra app/SP `sp-relops-nuc-wim-downloader` for the on-site server + a client
  secret (store in `kv-central-us-key`, do not commit).

## Access paths
- **Packer build VM** (Azure): launches in the Packer subnet → allowed by the
  firewall via the service endpoint → reads `base`, writes `captured` using its
  SP (Entra `--auth-mode login`). No secret needed (managed control-plane SP).
- **On-site MDC1 server**: reaches the public FQDN from its allow-listed egress
  IP; authenticates with the downloader SP (client_id+secret from Key Vault) or a
  read-only SAS. Downloads from `captured`.

## Pipeline wiring
- Host, before build: `download-wim.ps1` pulls the base WIM from `base/` →
  feed to `prepare-base-vhdx.ps1`.
- Host, after capture: `upload-wim.ps1` pushes `install.wim` (+ `.sha256`) to
  `captured/`.
- Deploy: MDC1 server `download-wim.ps1` pulls from `captured/` to the MDT share,
  then the existing PXE dance applies it.

## Open confirmations (parameterized, not blocking)
1. **MDC1 egress IP** — `var.mdc1_egress_cidrs` defaults to `63.245.208.251/32`
   (the MDC1 gateway used by the AWS S2S VPN). Confirm with netops.
2. **Auth method for MDC1** — SP+secret (default, RBAC wired) vs read-only SAS
   (set `nuc_wim_downloader_object_id = ""` to skip the RBAC grant and use a SAS
   from Key Vault instead).

## Apply order
1. `azure_ad`: apply → get `nuc_wim_downloader_object_id` output.
2. `azure_fxci`: apply with `-var nuc_wim_downloader_object_id=<that>` (and
   `-var 'mdc1_egress_cidrs=[...]'` if different). Both via PR, never main.
