function Install-AzPreReq {
    param (
        [string] $ext_src = "https://roninpuppetassets.blob.core.windows.net/binaries/prerequisites",
        [string] $local_dir = "$env:systemdrive\BootStrap",
        [string] $work_dir = "$env:systemdrive\scratch",
        [string] $git = "Git-2.37.3-64-bit.exe",
        [string] $vault_file = "azure_vault_template.yaml",
        [string] $rdagent = "rdagent",
        [string] $azure_guest_agent = "WindowsAzureGuestAgent",
        [string] $azure_telemetry = "WindowsAzureTelemetryService",
        [string] $ps_ver_maj = $PSVersionTable.PSVersion.Major,
        [string] $ps_ver_min = $PSVersionTable.PSVersion.Minor,
        [string] $ps_ver = ('{0}.{1}' -f $ps_ver_maj, $ps_ver_min),
        [string] $wmf_5_1 = "Win8.1AndW2K12R2-KB3191564-x64.msu",
        [string] $bootzip = "BootStrap_Azure_07-2022.zip",
        [string] $manifest = "nodes.pp"
    )
    begin {
        Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
        Set-PSRepository PSGallery -InstallationPolicy Trusted
        Install-Module powershell-yaml -ErrorAction Stop
    }
    process {
        ## Setup azcopy
        Write-host "Downloading azcopy to $ENV:systemdrive\"
        Invoke-WebRequest "https://aka.ms/downloadazcopy-v10-windows" -OutFile "$env:systemdrive\azcopy.zip"
        Write-host "Downloaded azcopy to $ENV:systemdrive\azcopy.zip"
        Expand-Archive -Path "$ENV:systemdrive\azcopy.zip" -DestinationPath "$ENV:systemdrive\azcopy"
        $azcopy_path = Get-ChildItem "$ENV:systemdrive\azcopy" -Recurse | Where-Object {$PSItem.name -eq "azcopy.exe"}
        Copy-Item $azcopy_path.FullName -Destination "$ENV:systemdrive\"
        Remove-Item "$ENV:systemdrive\azcopy.zip"

        ## Add support for switching between puppet versions for testing

        ## Pull in the configuration file of the worker pool
        $Config = Convertfrom-Yaml (Get-Content -Path "C:\Config\$Config.yaml" -Raw)

        if ([string]::IsNullOrEmpty($config.vm.puppet_version)) {
            $puppet = "puppet-agent-6.28.0-x64.msi"
        }
        else {
            $puppet = ("puppet-agent-{0}-x64.msi") -f $config.vm.puppet_version
        }

        ## Set azcopy vars
        $ENV:AZCOPY_AUTO_LOGIN_TYPE = "SPN"
        $ENV:AZCOPY_SPA_APPLICATION_ID = $ENV:application_id
        $ENV:AZCOPY_SPA_CLIENT_SECRET = $ENV:client_secret
        $ENV:AZCOPY_TENANT_ID = $ENV:tenant_id

        ## Authenticate
        Start-Process -FilePath "$ENV:systemdrive\azcopy.exe" -ArgumentList @(
            "login",
            "--service-principal",
            "--application-id $ENV:AZCOPY_SPA_APPLICATION_ID",
            "--tenant-id=$ENV:tenant_id"
        ) -Wait -NoNewWindow

        Start-Process -FilePath "$ENV:systemdrive\azcopy.exe" -ArgumentList @(
            "copy",
            "$ext_src/$puppet",
            "$env:systemdrive\$puppet"
        ) -Wait -NoNewWindow

        Start-Process -FilePath "$ENV:systemdrive\azcopy.exe" -ArgumentList @(
            "copy",
            "$ext_src/$git",
            "$env:systemdrive\$git"
        ) -Wait -NoNewWindow

        Start-Process -FilePath "$ENV:systemdrive\azcopy.exe" -ArgumentList @(
            "copy",
            "$ext_src/$manifest ",
            "$local_dir\$manifest"
        ) -Wait -NoNewWindow

        Start-Process "$env:systemdrive\$git" /verysilent -wait
        Write-Log -message  ('{0} :: Git installed " {1}' -f $($MyInvocation.MyCommand.Name), $git) -severity 'DEBUG'
        Write-Host ('{0} :: Git installed :: {1}' -f $($MyInvocation.MyCommand.Name), $git)
        
        Start-Process msiexec -ArgumentList @("/qn", "/norestart", "/i", "$env:systemdrive\$puppet") -Wait
        Write-Log -message  ('{0} :: Puppet installed :: {1}' -f $($MyInvocation.MyCommand.Name), $puppet) -severity 'DEBUG'
        Write-Host ('{0} :: Puppet installed :: {1}' -f $($MyInvocation.MyCommand.Name), $puppet)
        if (-Not (Test-Path "C:\Program Files\Puppet Labs\Puppet\bin")) {
            Write-Host "Did not install puppet"
            exit 1
        }
        $env:PATH += ";C:\Program Files\Puppet Labs\Puppet\bin"
    }
    end {
        Write-Log -message ('{0} :: end - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('{0} :: end - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
    }
}