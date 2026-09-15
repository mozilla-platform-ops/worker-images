function Install-AzPreReq {
    param (
        [string] $ext_src = "https://roninpuppetassets.blob.core.windows.net/binaries/prerequisites",
        [string] $local_dir = "$env:systemdrive\BootStrap",
        [string] $manifest = "nodes.pp"
    )

    begin {

        Get-PackageProvider -Name Nuget -ForceBootstrap | Out-Null
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    process {
        # Versions have already been resolved and validated on the runner.
        $openvox_version = $env:openvox_version
        $git_version = $env:git_version
        if (-not $openvox_version -or -not $git_version) {
            throw 'The runner must supply openvox_version and git_version.'
        }
        $puppet = "openvox-agent-$openvox_version-x64.msi"

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

}
