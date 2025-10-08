function New-GCPWorkerImage {
    [CmdletBinding()]
    param (
        [String] $Github_token,
        [String] $Key,
        [String] $Access_Token,
        [String] $Account_File,
        [String] $Worker_Env_Var_Key,
        [String] $TC_worker_cert,
        [String] $TC_worker_key,
        [String] $Team
    )
    
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop

    if ($Team -and $Team -ieq "tceng") {
        $YamlPath      = "config/tceng/$Key.yaml"
        $PackerHCLPath = "packer/tceng-gcp.pkr.hcl"
        $ENV:PKR_VAR_Team_key = $Team

        # Generate uuid (same as Azure tceng logic)
        $uuidBytes = [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String(
                [System.Convert]::ToBase64String(
                    (1..256 | ForEach-Object { Get-Random -Minimum 97 -Maximum 122 } | ForEach-Object { [byte]$_ })
                )
            )
        )
        $uuid = ($uuidBytes -replace '[^a-z0-9]', '')[0..19] -join ''
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

    ## Taskcluster Secrets
    $ENV:PKR_VAR_worker_env_var_key = $Worker_Env_Var_Key
    $ENV:PKR_VAR_tc_worker_cert     = $TC_worker_cert
    $ENV:PKR_VAR_tc_worker_key      = $TC_worker_key

    ## Image naming
    if ($Team -and $Team -ieq "tceng") {
        if (-not $ENV:PKR_VAR_uuid) {
            throw "UUID not set — required for tceng image naming"
        }
        $sanitizedUuid = $ENV:PKR_VAR_uuid -replace '[^a-z0-9]', ''
        $imageName = "imageset-$sanitizedUuid"
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

    if ($Github_token) {
        $ENV:PACKER_GITHUB_API_TOKEN = $Github_token
    }

    ## Initialize and build
    Write-Host "packer init $PackerHCLPath"
    packer init $PackerHCLPath

    if ($Team -and $Team -ieq "tceng") {
        # tceng uses single generic build; no --only flag
        Write-Host "packer build -force $PackerHCLPath"
        packer build -force $PackerHCLPath
    } else {
        $builder = "googlecompute.$Key"
        Write-Host "packer build --only $builder -force $PackerHCLPath"
        packer build --only $builder -force $PackerHCLPath
    }
}