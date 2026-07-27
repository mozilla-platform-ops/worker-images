<#
.SYNOPSIS
  Create or destroy the EPHEMERAL Azure build VM for a Windows HW WIM build. Runs on
  the GitHub Actions runner (pwsh + az, already authenticated by azure/login).

.DESCRIPTION
  The workflow spins this VM up per run and tears it down afterward (in an
  if: always() step), so there is no idle cost and no long-lived build host.

  -Action create : nested-virt VM (no public IP / no NSG — driven only via
    az vm run-command), system-assigned managed identity granted Storage Blob Data
    Contributor on the storage account, Premium data disk, then bootstrap Hyper-V +
    tooling (provisioners/windows/win-hw-wim/scripts/bootstrap-build-host.ps1).
  -Action destroy : remove the VM + its OS disk + NIC + the MI role assignment.
    Idempotent and best-effort so teardown never leaves the job stuck; safe to run
    even if create only partially succeeded.

  The VM name is run-scoped (e.g. win-hw-wim-build-<run_id>) so parallel runs don't
  collide and teardown targets exactly this run's VM.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('create', 'destroy')] [string] $Action,
    [Parameter(Mandatory)] [string] $VmName,
    [string] $ResourceGroup  = 'rg-central-us-nuc-wim',
    [string] $VnetName       = 'vn-central-us-nuc-wim',
    [string] $SubnetName     = 'sn-central-us-nuc-wim-packer',
    [string] $Size           = 'Standard_D64ads_v5',   # AMD, 64 vCPU/256 GiB, nested-virt capable (fits DADSv5 64-core quota)
    # Plain Windows Server 2025 gen2 (NOT azure-edition — azure-edition pushes Trusted
    # Launch, which is incompatible with nested virtualization).
    [string] $Image          = 'MicrosoftWindowsServer:WindowsServer:2025-datacenter-g2:latest',
    [int]    $DataDiskGB     = 512,
    # Pre-provisioned user-assigned identity (Terraform) attached to the VM for blob
    # access — so no per-run role assignment (and no role-assignment rights) is needed.
    [string] $BuilderIdentityName = 'id-central-us-wim-builder'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# Resolve the real az executable — PowerShell is case-insensitive, so a function
