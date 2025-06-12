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
        Install-Module powershell-yaml -Force -ErrorAction Stop

        Write-Host "[Init] Starting Install-AzPreReq at $(Get-Date -Format o)"
    }

    process {
        $configFile = "C:\Config\$($env:Config).yaml"

        if (-Not (Test-Path $configFile)) {
            Write-Host " Could not find config file: $configFile"
            exit 1
        }

        $data = ConvertFrom-Yaml (Get-Content $configFile -Raw)

        # Puppet version
        $puppet_version = $data.vm.puppet_version
        if (-not $puppet_version -or $puppet_version -eq 'default') {
            $puppet_version = "6.28.0"
        }
        $puppet = "puppet-agent-$puppet_version-x64.msi"

        # Git version
        $git_version = $data.vm.git_version
        if (-not $git_version -or $git_version -eq 'default') {
            $git_version = "2.46.0"
        }

        switch ($env:PROCESSOR_ARCHITECTURE) {
            "AMD64" { $git = "Git-$git_version-64-bit.exe" }
            "ARM64" { $git = "Git-$git_version-arm64.exe" }
            Default { $git = "Git-$git_version-64-bit.exe" }
        }

        $git_url = "https://github.com/git-for-windows/git/releases/download/v$git_version.windows.1/$git"

        Write-Host "[Resolved] puppet_version: $puppet_version"
        Write-Host "[Resolved] git_version: $git_version"
        Write-Host "[Resolved] Puppet installer: $puppet"
        Write-Host "[Resolved] Git installer: $git"
        Write-Host "[Resolved] Git download URL: $git_url"

        # Set up azcopy
        $null = New-Item -Path $local_dir -ItemType Directory -Force
        Write-Host " Downloading azcopy to $env:SystemDrive"
        Invoke-DownloadWithRetry -Url "https://aka.ms/downloadazcopy-v10-windows" -Path "$env:SystemDrive\azcopy.zip"
        Expand-Archive -Path "$env:SystemDrive\azcopy.zip" -DestinationPath "$env:SystemDrive\azcopy"
        Copy-Item (Get-ChildItem "$env:SystemDrive\azcopy" -Recurse | Where-Object { $_.Name -eq "azcopy.exe" }).FullName -Destination "$env:SystemDrive\"
        Remove-Item "$env:SystemDrive\azcopy.zip"

        # Download prerequisites
        Invoke-DownloadWithRetry -Url "$ext_src/$puppet" -Path "$env:SystemDrive\$puppet"
        Invoke-DownloadWithRetry -Url $git_url -Path "$env:SystemDrive\$git"

        # Write manifest
        @"
node default {
    include roles_profiles::roles::role
}
"@ | Out-File "$local_dir\$manifest" -Force

        # Install Git
        Start-Process "$env:SystemDrive\$git" /verysilent -Wait
        if (-Not (Test-Path "C:\Program Files\Git\bin")) {
            Write-Host " Git not installed"
            exit 1
        }

        # Install Puppet
        Start-Process msiexec -ArgumentList @("/qn", "/norestart", "/i", "$env:SystemDrive\$puppet") -Wait
        if (-Not (Test-Path "C:\Program Files\Puppet Labs\Puppet\bin")) {
            Write-Host " Puppet not installed"
            exit 1
        }

        $env:PATH += ";C:\Program Files\Puppet Labs\Puppet\bin"
    }

    end {
        Write-Host "[Complete] Install-AzPreReq finished at $(Get-Date -Format o)"
    }
}