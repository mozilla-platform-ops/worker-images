function New-GCPWorkerImage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]  [String] $Key,
        [Parameter(Mandatory = $false)] [String] $Github_token,
        [Parameter(Mandatory = $false)] [String] $Worker_Env_Var_Key,
        [Parameter(Mandatory = $false)] [String] $TC_worker_cert,
        [Parameter(Mandatory = $false)] [String] $TC_worker_key,
        [Parameter(Mandatory = $false)] [String] $Team
    )

    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop

    switch ($Team) {
        "tceng" {
            $YamlPath      = "config/tceng/$Key.yaml"
            $PackerHCLPath = "packer/tceng-gcp.pkr.hcl"
            $ENV:PKR_VAR_Team_key = $Team
        }
        default {
            $YamlPath      = "config/$Key.yaml"
            $PackerHCLPath = "gcp.pkr.hcl"
            if ($Team) { $ENV:PKR_VAR_Team_key = $Team }
        }
    }

    if (-not (Test-Path $YamlPath)) {
        throw "YAML file not found at: $YamlPath"
    }

    $YAML = ConvertFrom-Yaml (Get-Content $YamlPath -Raw)

    $ENV:PKR_VAR_config              = $Key
    $ENV:PKR_VAR_project_id          = $YAML.image["project_id"]
    $ENV:PKR_VAR_zone                = $YAML.image["zone"]
    $ENV:PKR_VAR_source_image_family = $YAML.image["source_image_family"]
    $ENV:PKR_VAR_disk_size           = $YAML.vm["disk_size"]
    $ENV:PKR_VAR_taskcluster_version = $YAML.vm["taskcluster_version"]
    $ENV:PKR_VAR_taskcluster_ref     = $YAML.vm["taskcluster_ref"]
    $ENV:PKR_VAR_tc_arch             = $YAML.vm["tc_arch"]
    $ENV:PKR_VAR_worker_env_var_key  = $Worker_Env_Var_Key
    $ENV:PKR_VAR_tc_worker_cert      = $TC_worker_cert
    $ENV:PKR_VAR_tc_worker_key       = $TC_worker_key
    $ENV:PACKER_GITHUB_API_TOKEN     = $Github_token

    # image name handling (date suffix unless alpha)
    if ($Key -notmatch "alpha") {
        $suffix = Get-Date -Format "yyyy-MM-dd"
        $ENV:PKR_VAR_image_name = -join ($YAML.image["image_name"], "-", $suffix)
    } else {
        $ENV:PKR_VAR_image_name = $YAML.image["image_name"]
    }

    # --- team-specific bootstrap path logic ---
    if ($Team -and $Team -ieq "tceng") {
        $scriptName = $YAML.vm["script_name"]
        if (-not $scriptName) { throw "vm.script_name missing in $YamlPath" }

        # resolve repo root (works in GitHub Actions and locally)
        $repoRoot = if ($env:GITHUB_WORKSPACE -and (Test-Path $env:GITHUB_WORKSPACE)) {
            (Resolve-Path $env:GITHUB_WORKSPACE).Path
        } else {
            (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
        }

        $teamDir    = Join-Path $repoRoot "scripts\linux\$Team"
        $scriptPath = Join-Path $teamDir $scriptName
        if (-not (Test-Path $scriptPath)) {
            throw "Script not found: scripts/linux/$Team/$scriptName"
        }

        $ENV:PKR_VAR_bootstrap_script = $scriptName
    }

    packer init $PackerHCLPath

    if ($Team -and $Team -ieq "tceng") {
        # tceng images use a single generic build (no --only)
        packer build -force $PackerHCLPath
    } else {
        # preserve existing non-tceng behavior
        packer build --only googlecompute.$Key -force $PackerHCLPath
    }
}