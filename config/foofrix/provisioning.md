# Provision Azure workers from the GCP Linux launcher

`scripts/foofrix/azure-worker.sh` is a Bash starting point for Perf to adapt into
FooFrix. It uses Azure CLI and the **VM-provisioning service principal**, not the
worker-images build identity. Run it on the GCP Linux launcher; the workers it
creates run Windows in Azure.

The existing harness's `scripts/launch-optimize-worker.sh` creates GCE workers,
queues jobs, supplies Linux/systemd startup configuration, and waits for a worker
heartbeat. Its `scripts/stop-worker-vm.sh` stops the scheduler and updates GCS state
before stopping/deleting a VM. This example provides the Azure resource operations
only. Perf retains those queue, heartbeat, graceful-stop, and retry responsibilities.

## Prerequisites

- Install Azure CLI on the GCP launcher.
- Deploy the FooFrix subscription, provisioning identity, worker managed identity,
  vault, storage, and gallery from infrastructure PR #339, and publish an image.
- Provide a subnet and NSG in that subscription and the chosen region. Configure
  explicit outbound connectivity (for example NAT Gateway) and the required
  outbound rules for Azure services, GCS, code downloads, and model APIs.
- Choose a private access route for operators, such as VPN or Bastion. This script
  creates no public IP and opens no RDP/WinRM ports. A GCP VM can call Azure APIs
  without a private route, but direct connections to the Windows VM require one.
- Confirm VM size availability/quota and image replication in the chosen region.
  Match `AZURE_SECURITY_TYPE` to the gallery definition; the example defaults to
  `Standard`. GPU drivers and performance checks remain image work.

## Configure and create

Load `AZURE_CLIENT_SECRET` and `WINDOWS_ADMIN_PASSWORD` privately from your secret
store. Do not put their values in source control, command examples, shell tracing,
or dashboard logs. The admin password must satisfy Azure's Windows password rules.
Keep it in your secret store for operator access. The script uses an isolated,
temporary Azure CLI login/cache and removes that cache when it exits.

Set the non-secret environment variables using the infrastructure outputs:

```bash
export AZURE_TENANT_ID='<Mozilla tenant ID>'
export AZURE_SUBSCRIPTION_ID='<FooFrix subscription ID>'
export AZURE_CLIENT_ID='<FooFrix VM provisioner client ID>'
export AZURE_WORKER_IDENTITY_ID='<worker managed identity resource ID>'
export AZURE_IMAGE_VERSION_ID='/subscriptions/<subscription>/resourceGroups/rg-foofrix/providers/Microsoft.Compute/galleries/foofrix/images/foofrix_win11_25h2/versions/0.1.0'
export AZURE_SUBNET_ID='<full existing subnet resource ID>'
export AZURE_NSG_ID='<full existing NSG resource ID>'
export AZURE_LOCATION=centralus
export AZURE_VM_SIZE='<agreed size with regional quota>'
export AZURE_OS_DISK_GB=1024

bash scripts/foofrix/azure-worker.sh create foofrix-win-01
bash scripts/foofrix/azure-worker.sh show foofrix-win-01
```

The final stdout is JSON containing the VM resource ID, name, resource group,
private IP, and power state. A successful create means Azure provisioned the VM;
it does not mean the FooFrix harness is ready. Boot the candidate and validate it
before using it for workloads. The current image draft contains only base tools.

Each worker gets its own `rg-<VM_NAME>` resource group for the VM, NIC, and managed
OS disk. Keep other resources out of this group. The shared subnet/NSG, gallery,
vault, storage account, and managed identity stay in their existing groups.
Creation refuses to reuse an existing worker group. A failed create leaves its
group/resources available for diagnosis; use explicit deletion before retrying.

## Windows startup handoff

Do not pass the current GCE startup script to Azure: it uses Bash, systemd, GCE
metadata, and GCP secret retrieval. Agree on a Windows startup entry point with
Perf that configures the runtime user, retrieves Key Vault secrets using the
attached worker identity, authenticates both the Google SDK and `gcloud`, and
starts the appropriate FooFrix job/scheduler. Managed identity attachment alone
does not create Google credentials or populate API-key environment variables.

Azure Run Command is one possible way to invoke a reviewed PowerShell startup
script from the launcher without inbound ports. Its guest command result must be
checked, and the existing FooFrix heartbeat remains the readiness signal. This
example intentionally does not invent that startup script or modify GCS state.

## Stop and delete

After the harness has stopped gracefully and saved results:

```bash
bash scripts/foofrix/azure-worker.sh stop foofrix-win-01
# Deallocates compute; the managed disk remains and continues to incur storage cost.

bash scripts/foofrix/azure-worker.sh delete foofrix-win-01
# Permanently deletes the worker group, VM, NIC, and ALL disks in that group.
```

The script checks ownership tags before show/stop/delete. It never deletes
`rg-foofrix`. Keep durable results in GCS or export them before deleting the worker.
These are regular VMs with no automatic shutdown timer. Perf's launcher must
enforce the intended lifetime (24+ hours for the initial experiment) and handle
cancellations, job requeueing, capacity failures, and heartbeat cleanup.
