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
# the bake VM gets outbound internet (Ronin/Git/Windows Update) and a
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

function Install-BuildHostTools {
    $bin = Join-Path $env:ProgramFiles 'WimBuildTools\bin'
    $stage = Join-Path $env:ProgramFiles ("WimBuildTools\stage-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $bin, $stage -Force | Out-Null
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    function Get-BuildTool($Url, $Name) {
        $destination = Join-Path $stage $Name
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Write-Host "== Downloading $Name (attempt $attempt) =="
                Invoke-WebRequest -Uri $Url -OutFile $destination -UseBasicParsing -TimeoutSec 300
                return $destination
            } catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds 10
            }
        }
    }

    function Invoke-BuildInstaller($Path, $Arguments) {
        Write-Host "== Installing $Path =="
        $process = Start-Process -FilePath $Path -ArgumentList $Arguments -Wait -PassThru
        if ($process.ExitCode -notin 0, 3010) { throw "Installer $Path failed rc=$($process.ExitCode)" }
    }

    try {
        if (-not (Get-Command packer -ErrorAction SilentlyContinue)) {
            $zip = Get-BuildTool 'https://releases.hashicorp.com/packer/1.16.2/packer_1.16.2_windows_amd64.zip' 'packer.zip'
            Expand-Archive -Path $zip -DestinationPath "$stage\packer" -Force
            Copy-Item -Path "$stage\packer\packer.exe" -Destination $bin -Force
        }
        if (-not (Get-Command azcopy -ErrorAction SilentlyContinue)) {
            $zip = Get-BuildTool 'https://github.com/Azure/azure-storage-azcopy/releases/download/v10.34.1/azcopy_windows_amd64_10.34.1.zip' 'azcopy.zip'
            Expand-Archive -Path $zip -DestinationPath "$stage\azcopy" -Force
            $exe = Get-ChildItem -Path "$stage\azcopy" -Filter azcopy.exe -Recurse | Select-Object -First 1
            if (-not $exe) { throw 'AzCopy archive did not contain azcopy.exe.' }
            Copy-Item -Path $exe.FullName -Destination $bin -Force
        }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
            $installer = Get-BuildTool 'https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/Git-2.56.0.2-64-bit.exe' 'git.exe'
            Invoke-BuildInstaller $installer '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP- /o:PathOption=Cmd'
        }
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            $installer = Get-BuildTool 'https://github.com/Azure/azure-cli/releases/download/azure-cli-2.92.0/azure-cli-2.92.0-x64.msi' 'azure-cli.msi'
            Invoke-BuildInstaller 'msiexec.exe' "/i `"$installer`" /qn /norestart"
        }
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        if (($machinePath -split ';') -notcontains $bin) {
            [Environment]::SetEnvironmentVariable('Path', "$machinePath;$bin", 'Machine')
        }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
}

# DISM is built into Windows; the other tools come directly from vendor releases.
Install-BuildHostTools

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
