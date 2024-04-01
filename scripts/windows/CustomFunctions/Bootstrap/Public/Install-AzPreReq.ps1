function Install-AzPreReq {
    param (
        [string] $ext_src = "https://roninpuppetassets.blob.core.windows.net/binaries/prerequisites",
        [string] $local_dir = "$env:systemdrive\BootStrap",
        [string] $work_dir = "$env:systemdrive\scratch",
        [string] $git = "Git-2.37.3-64-bit.exe",
        [string] $manifest = "nodes.pp"
    )
    begin {
        Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
        Set-PSRepository PSGallery -InstallationPolicy Trusted
        Install-Module powershell-yaml -ErrorAction Stop
    }
    process { 
        ## Setup azcopy
        Write-host "Downloading azcopy to $ENV:systemdrive\"
        Invoke-DownloadWithRetry -Url "https://aka.ms/downloadazcopy-v10-windows" -Path "$env:systemdrive\azcopy.zip"
        Write-host "Downloaded azcopy to $ENV:systemdrive\azcopy.zip"
        Expand-Archive -Path "$ENV:systemdrive\azcopy.zip" -DestinationPath "$ENV:systemdrive\azcopy"
        $azcopy_path = Get-ChildItem "$ENV:systemdrive\azcopy" -Recurse | Where-Object { $PSItem.name -eq "azcopy.exe" }
        Copy-Item $azcopy_path.FullName -Destination "$ENV:systemdrive\"
        Remove-Item "$ENV:systemdrive\azcopy.zip"
        
        ## Add support for switching between puppet versions for testing
        ## Pull in the configuration file of the worker pool
        $data = Convertfrom-Yaml (Get-Content -Path "C:\Config\$($ENV:Config).yaml" -Raw)

        if ([string]::IsNullOrEmpty($data)) {
            Write-Log -message ('{0} :: - {2:o}' -f "Could not find Config at C:\Config\$($ENV:Config).yaml", (Get-Date).ToUniversalTime()) -severity 'DEBUG'
            Write-Host ('{0} :: - {1:o}' -f "Could not find Config at C:\Config\$($ENV:Config).yaml", , (Get-Date).ToUniversalTime())
            exit 1
        }

        if ([string]::IsNullOrEmpty($data.vm.puppet_version)) {
            $puppet = "puppet-agent-6.28.0-x64.msi"
        }
        else {
            $puppet = ("puppet-agent-{0}-x64.msi") -f $data.vm.puppet_version
        }

        Write-Log -message ('Puppet version: {0} :: - {1:o}' -f $puppet, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('Puppet version: {0} :: - {1:o}' -f $puppet, (Get-Date).ToUniversalTime())

        ## Download puppet, git, and nodes.pp
        Invoke-DownloadWithRetry -Url "$ext_src/$puppet" -Path "$env:systemdrive\$puppet"
        Invoke-DownloadWithRetry -Url "$ext_src/$git" -Path "$env:systemdrive\$git"
        Invoke-DownloadWithRetry -Url "$ext_src/$manifest" -Path "$local_dir\$manifest"

        ## Install git
        Start-Process "$env:systemdrive\$git" /verysilent -wait
        Write-Log -message  ('{0} :: Git installed " {1}' -f $($MyInvocation.MyCommand.Name), $git) -severity 'DEBUG'
        Write-Host ('{0} :: Git installed :: {1}' -f $($MyInvocation.MyCommand.Name), $git)
        
        ## Install Puppet
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