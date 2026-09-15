function New-GCPWorkerImage {
    [CmdletBinding()]
    param (
        [String] $Github_token,
        [ValidatePattern('^[a-zA-Z0-9_-]+$')]
        [String] $Key,
        [String] $Team
    )

    $ErrorActionPreference = 'Stop'
    Import-WorkerImagesYaml

    if ($Team -and $Team -ieq "tceng") {
        $YamlPath      = "config/tceng/$Key.yaml"
        $PackerHCLPath = "packer/tceng-gcp.pkr.hcl"
        $ENV:PKR_VAR_Team_key = $Team

        $uuid = ([guid]::NewGuid().ToString('N')).Substring(0, 20)
        $ENV:PKR_VAR_uuid = $uuid
    } else {
        $YamlPath      = "config/$Key.yaml"
        $PackerHCLPath = "gcp.pkr.hcl"
        if ($Team) { $ENV:PKR_VAR_Team_key = $Team }
    }

    if (-not (Test-Path $YamlPath)) {
        throw "YAML file not found at: $YamlPath"
    }

    $YAML = ConvertFrom-Yaml (Get-Content $YamlPath -Raw)
    $ENV:PKR_VAR_config = $Key

    ## Image naming
    if ($Team -and $Team -ieq "tceng") {
        if (-not $ENV:PKR_VAR_uuid) {
            throw "UUID not set — required for tceng image naming"
        }
        $sanitizedUuid = $ENV:PKR_VAR_uuid -replace '[^a-z0-9]', ''
        $imageName = @($YAML.image["image_name"],$sanitizedUuid) -join "-"
        Write-Host "tceng image name: $imageName"
        $ENV:PKR_VAR_image_name = $imageName
    } elseif ($Key -notmatch "alpha") {
        $suffix     = Get-Date -Format "yyyy-MM-dd"
        $imageName  = -join ($YAML.image["image_name"], "-", $suffix)
        Write-Host "image name: $imageName"
        $ENV:PKR_VAR_image_name = $imageName
    } else {
        $imageName = $YAML.image["image_name"]
        Write-Host "image name: $imageName"
        $ENV:PKR_VAR_image_name = $imageName
    }

    ## Other configuration
    if ($YAML.vm["disk_size"])             { $ENV:PKR_VAR_disk_size            = $YAML.vm["disk_size"] }
    if ($YAML.image["project_id"])         { $ENV:PKR_VAR_project_id           = $YAML.image["project_id"] }
    if ($YAML.vm["taskcluster_version"])   { $ENV:PKR_VAR_taskcluster_version  = $YAML.vm["taskcluster_version"] }
    if ($YAML.vm["taskcluster_ref"])       { $ENV:PKR_VAR_taskcluster_ref      = $YAML.vm["taskcluster_ref"] }
    if ($YAML.vm["tc_arch"])               { $ENV:PKR_VAR_tc_arch              = $YAML.vm["tc_arch"] }
    if ($YAML.image["source_image_family"]){ $ENV:PKR_VAR_source_image_family  = $YAML.image["source_image_family"] }
    if ($YAML.image["zone"])               { $ENV:PKR_VAR_zone                 = $YAML.image["zone"] }
    if ($YAML.vm["script_name"])           { $ENV:PKR_VAR_bootstrap_script     = $YAML.vm["script_name"] }

    $ENV:PACKER_GITHUB_API_TOKEN = $Github_token

    if ($YAML.vm["machine_type"]) {
        # use the YAML-defined type
        $ENV:PKR_VAR_machine_type = $YAML.vm["machine_type"]
        Write-Host "Using machine type from YAML: $($YAML.vm['machine_type'])"
    }
    else {
        $ENV:PKR_VAR_machine_type = $null
        Write-Host "No machine_type specified in YAML; using default from builder"
    }

    ## Initialize and build
    Write-Host "packer init $PackerHCLPath"
    packer init $PackerHCLPath
    if ($LASTEXITCODE -ne 0) { throw "packer init failed: $LASTEXITCODE" }
    if ($key -match "Trusted") {
        $ENV:PKR_VAR_use_keyvault = "true"
    }
    else {
        $ENV:PKR_VAR_use_keyvault = "false"
    }
    if ($Team -and $Team -ieq "tceng") {
        # tceng uses single generic build; no --only flag
        Write-Host "packer build -force $PackerHCLPath"
        packer build -force $PackerHCLPath
    } else {
        $builder = "googlecompute.$Key"
        Write-Host "packer build --only $builder -force $PackerHCLPath"
        packer build --only $builder -force $PackerHCLPath
    }
    if ($LASTEXITCODE -ne 0) { throw "packer build failed: $LASTEXITCODE" }
}
