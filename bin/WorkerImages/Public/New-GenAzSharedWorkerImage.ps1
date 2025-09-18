Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-GenAzSharedWorkerImage {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        # --- Auth: GitHub OIDC to Azure ---
        [Parameter(Mandatory)] [string] $Client_ID,
        [Parameter(Mandatory)] [string] $Tenant_ID,
        [Parameter(Mandatory)] [string] $Subscription_ID,
        [Parameter(Mandatory)] [string] $oidc_request_url,
        [Parameter(Mandatory)] [string] $oidc_request_token,

        # --- Which config to build (e.g., "win11-64-24h2") ---
        [Parameter(Mandatory)] [string] $Key,

        # --- Paths (repo-relative) ---
        [string] $ConfigDir  = "config\monitor",
        [string] $PackerFile = "packer\gen-sig-azure.hcl",

        # Optional defaults merge; if not present, we just use the image YAML
        [string] $DefaultsPath = "config\windows_production_defaults.yaml",

        # Optional (lets Packer fetch plugins from GitHub if needed)
        [string] $github_token,

        # Utility
        [switch] $GenerateTemplateOnly
    )

    # --- Helpers ---------------------------------------------------------------
    function Ensure-YamlModule {
        if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
            Set-PSRepository PSGallery -InstallationPolicy Trusted
            Install-Module powershell-yaml -ErrorAction Stop
        }
        Import-Module powershell-yaml -ErrorAction Stop
    }

    function Merge-YamlWithDefaults {
        param([hashtable]$ImageData,[hashtable]$DefaultData)
        $merged = @{}
        $all = $ImageData.Keys + $DefaultData.Keys | Select-Object -Unique
        foreach ($k in $all) {
            $img = $ImageData[$k]
            $def = $DefaultData[$k]
            if ($img -is [hashtable] -and $def -is [hashtable]) {
                $merged[$k] = Merge-YamlWithDefaults -ImageData $img -DefaultData $def
            }
            elseif ($img -is [System.Collections.IEnumerable] -and -not ($img -is [string]) -and $img.Count -gt 0) {
                $merged[$k] = $img
            }
            elseif ($img -is [string] -and $img -eq 'default' -and $null -ne $def -and $def -ne 'default') {
                $merged[$k] = $def
            }
            elseif ($null -ne $img -and ($img -isnot [string] -or ($img -ne '' -and $img -ne 'default'))) {
                $merged[$k] = $img
            }
            elseif ($null -ne $def -and $def -ne 'default') {
                $merged[$k] = $def
            }
        }
        return $merged
    }

    function New-ConfigYamlTemplate([string]$OutPath) {
@"
---
image:
  publisher:
  offer:
  sku:
  version:
azure:
  # Regions to replicate the SIG image to
  locations:
    - centralus
    - eastus
  # Resource group that contains your SIG (the *destination* SIG RG)
  managed_image_resource_group_name:
  # SIG identifiers (destination)
  gallery_name:
  image_name:
  image_version:
vm:
  providerType: "azure"
  vm_size:
  # Path to your bootstrap script in repo
  bootstrapscript: "scripts/windows/monitor/host-pool-image-bootstrap.ps1"
  tags:
    # If you need tags, you can add key/values; left blank by default
    # - image_set: monitor-win11-24h2
"@ | Out-File -FilePath $OutPath -Encoding UTF8 -Force
        Write-Host "Created template: $OutPath"
    }

    function Get-FirstNonEmpty($arr) {
        foreach ($x in $arr) {
            if ($x) { return $x }
        }
        return $null
    }

    # --- Early exits / template generation ------------------------------------
    $cfgPath = Join-Path $ConfigDir "$Key.yaml"
    if ($GenerateTemplateOnly) {
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
        New-ConfigYamlTemplate -OutPath $cfgPath
        return
    }

    # --- Load YAML -------------------------------------------------------------
    Ensure-YamlModule

    if (-not (Test-Path $cfgPath)) {
        throw "Config not found: $cfgPath"
    }

    $imgYaml = ConvertFrom-Yaml (Get-Content $cfgPath -Raw)
    $useDefaults = Test-Path $DefaultsPath

    if ($useDefaults) {
        $defYaml = ConvertFrom-Yaml (Get-Content $DefaultsPath -Raw)
        $Y = Merge-YamlWithDefaults -ImageData $imgYaml -DefaultData $defYaml
    } else {
        $Y = $imgYaml
    }

    # --- Extract fields --------------------------------------------------------
    $imgPublisher = $Y.image.publisher
    $imgOffer     = $Y.image.offer
    $imgSku       = $Y.image.sku
    $imgVersion   = $Y.image.version

    # vm size may be vm.vm_size or vm.size
    $vmSize       = if ($Y.vm.PSObject.Properties.Name -contains 'vm_size') { $Y.vm.vm_size } else { $Y.vm.size }

    $bootstrap    = $Y.vm.bootstrapscript

    # build location will be first region; replication covers the entire list
    $locations    = @($Y.azure.locations) | Where-Object { $_ -and $_ -ne '' }
    $buildLocation = $locations | Select-Object -First 1
    $locationsCsv = ($locations -join ',')

    # SIG target
    $sigRG        = $Y.azure.managed_image_resource_group_name
    $sigGallery   = Get-FirstNonEmpty @($Y.sharedimage.gallery_name, $Y.azure.gallery_name)
    $sigImageName = Get-FirstNonEmpty @($Y.sharedimage.image_name,   $Y.azure.image_name)
    $sigVersion   = Get-FirstNonEmpty @($Y.sharedimage.image_version,$Y.azure.image_version)

    foreach ($name in @('imgPublisher','imgOffer','imgSku','imgVersion','vmSize','bootstrap','buildLocation','locationsCsv','sigRG','sigGallery','sigImageName','sigVersion')) {
        if (-not (Get-Variable -Name $name -ValueOnly)) {
            throw "Required value '$name' not found after YAML merge."
        }
    }

    # --- Map to PKR_VAR_* for packer\gen-sig-azure.hcl ------------------------
    $ENV:PKR_VAR_config               = $Key

    $ENV:PKR_VAR_image_publisher      = $imgPublisher
    $ENV:PKR_VAR_image_offer          = $imgOffer
    $ENV:PKR_VAR_image_sku            = $imgSku
    $ENV:PKR_VAR_image_version        = $imgVersion

    $ENV:PKR_VAR_vm_size              = $vmSize
    $ENV:PKR_VAR_location             = $buildLocation
    $ENV:PKR_VAR_replication_regions  = $locationsCsv

    $ENV:PKR_VAR_sig_resource_group   = $sigRG
    $ENV:PKR_VAR_sig_gallery_name     = $sigGallery
    $ENV:PKR_VAR_sig_image_name       = $sigImageName
    $ENV:PKR_VAR_sig_image_version    = $sigVersion

    $ENV:PKR_VAR_bootstrap_script     = $bootstrap

    # temp RG (simple/unique)
    $ENV:PKR_VAR_temp_resource_group_name = "monitor-$($Key)-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))-pkrtmp"

    # OIDC auth for Packer source
    $ENV:PKR_VAR_client_id            = $Client_ID
    $ENV:PKR_VAR_tenant_id            = $Tenant_ID
    $ENV:PKR_VAR_subscription_id      = $Subscription_ID
    $ENV:PKR_VAR_oidc_request_url     = $oidc_request_url
    $ENV:PKR_VAR_oidc_request_token   = $oidc_request_token

    # Optional: allow Packer to fetch plugins from GitHub
    if ($github_token) { $ENV:PACKER_GITHUB_API_TOKEN = $github_token }

    # --- Run Packer (SIG-only) -------------------------------------------------
    if (-not (Test-Path $PackerFile)) { throw "Packer file not found: $PackerFile" }

    Write-Host "=== Building Azure SIG Image ==="
    Write-Host " Key:              $Key"
    Write-Host " Build Location:   $buildLocation"
    Write-Host " Replication:      $locationsCsv"
    Write-Host " SIG RG:           $sigRG"
    Write-Host " SIG Gallery:      $sigGallery"
    Write-Host " SIG Image Name:   $sigImageName"
    Write-Host " SIG Version:      $sigVersion"
    Write-Host " Bootstrap Script: $bootstrap"
    Write-Host " Packer HCL:       $PackerFile"
    Write-Host " Temp RG:          $env:PKR_VAR_temp_resource_group_name"

    packer init $PackerFile
    packer build --only azure-arm.sig $PackerFile
}