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
        Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime())
        Set-PSRepository PSGallery -InstallationPolicy Trusted
        Install-Module powershell-yaml -ErrorAction Stop
    }
    process { 
        ## Create bootstrap
        New-Item -Path $local_dir -ItemType Directory -Force
        
        ## Setup azcopy
        Write-host "Downloading azcopy to $ENV:systemdrive\"
        Invoke-DownloadWithRetry -Url "https://aka.ms/downloadazcopy-v10-windows" -Path "$env:systemdrive\azcopy.zip"
        if (-Not (Test-Path "$ENV:systemdrive\azcopy.zip")) {
            Write-Host "Failed to download azcopy"
            Write-Log -message ('{0} :: Failed to download azcopy' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
            exit 1
        }
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

        ## Puppet version
        if ([string]::IsNullOrEmpty($data.vm.puppet_version)) {
            $puppet = "puppet-agent-6.28.0-x64.msi"
        }
        else {
            $puppet = ("puppet-agent-{0}-x64.msi") -f $data.vm.puppet_version
        }
        ## Git Version
        if ([string]::IsNullOrEmpty($data.vm.git_version)) {
            $git = "Git-2.46.0-64-bit.exe"
            $git_url = "https://github.com/git-for-windows/git/releases/download/v2.46.0.windows.1/Git-2.46.0-64-bit.exe"
        }
        else {
            $git = ("Git-{0}-64-bit.exe") -f $data.vm.git_version
            $git_url = "https://github.com/git-for-windows/git/releases/download/v{0}windows.1/Git-{1}-64-bit.exe" -f $data.vm.git_version, $data.vm.git_version
        }

        Write-Log -message ('Puppet version: {0} :: - {1:o}' -f $puppet, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        Write-Host ('Puppet version: {0} :: - {1:o}' -f $puppet, (Get-Date).ToUniversalTime())

        ## Download puppet, git, and nodes.pp
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
        Write-Log -message  ('{0} :: Git installed " {1}' -f $($MyInvocation.MyCommand.Name), $git) -severity 'DEBUG'
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