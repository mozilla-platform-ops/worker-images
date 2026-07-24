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
    [string] $Size           = 'Standard_D8s_v5',
    [string] $Image          = 'MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest',
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

    Add-Type -AssemblyName System.Web
    $pw = [System.Web.Security.Membership]::GeneratePassword(32, 8)   # never used (no RDP); required by az

    $uamiId = (Az identity show -g $ResourceGroup -n $BuilderIdentityName --query id -o tsv)
    Write-Host "== Creating ephemeral VM $VmName ($Size, no public IP; identity $BuilderIdentityName) =="
    Az vm create -g $ResourceGroup -n $VmName `
        --image $Image --size $Size `
        --admin-username nucadmin --admin-password $pw `
        --subnet $subnetId --public-ip-address "" --nsg "" `
        --assign-identity $uamiId `
        --os-disk-size-gb 128 --storage-sku Premium_LRS `
        --data-disk-sizes-gb $DataDiskGB --output none

    $boot = Join-Path $PSScriptRoot '..\provisioners\windows\win-hw-wim\scripts\bootstrap-build-host.ps1'
    Write-Host '== Bootstrap phase 1: Hyper-V =='
    Az vm run-command invoke -g $ResourceGroup -n $VmName --command-id RunPowerShellScript `
        --scripts "@$boot" --parameters 'Phase=Hyperv' --output none
    Write-Host '== Reboot for Hyper-V =='
    Az vm restart -g $ResourceGroup -n $VmName --output none
    Start-Sleep -Seconds 30
    Write-Host '== Bootstrap phase 2: tooling =='
    $ok = $false
    for ($i = 1; $i -le 5; $i++) {
        try {
            Az vm run-command invoke -g $ResourceGroup -n $VmName --command-id RunPowerShellScript `
                --scripts "@$boot" --parameters 'Phase=Tooling' --output none
            $ok = $true; break
        } catch { Write-Warning "phase 2 attempt $i failed; retry in 30s"; Start-Sleep 30 }
    }
    if (-not $ok) { throw 'Bootstrap phase 2 failed after retries.' }
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
    Write-Host "== Teardown complete for $VmName =="
}
