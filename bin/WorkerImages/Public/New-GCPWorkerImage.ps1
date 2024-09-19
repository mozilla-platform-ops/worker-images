function New-GCPWorkerImage {
    [CmdletBinding()]
    param (
        [String]
        $Key,

        [String]
        $Access_Token,

        [String]
        $Account_File,

        [String]
        $Worker_Env_Var_Key,

        [String]
        $TC_worker_cert,

        [String]
        $TC_worker_key
    )
    
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
    $ENV:PKR_VAR_config = $key
    
    ## Authentication
    #$ENV:PKR_VAR_account_file = $Account_File
    #$ENV:GOOGLE_APPLICATION_CREDENTIALS = $Credentials_File

    ## Taskcluster Secrets
    $ENV:PKR_VAR_worker_env_var_key = $Worker_Env_Var_Key
    $ENV:PKR_VAR_tc_worker_cert = $TC_worker_cert
    $ENV:PKR_VAR_tc_worker_key = $TC_worker_key

    ## Configuration
    Write-Host "image name: $($YAML.image["image_name"])"
    $ENV:PKR_VAR_image_name = $YAML.image["image_name"]

    Write-Host "disk size: $($YAML.vm["disk_size"])"
    $ENV:PKR_VAR_disk_size = $YAML.vm["disk_size"]

    Write-Host "project id: $($YAML.image["project_id"])"
    $ENV:PKR_VAR_project_id = $YAML.image["project_id"]

    Write-Host "tc version: $($YAML.vm["taskcluster_version"])"
    $ENV:PKR_VAR_taskcluster_version = $YAML.vm["taskcluster_version"]

    Write-Host "tc arch: $($YAML.vm["tc_arch"])"
    $ENV:PKR_VAR_tc_arch = $YAML.vm["tc_arch"]

    Write-Host "image family: $($YAML.image["source_image_family"])"
    $ENV:PKR_VAR_source_image_family = $YAML.image["source_image_family"]

    Write-Host "zone: $($YAML.image["zone"])"
    $ENV:PKR_VAR_zone = $YAML.image["zone"]

    ## Initialize Packer plugins
    packer init gcp.pkr.hcl

    ## Run Packer
    packer build --only googlecompute.ubuntu2204 -force gcp.pkr.hcl
}