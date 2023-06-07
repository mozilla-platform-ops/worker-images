function Install-AzPreReq {
    param (
        [string] $ext_src = "https://roninpuppetassets.blob.core.windows.net/binaries/prerequisites",
        [string] $local_dir = "$env:systemdrive\BootStrap",
        [string] $work_dir = "$env:systemdrive\scratch",
        [string] $git = "Git-2.37.3-64-bit.exe",
        [string] $puppet = "puppet-agent-6.28.0-x64.msi",
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
    }
    process {

        Invoke-WebRequest -Uri $ext_src/$puppet -UseBasicParsing -OutFile "$env:systemdrive\$puppet"
        Invoke-WebRequest -Uri $ext_src/$git -UseBasicParsing -OutFile "$env:systemdrive\$git"
        Invoke-WebRequest -Uri $ext_src/$manifest -UseBasicParsing -OutFile "$local_dir\$manifest"

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