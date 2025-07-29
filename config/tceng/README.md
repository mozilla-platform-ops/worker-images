# TCEng Image Build Metadata

This directory contains configuration, provisioning, and metadata related to building Azure images for the TCEng (Taskcluster Engineering) team.

---

## 📁 Directory Structure

- `config/tceng/`  
  YAML files defining metadata and configurations for each image set (e.g. `generic-worker-win2022-staging.yaml`, `image _development.yaml`).

- `scripts/windows/tceng/`  
  PowerShell bootstrap scripts for Windows images. These are run by Packer during provisioning.

- `scripts/linux/tceng/`  
  Bootstrap scripts for Linux-based image builds.

---

## ✏️ Ownership and Access

The **TCEng team has direct write access** to the following directories:
- `config/tceng/`
- `scripts/windows/tceng/`
- `scripts/linux/tceng/`

These directories house image definitions and platform-specific bootstrap logic maintained by TCEng.

---

## 🔐 Authorized User Enforcement

Access to the [TCEng image build workflow](https://github.com/mozilla-platform-ops/worker-images/blob/main/.github/workflows/nonsig-tceng-azure.yml) is **restricted by GitHub Actions**. Before executing the workflow, the following file is used to authorize users:

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
  [`.github/workflows/nonsig-tceng-azure.yml`](https://github.com/mozilla-platform-ops/worker-images/blob/main/.github/workflows/nonsig-tceng-azure.yml)  
  Defines how TCEng images are built in CI using GitHub Actions.

- **Access Control List**  
  [`.github/tceng.json`](https://github.com/mozilla-platform-ops/worker-images/blob/main/.github/tceng.json)  
  Defines which GitHub users are authorized to trigger the workflow.

- **Image Build Script**  
  [`bin/WorkerImages/Public/New-AzWorkerImage.ps1`](https://github.com/mozilla-platform-ops/worker-images/blob/main/bin/WorkerImages/Public/New-AzWorkerImage.ps1)  
  PowerShell module function used to parse image YAMLs and launch a Packer build.

- **Packer HCL Template**  
  [`packer/tceng-azure.pkr.hcl`](https://github.com/mozilla-platform-ops/worker-images/blob/main/packer/tceng-azure.pkr.hcl)  
  Contains the Packer source and build configuration for non-SIG Azure image builds.

If you need to change how images are built or who can trigger them, submit a PR modifying these files.

---

## 🧪 Development Workflow

For users who want to test image builds **without modifying named configurations**, TCEng supports a general-purpose test config:

- [`image _development.yaml`](https://github.com/mozilla-platform-ops/worker-images/blob/main/config/tceng/image%20_development.yaml)

### Usage:

1. Edit `config/tceng/image _development.yaml` with the values for your image.
2. Run the `nonsig-tceng-azure.yml` workflow from GitHub Actions.
3. Select `image _development` from the `config` dropdown input.

This allows for safely prototyping new images without adding them to the workflow permanently.

---

## 🧾 YAML Structure

Each YAML file under `config/tceng/` defines an image and follows this structure:

```yaml
image:
  publisher: MicrosoftWindowsServer
  offer: WindowsServer
  sku: 2022-datacenter-azure-edition
  version: latest

azure:
  locations:
    - centralus
    - eastus
  managed_image_resource_group_name: "rg-tc-eng-images"
  managed_image_storage_account_type: "Standard_LRS"
  bootstrapscript: "azure_staging_bootstrap"

vm:
  providerType: azure
  vm_size: Standard_D2s_v3
  taskcluster_ref: main
  taskcuster_repo: https://github.com/taskcluster/taskcluster
  tags:
    base_image: ...
    sourceBranch: ...
    sourceRepository: ...
    sourceOrganization: ...
    deploymentId: ...
    worker_pool_id: ...