# named "Az" would otherwise shadow "az" and recurse infinitely.
$azExe = (Get-Command az -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
function Az { $o = & $azExe @args 2>&1; if ($LASTEXITCODE) { throw "az $($args -join ' ') failed:`n$o" }; return $o }
function AzTry { & $azExe @args 2>&1 | Out-Null }   # best-effort (teardown)

if ($Action -eq 'create') {
    $subnetId = (Az network vnet subnet show -g $ResourceGroup --vnet-name $VnetName -n $SubnetName --query id -o tsv)

    # Random admin password (never used — no RDP; az just requires one). Portable:
    # System.Web isn't available in pwsh 7 on Linux. Guid hex + 'Aa1!' meets Azure complexity.
    $pw = 'Aa1!' + [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N').Substring(0, 12)

    $uamiId = (Az identity show -g $ResourceGroup -n $BuilderIdentityName --query id -o tsv)
    # Windows computer name is capped at 15 chars, so derive a short one from the
    # (longer) run-scoped VM resource name. It's just an ephemeral standalone host.
    $computerName = ($VmName -replace '[^a-zA-Z0-9]', '')
    if ($computerName.Length -gt 15) { $computerName = $computerName.Substring(0, 15) }
    Write-Host "== Creating ephemeral VM $VmName ($Size, no public IP; computer $computerName; identity $BuilderIdentityName) =="
    Az vm create -g $ResourceGroup -n $VmName `
        --image $Image --size $Size --computer-name $computerName `
        --security-type Standard `
        --admin-username nucadmin --admin-password $pw `
        --subnet $subnetId --public-ip-address "" --nsg "" `
        --assign-identity $uamiId `
        --os-disk-size-gb 128 --storage-sku Premium_LRS `
        --data-disk-sizes-gb $DataDiskGB --output none

    # Forward slashes so the path resolves on the Linux runner too.
    $boot = "$PSScriptRoot/../provisioners/windows/win-hw-wim/scripts/bootstrap-build-host.ps1"
    if (-not (Test-Path $boot)) { throw "bootstrap script not found: $boot" }
    $bootBody = Get-Content -Raw $boot

    # Run a bootstrap phase and ASSERT its success sentinel. `az vm run-command` returns
    # exit 0 even if the inner script throws, so we can't rely on the az exit code.
    # Inline the phase assignment + script content as ONE --scripts value (mixing a
    # literal line with @file, or --parameters -> params, proved unreliable).
    function Invoke-Phase([string]$Ph) {
        $script = "`$Phase = '$Ph'`n" + $bootBody
        # Capture ALL message streams (value[0]=stdout, value[1]=stderr) — a thrown
        # error lands in stderr, so querying only value[0] hid the real failure.
        $msg = Az vm run-command invoke -g $ResourceGroup -n $VmName --command-id RunPowerShellScript `
            --scripts $script --query "join('`n', value[].message)" -o tsv
        if ("$msg" -notmatch 'BOOTSTRAP_PHASE_OK') { throw "bootstrap phase '$Ph' did not succeed:`n$msg" }
        Write-Host "  phase $Ph OK"
    }

    Write-Host '== Bootstrap phase 1: Hyper-V =='
    Invoke-Phase 'Hyperv'
    Write-Host '== Reboot for Hyper-V =='
    Az vm restart -g $ResourceGroup -n $VmName --output none
    Start-Sleep -Seconds 30
    Write-Host '== Bootstrap phase 2: tooling (retry for guest-agent readiness) =='
    $ok = $false
    for ($i = 1; $i -le 5; $i++) {
        try { Invoke-Phase 'Tooling'; $ok = $true; break }
        catch { Write-Warning "phase 2 attempt $i failed; retry in 30s. $_"; Start-Sleep 30 }
    }
    if (-not $ok) { throw 'Bootstrap phase 2 (tooling) failed after retries.' }
    Write-Host "== Ephemeral build VM $VmName ready =="
}
else {
    Write-Host "== Destroying ephemeral VM $VmName (best-effort) =="
    # Capture child resource ids before deleting the VM (az vm delete doesn't cascade).
    # Use $azExe directly (best-effort; the VM may not exist) — not the throwing Az wrapper.
    $diskId = (& $azExe vm show -g $ResourceGroup -n $VmName --query "storageProfile.osDisk.managedDisk.id" -o tsv 2>$null)
    $nicIds = (& $azExe vm show -g $ResourceGroup -n $VmName --query "networkProfile.networkInterfaces[].id" -o tsv 2>$null)
    $dataDisks = (& $azExe vm show -g $ResourceGroup -n $VmName --query "storageProfile.dataDisks[].managedDisk.id" -o tsv 2>$null)
    # The UAMI is persistent (Terraform-managed) and just attached — nothing to detach/remove here.

    AzTry vm delete -g $ResourceGroup -n $VmName --yes
    foreach ($nic in ($nicIds -split "`n" | Where-Object { $_ })) { Write-Host "  deleting nic $nic"; AzTry network nic delete --ids $nic }
    foreach ($d in (@($diskId) + ($dataDisks -split "`n") | Where-Object { $_ })) { Write-Host "  deleting disk $d"; AzTry disk delete --ids $d --yes }

    # Sweep by name prefix — catches resources az created before a FAILED 'vm create'
    # (the VM never existed, so 'az vm show' above found nothing). az's default NIC is
    # <VmName>VMNic; disks are <VmName>_*.
    foreach ($n in ((& $azExe network nic list -g $ResourceGroup --query "[?starts_with(name,'$VmName')].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ })) {
        Write-Host "  deleting leaked nic $n"; AzTry network nic delete -g $ResourceGroup -n $n
    }
    foreach ($d in ((& $azExe disk list -g $ResourceGroup --query "[?starts_with(name,'$VmName')].name" -o tsv 2>$null) -split "`n" | Where-Object { $_ })) {
        Write-Host "  deleting leaked disk $d"; AzTry disk delete -g $ResourceGroup -n $d --yes
    }
    Write-Host "== Teardown complete for $VmName =="
}
