function Install-AzPreReq {
    param (
        [string] $ext_src = "https://roninpuppetassets.blob.core.windows.net/binaries/prerequisites",
        [string] $local_dir = "$env:systemdrive\BootStrap",
        [string] $work_dir = "$env:systemdrive\scratch",
        [string] $manifest = "nodes.pp"
    )

    function Merge-YamlWithDefaults {
        param (
            [hashtable] $ImageData,
            [hashtable] $DefaultData
        )
        $merged = @{}
        $allKeys = $ImageData.Keys + $DefaultData.Keys | Select-Object -Unique
        foreach ($key in $allKeys) {
            $imageVal = $ImageData[$key]
            $defaultVal = $DefaultData[$key]

            if ($imageVal -is [hashtable] -and $defaultVal -is [hashtable]) {
                $merged[$key] = Merge-YamlWithDefaults -ImageData $imageVal -DefaultData $defaultVal
            }
            elseif ($imageVal -eq 'default' -or $null -eq $imageVal -or $imageVal -eq '') {
                $merged[$key] = $defaultVal
            }
            else {
                $merged[$key] = $imageVal
            }
        }
        return $merged
    }

    begin {
        Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
        Set-PSRepository PSGallery -InstallationPolicy Trusted
        Install-Module powershell-yaml -Force -ErrorAction Stop

        Write-Host "[Init] Starting Install-AzPreReq at $(Get-Date -Format o)"
    }

    process {
        $configFile = "C:\Config\$($env:Config).yaml"
        $defaultsFile = "C:\Config\windows_production_defualts.yaml"

        if (-Not (Test-Path $configFile)) {
            Write-Host "❌ Could not find config file: $configFile"
            exit 1
        }

        if (-Not (Test-Path $defaultsFile)) {
            Write-Host "❌ Could not find defaults file: $defaultsFile"
            exit 1
        }

        $configYaml   = ConvertFrom-Yaml (Get-Content $configFile -Raw)
        $defaultsYaml = ConvertFrom-Yaml (Get-Content $defaultsFile -Raw)
        $data = Merge-YamlWithDefaults -ImageData $configYaml -DefaultData $defaultsYaml

        # Puppet version
        $puppet_version = $data.vm.puppet_version
        $puppet = "puppet-agent-$puppet_version-x64.msi"

        # Git version
        $git_version = $data.vm.git_version
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
        Write-Host "📥 Downloading azcopy to $env:SystemDrive"
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
            Write-Host "❌ Git not installed"
            exit 1
        }

        # Install Puppet
        Start-Process msiexec -ArgumentList @("/qn", "/norestart", "/i", "$env:SystemDrive\$puppet") -Wait
        if (-Not (Test-Path "C:\Program Files\Puppet Labs\Puppet\bin")) {
            Write-Host "❌ Puppet not installed"
            exit 1
        }

        $env:PATH += ";C:\Program Files\Puppet Labs\Puppet\bin"
    }

    end {
        Write-Host "[Complete] Install-AzPreReq finished at $(Get-Date -Format o)"
    }
}