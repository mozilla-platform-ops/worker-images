function Install-AzPreReq {
    param (
        [string] $ext_src = "https://roninpuppetassets.blob.core.windows.net/binaries/prerequisites",
        [string] $local_dir = "$env:systemdrive\BootStrap",
        [string] $work_dir = "$env:systemdrive\scratch",
        [string] $manifest = "nodes.pp"
    )

    begin {
        Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Install-Module powershell-yaml -ErrorAction Stop

        Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
    }

    process {
        $configPath   = "C:\Config\$($env:Config).yaml"
        $defaultsPath = "C:\Config\windows_production_defaults.yaml"

        if (-Not (Test-Path $configPath)) {
            Write-Host "Could not find config file: $configPath"
            exit 1
        }

        if (-Not (Test-Path $defaultsPath)) {
            Write-Host "Could not find default config: $defaultsPath"
            exit 1
        }

        $data    = ConvertFrom-Yaml (Get-Content -Path $configPath -Raw)
        $defaults = ConvertFrom-Yaml (Get-Content -Path $defaultsPath -Raw)

        ## Puppet version
        $puppet_version = $data.vm.puppet_version
        if (-not $puppet_version -or $puppet_version -eq "default") {
            $puppet_version = $defaults.vm.puppet_version
        }
        $puppet = "puppet-agent-$puppet_version-x64.msi"

        ## Git Version
        $git_version = $data.vm.git_version
        if (-not $git_version -or $git_version -eq "default") {
            $git_version = $defaults.vm.git_version
        }

        switch ($env:PROCESSOR_ARCHITECTURE) {
            "AMD64" {
                $git = "Git-$git_version-64-bit.exe"
            }
            "ARM64" {
                $git = "Git-$git_version-arm64.exe"
            }
            Default {
                $git = "Git-$git_version-64-bit.exe"
            }
        }
        $git_url = "https://github.com/git-for-windows/git/releases/download/v$git_version.windows.1/$git"

        Write-Log -message ('Puppet version: {0} :: - {1:o}' -f $puppet, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('Puppet version: {0} :: - {1:o}' -f $puppet, (Get-Date).ToUniversalTime())

        ## Create bootstrap directory
        $null = New-Item -Path $local_dir -ItemType Directory -Force

        ## Setup azcopy
        Write-host "Downloading azcopy to $ENV:systemdrive\"
        Invoke-DownloadWithRetry -Url "https://aka.ms/downloadazcopy-v10-windows" -Path "$env:systemdrive\azcopy.zip"
        if (-Not (Test-Path "$ENV:systemdrive\azcopy.zip")) {
            Write-Host "Failed to download azcopy"
            Write-Log -message ('{0} :: Failed to download azcopy' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
            exit 1
        }
        Write-host "Downloaded azcopy to $ENV:systemdrive\azcopy.zip"
        Expand-Archive -Path "$env:systemdrive\azcopy.zip" -DestinationPath "$env:systemdrive\azcopy"
        $azcopy_path = Get-ChildItem "$env:systemdrive\azcopy" -Recurse | Where-Object { $_.Name -eq "azcopy.exe" }
        Copy-Item $azcopy_path.FullName -Destination "$env:systemdrive\"
        Remove-Item "$env:systemdrive\azcopy.zip"

        ## Download puppet, git, and manifest
        Invoke-DownloadWithRetry -Url "$ext_src/$puppet" -Path "$env:systemdrive\$puppet"
        Invoke-DownloadWithRetry -Url $git_url -Path "$env:systemdrive\$git"

        $manifest_contents = @"
node default {
    include roles_profiles::roles::role
}
"@
        $manifest_contents | Out-File "$local_dir\$manifest" -Force
        if (-Not (Test-Path "$local_dir\$manifest")) {
            Write-Host "Failed to create manifest for puppet"
        }

        ## Install git
        Start-Process "$env:systemdrive\$git" /verysilent -wait
        if (-Not (Test-Path "C:\Program Files\Git\bin")) {
            Write-Host "Git not installed"
            Write-Log -message  ('{0} :: Git not installed' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
            exit 1
        }
        Write-Log -message  ('{0} :: Git installed :: {1}' -f $($MyInvocation.MyCommand.Name), $git) -severity 'DEBUG'
        Write-Host ('{0} :: Git installed :: {1}' -f $($MyInvocation.MyCommand.Name), $git)

        ## Install Puppet
        Start-Process msiexec -ArgumentList @("/qn", "/norestart", "/i", "$env:systemdrive\$puppet") -Wait
        if (-Not (Test-Path "C:\Program Files\Puppet Labs\Puppet\bin")) {
            Write-Host "Did not install puppet"
            exit 1
        }
        Write-Log -message  ('{0} :: Puppet installed :: {1}' -f $($MyInvocation.MyCommand.Name), $puppet) -severity 'DEBUG'
        Write-Host ('{0} :: Puppet installed :: {1}' -f $($MyInvocation.MyCommand.Name), $puppet)
        $env:PATH += ";C:\Program Files\Puppet Labs\Puppet\bin"
    }

    end {
        Write-Log -message ('{0} :: end - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('{0} :: end - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
    }
}