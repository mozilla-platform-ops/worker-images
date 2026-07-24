<#
.SYNOPSIS
  Provision the Azure VM that builds Windows HW install.wim images with Packer (nested
  Hyper-V). The "scripting in worker-images" entry point for standing up the
  build host; the WIM build itself stays Packer (bin/WinHwWim/New-WinHwWim.ps1).

.DESCRIPTION
  Creates a nested-virtualization-capable Windows Server VM in the existing
  win-hw-wim network (rg-central-us-nuc-wim / sn-central-us-nuc-wim-packer, from the
  storage Terraform), attaches a Premium data disk for build artifacts, gives it a
  system-assigned managed identity, grants that identity Storage Blob Data
  Contributor on nucwimfxci (so azcopy --auth-mode login works with no secrets),
  and bootstraps Hyper-V + Packer + ADK + azcopy + git.

  Nested virtualization requires a supported SKU (Dv3/Dv4/Dv5, Ev3+, Fsv2, ...);
  default Standard_D8s_v5.

  After it finishes: RDP in (or `az vm run-command`) and run the build:
    cd C:\worker-images\provisioners\windows\win-hw-wim   # (clone the repo there)
    az login --identity
    .\bin\WinHwWim\New-WinHwWim.ps1 -Image win11-24h2-hw

.PARAMETER AllowRdpFrom
  CIDR(s) allowed to RDP (NSG). Default: Mozilla VPN netblocks. Pass your real
  egress if VPN is split-tunnel. Use -NoPublicIp to skip inbound entirely.

.EXAMPLE
  ./New-WinHwWimBuildVm.ps1 -AllowRdpFrom 63.245.208.132/32
#>
[CmdletBinding()]
param(
    [string]   $VmName         = 'win-hw-wim-builder',
    [string]   $ResourceGroup  = 'rg-central-us-nuc-wim',
    [string]   $Location       = 'centralus',
    [string]   $VnetName       = 'vn-central-us-nuc-wim',
    [string]   $SubnetName     = 'sn-central-us-nuc-wim-packer',
    [string]   $Size           = 'Standard_D8s_v5',   # nested-virt capable
    [string]   $Image          = 'MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest',
    [int]      $DataDiskGB     = 512,
    [string]   $StorageAccount = 'nucwimfxci',
    [string]   $AdminUsername  = 'nucadmin',
    [string]   $AdminPassword,                        # generated + printed if omitted
    [string[]] $AllowRdpFrom   = @('63.245.208.132/32', '63.245.208.133/32', '63.245.210.132/32', '63.245.210.133/32', '185.155.182.210/32'),
    [switch]   $NoPublicIp
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Az { $o = az @args 2>&1; if ($LASTEXITCODE) { throw "az $($args -join ' ') failed:`n$o" }; return $o }

$sub = (Az account show --query id -o tsv)
Write-Host "== Subscription: $sub =="

$subnetId  = (Az network vnet subnet show -g $ResourceGroup --vnet-name $VnetName -n $SubnetName --query id -o tsv)
$storageId = (Az storage account show -g $ResourceGroup -n $StorageAccount --query id -o tsv)

if (-not $AdminPassword) {
    Add-Type -AssemblyName System.Web
    $AdminPassword = [System.Web.Security.Membership]::GeneratePassword(24, 6)
    Write-Host "== Generated admin password (save it now): $AdminPassword =="
}

Write-Host "== Creating VM $VmName ($Size, nested-virt) in $SubnetName =="
$pip = if ($NoPublicIp) { '""' } else { "$VmName-pip" }
Az vm create `
    -g $ResourceGroup -n $VmName -l $Location `
    --image $Image --size $Size `
    --admin-username $AdminUsername --admin-password $AdminPassword `
    --subnet $subnetId --public-ip-address $pip --nsg "$VmName-nsg" `
    --assign-identity '[system]' `
    --os-disk-size-gb 128 --storage-sku Premium_LRS `
    --data-disk-sizes-gb $DataDiskGB `
    --output none

# Lock RDP down to the allow-list (default-deny otherwise).
if (-not $NoPublicIp) {
    Write-Host "== NSG: allow RDP only from $($AllowRdpFrom -join ', ') =="
    Az network nsg rule create -g $ResourceGroup --nsg-name "$VmName-nsg" -n allow-rdp `
        --priority 300 --access Allow --protocol Tcp --direction Inbound `
        --destination-port-ranges 3389 --source-address-prefixes @AllowRdpFrom --output none
}

# Grant the VM's managed identity blob data access (Entra-only storage).
$principalId = (Az vm show -g $ResourceGroup -n $VmName --query identity.principalId -o tsv)
Write-Host "== Granting Storage Blob Data Contributor to VM identity $principalId =="
Az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal `
    --role 'Storage Blob Data Contributor' --scope $storageId --output none

# Bootstrap: Hyper-V (phase 1) -> reboot -> tooling (phase 2).
$boot = Join-Path $PSScriptRoot 'scripts\bootstrap-build-host.ps1'
Write-Host '== Bootstrap phase 1: enable Hyper-V =='
Az vm run-command invoke -g $ResourceGroup -n $VmName --command-id RunPowerShellScript `
    --scripts "@$boot" --parameters 'Phase=Hyperv' --output none
Write-Host '== Rebooting for Hyper-V =='
Az vm restart -g $ResourceGroup -n $VmName --output none
Write-Host '== Bootstrap phase 2: install Packer/ADK/azcopy/git/az + powershell-yaml =='
Az vm run-command invoke -g $ResourceGroup -n $VmName --command-id RunPowerShellScript `
    --scripts "@$boot" --parameters 'Phase=Tooling' --output none

$ip = if ($NoPublicIp) { '(no public IP — use Bastion/jumpbox)' } else { (Az vm show -d -g $ResourceGroup -n $VmName --query publicIps -o tsv) }
Write-Host ""
Write-Host "== Build host ready =="
Write-Host "   VM      : $VmName ($Size)   RDP: $ip   user: $AdminUsername"
Write-Host "   Identity: $principalId  (Storage Blob Data Contributor on $StorageAccount)"
Write-Host "   Next    : RDP in, clone worker-images, then:"
Write-Host "             az login --identity"
Write-Host "             .\provisioners\windows\win-hw-wim\bin\WinHwWim\New-WinHwWim.ps1 -Image win11-24h2-hw"
