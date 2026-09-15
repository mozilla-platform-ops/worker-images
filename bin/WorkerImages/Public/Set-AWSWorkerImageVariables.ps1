function Set-AWSWorkerImageVariables {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-zA-Z0-9_-]+$')] [String] $Key,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9-]+$')] [String] $Region,

        [Parameter(Mandatory = $false)]
        [String] $IamInstanceProfile,

        [Parameter(Mandatory = $false)]
        [String[]] $AmiRegions
    )

    Import-WorkerImagesYaml

    # AWS images are only for tceng
    $YamlPath = "config/tceng/$Key.yaml"
    $ENV:PKR_VAR_Team_key = "tceng"

    $uuid = ([guid]::NewGuid().ToString('N')).Substring(0, 20)
    $ENV:PKR_VAR_uuid = $uuid

    if (-not (Test-Path $YamlPath)) {
        throw "YAML file not found at: $YamlPath"
    }

    # Load and parse YAML configuration
    $YAML = ConvertFrom-Yaml (Get-Content $YamlPath -Raw)
    $ENV:PKR_VAR_config = $Key

    ## AMI naming (tceng uses uuid)
    if (-not $ENV:PKR_VAR_uuid) {
        throw "UUID not set — required for tceng AMI naming"
    }
    $sanitizedUuid = $ENV:PKR_VAR_uuid -replace '[^a-z0-9]', ''
    $amiName = @($YAML.image["ami_name"], $sanitizedUuid) -join "-"
    Write-Host "tceng AMI name: $amiName"
    $ENV:PKR_VAR_ami_name = $amiName

    ## AWS configuration from YAML
    $ENV:PKR_VAR_region = $Region

    if ($YAML.vm["disk_size"]) { $ENV:PKR_VAR_disk_size = $YAML.vm["disk_size"] }
    if ($YAML.vm["instance_type"]) { $ENV:PKR_VAR_instance_type = $YAML.vm["instance_type"] }
    if ($YAML.vm["taskcluster_version"]) { $ENV:PKR_VAR_taskcluster_version = $YAML.vm["taskcluster_version"] }
    if ($YAML.vm["tc_arch"]) { $ENV:PKR_VAR_tc_arch = $YAML.vm["tc_arch"] }
    if ($YAML.vm["script_name"]) { $ENV:PKR_VAR_bootstrap_script = $YAML.vm["script_name"] }

    # AWS-specific image configuration
    if ($YAML.image["source_ami"]) { $ENV:PKR_VAR_source_ami = $YAML.image["source_ami"] }
    if ($YAML.image["source_ami_owner"]) { $ENV:PKR_VAR_source_ami_owner = $YAML.image["source_ami_owner"] }
    if ($YAML.image["source_ami_filter"]) { $ENV:PKR_VAR_source_ami_filter = $YAML.image["source_ami_filter"] }

    # Optional IAM instance profile
    if ($IamInstanceProfile) {
        $ENV:PKR_VAR_iam_instance_profile = $IamInstanceProfile
    }
    elseif ($YAML.aws["iam_instance_profile"]) {
        $ENV:PKR_VAR_iam_instance_profile = $YAML.aws["iam_instance_profile"]
    }

    # AMI replication regions (optional)
    if ($AmiRegions -and $AmiRegions.Count -gt 0) {
        # Convert PowerShell array to JSON array for Packer
        $regionsJson = $AmiRegions | ConvertTo-Json -Compress
        $ENV:PKR_VAR_ami_regions = $regionsJson
        Write-Host "AMI will be replicated to regions: $($AmiRegions -join ', ')"
    }
    elseif ($YAML.aws["ami_regions"]) {
        $regionsJson = $YAML.aws["ami_regions"] | ConvertTo-Json -Compress
        $ENV:PKR_VAR_ami_regions = $regionsJson
        Write-Host "AMI will be replicated to regions from YAML"
    }

    Write-Host "Prepared AMI: $($ENV:PKR_VAR_ami_name) in region: $Region"
    Write-Host "Using AWS credentials from GitHub Actions environment"

    # Ensure AWS credentials from GitHub Actions are available to Packer
    if ($ENV:AWS_ACCESS_KEY_ID) {
        Write-Host "AWS credentials detected from environment"
    }
    else {
        Write-Warning "No AWS credentials found in environment - this may cause authentication issues"
    }

    Export-WorkerImageEnvironment
}
