<#
.SYNOPSIS
  Prepare an Azure VM to be a win-hw-wim build host: nested Hyper-V + tooling.
  Runs ON the VM via `az vm run-command`.

.DESCRIPTION
  Driven by a script-scope $Phase variable (NOT a param) because
  `az vm run-command --parameters` does not reliably map to script parameters —
  the caller prepends `$Phase = 'Hyperv'` (or 'Tooling') as a separate --scripts line.

    Hyperv  : enable the Hyper-V role (caller reboots afterward).
    Tooling : install Packer, azcopy, git, az CLI (DISM is native), powershell-yaml.

  On success each phase prints the sentinel BOOTSTRAP_PHASE_OK — the caller asserts it,
  because `az vm run-command` returns exit 0 even when the inner script throws.
  Needs a nested-virtualization-capable SKU (Dv3/Dv4/Dv5, Ev3+, Fsv2, ...).
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $Phase) { throw "Set `$Phase to 'Hyperv' or 'Tooling' before running this script." }
if ($Phase -notin @('Hyperv', 'Tooling')) { throw "Invalid `$Phase '$Phase' (expected Hyperv or Tooling)." }
$DataDriveLetter = 'F'

if ($Phase -eq 'Hyperv') {
    Write-Host '== Enabling Hyper-V role (reboot required afterwards) =='
    $r = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools
    Write-Host "  Success=$($r.Success) RestartNeeded=$($r.RestartNeeded)"
    if (-not $r.Success) { throw "Install-WindowsFeature Hyper-V failed: $($r | Out-String)" }
    Write-Output 'BOOTSTRAP_PHASE_OK'
    return
}

# ---- Phase: Tooling ----------------------------------------------------------
if (-not (Get-WindowsFeature -Name Hyper-V).Installed) {
    throw 'Hyper-V not installed yet. Run Phase Hyperv and reboot first.'
}

# Nested-VM network: an INTERNAL switch + NAT. Windows Server has no client
# "Default Switch", and an Azure host can't bridge a nested VM onto the vnet, so
# the bake VM gets outbound internet (ronin/git/choco/Windows Update) and a
# host-reachable IP for Packer WinRM through NAT. The guest gets a matching STATIC
# IP via the injected unattend (scripts/unattend/unattend.xml.template) because a
# NAT switch has no DHCP. Keep these in sync with that template.
$SwitchName = 'wim-nat'
$HostNatIp  = '192.168.234.1'
$NatPrefix  = '192.168.234.0/24'
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    Write-Host "== Creating internal NAT switch $SwitchName =="
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
}
$ifAlias = "vEthernet ($SwitchName)"
if (-not (Get-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $HostNatIp -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceAlias $ifAlias -IPAddress $HostNatIp -PrefixLength 24 | Out-Null
}
if (-not (Get-NetNat -Name $SwitchName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $SwitchName -InternalIPInterfaceAddressPrefix $NatPrefix | Out-Null
}
Write-Host "== NAT switch $SwitchName ready ($NatPrefix via $HostNatIp) =="

# Initialize + mount the data disk (if a raw disk is attached) for build artifacts.
$raw = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Select-Object -First 1
if ($raw) {
    Write-Host "== Initializing data disk #$($raw.Number) as ${DataDriveLetter}: =="
    $raw | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -DriveLetter $DataDriveLetter -UseMaximumSize |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel 'build' -Confirm:$false | Out-Null
}

# Chocolatey.
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Host '== Installing Chocolatey =='
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
    $env:Path += ";$env:ProgramData\chocolatey\bin"
    if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { throw 'Chocolatey install failed.' }
}

# DISM is built into Windows (System32) — no ADK package needed for the WIM
# apply/capture cmdlets (Expand-WindowsImage / New-WindowsImage) the pipeline uses.
foreach ($pkg in 'packer', 'azcopy10', 'git', 'azure-cli') {
    Write-Host "== choco install $pkg =="
    & choco install $pkg -y --no-progress --limit-output
    if ($LASTEXITCODE -notin 0, 3010) { throw "choco install $pkg failed rc=$LASTEXITCODE" }
}

Write-Host '== Installing powershell-yaml module =='
if (-not (Get-Module -ListAvailable powershell-yaml)) {
    # In a non-interactive run-command session, Install-Module HANGS forever
    # prompting to bootstrap the NuGet provider / trust the PSGallery repo.
    # Pre-install the provider and mark PSGallery trusted so nothing prompts.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -Scope AllUsers -Force -Confirm:$false
}

# Refresh PATH from the machine env so the just-installed tools resolve now.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')

# Verify the toolchain actually installed (fail loudly — run-command hides inner errors).
$missing = @()
foreach ($t in 'packer', 'git', 'azcopy', 'az', 'dism') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t }
}
if ($missing) { throw "Tooling missing after install: $($missing -join ', ')" }

Write-Host '== Build host ready (packer/git/azcopy/az/dism present). =='
Write-Output 'BOOTSTRAP_PHASE_OK'
