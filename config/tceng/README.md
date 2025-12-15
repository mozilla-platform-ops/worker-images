# TCEng Image Build Metadata

This directory contains configuration, provisioning, and metadata related to building Azure images for the TCEng (Taskcluster Engineering) team.

---

## 📁 Directory Structure

- `config/tceng/`
  YAML files defining metadata and configurations for each image set (e.g. `generic-worker-win2022.yaml`, `image_development.yaml`).

- `scripts/windows/tceng/`
  PowerShell bootstrap scripts for Windows images. These are run by Packer during provisioning.

- `scripts/linux/tceng/`
  Shell bootstrap scripts for Linux-based image builds.

---

## ✏️ Ownership and Access

The **TCEng team has direct write access** to the following directories:
- `config/tceng/`
- `scripts/windows/tceng/`
- `scripts/linux/tceng/`

These directories house image definitions and platform-specific bootstrap logic maintained by TCEng.

To modify shared infrastructure and workflows outside these directories, **a pull request is required** (see below).

---

## 🔐 Authorized User Enforcement

Access to the [TCEng image build workflow](https://github.com/mozilla-platform-ops/worker-images/blob/main/.github/workflows/nonsig-tceng-azure.yml) is **restricted by GitHub Actions**.

Before executing the workflow, the following file is used to authorize users:

- [`tceng.json`](https://github.com/mozilla-platform-ops/worker-images/blob/main/.github/tceng.json)
  This file contains a list of GitHub usernames permitted to trigger TCEng image builds.

### 🔎 How it works:

At the beginning of the `nonsig-tceng-azure.yml` workflow:
- The actor who triggers the workflow (`github.actor`) is checked against both:
  - `.github/tceng.json`
  - `.github/relsre.json`
- If their username is not present in either file, the job fails early with an "unauthorized" message.

To add or remove access, submit a PR modifying `tceng.json`.

---

## 🔒 Requires Pull Request (PR)

The following files and directories are shared infrastructure and require a **PR submission and review** for changes:

- **GitHub Actions Workflow**
  `.github/workflows/nonsig-tceng-azure.yml`
  Defines how TCEng images are built in CI using GitHub Actions.

- **Access Control List**
  `.github/tceng.json`
  Defines which GitHub users are authorized to trigger the workflow.

- **Image Build Script**
  [`New-AzWorkerImage.ps1`](https://github.com/mozilla-platform-ops/worker-images/blob/main/bin/WorkerImages/Public/New-AzWorkerImage.ps1)
  PowerShell module function used to parse image YAMLs and launch a Packer build.

- **Packer HCL Template**
  [`tceng-azure.pkr.hcl`](https://github.com/mozilla-platform-ops/worker-images/blob/main/packer/tceng-azure.pkr.hcl)
  Contains the Packer source and build configuration for non-SIG Azure image builds.

---

## 🧾 YAML Structure

Each YAML file under `config/tceng/` defines an image and follows this structure:

```yaml
image:
  publisher: MicrosoftWindowsServer      # Azure Marketplace publisher
  offer: WindowsServer                   # Marketplace image offer name
  sku: 2022-datacenter-azure-edition     # Specific SKU/version of the OS image
  version: latest                        # Use latest published version

azure:
  locations:                             # Azure regions to replicate the image to
    - centralus
    - eastus
  managed_image_resource_group_name: "rg-tc-eng-images"   # Destination image resource group
  managed_image_storage_account_type: "Standard_LRS"      # Type of storage for managed image

vm:
  providerType: "azure"                     # Always "azure" for these builds
  vm_size: Standard_D2s_v3                  # VM size used during image build
  bootstrapscript: "generic-worker-win2022" # Script name (no extension) located in scripts/windows/tceng/
  tags:
    - image_set: markco-generic-worker-win2022  # Logical grouping name, used for tagging
```

---

### 🧪 `image_development.yaml`

To test or work on new image builds that are **not explicitly listed in the workflow dropdown**, you may use the reserved file:

- [`config/tceng/image_development.yaml`](https://github.com/mozilla-platform-ops/worker-images/blob/main/config/tceng/image%20_development.yaml)

This config allows for temporary or experimental image builds without requiring updates to the workflow’s `config` input options.

You can manually run the workflow and supply `"image_development"` as the build key to use this file.

---

## 🆔 UUID Handling

To ensure image names and resource group names are globally unique, the [`New-AzWorkerImage.ps1`](https://github.com/mozilla-platform-ops/worker-images/blob/main/bin/WorkerImages/Public/New-AzWorkerImage.ps1) script dynamically generates a **20-character lowercase alphanumeric UUID** at runtime for each invocation.

This UUID is injected into:

- **Managed Image Name**
  ```plaintext
  markco-test-imageset-abcde12345xyz67890-centralus
  ```

- **Temporary Resource Group Name**
  ```plaintext
  imageset-abcde12345xyz67890-rg
  ```

This dynamic naming prevents collisions between image builds, especially when using `image_development.yaml` or running jobs concurrently.

---
