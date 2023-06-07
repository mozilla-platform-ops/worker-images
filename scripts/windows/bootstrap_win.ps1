[CmdletBinding()]
param (
    [String]
    $Worker_Pool_ID = $ENV:worker_pool_id,

    [String]
    $Base_Image = $ENV:base_image,
    
    [String]
    $src_Organisation = $ENV:src_organisation,

    [String]
    $Src_Repository = $ENV:src_Repository,
    
    [String]
    $Src_Branch = $ENV:src_Branch
)

Write-Host ("Processing {0}" -f [System.Net.Dns]::GetHostByName($env:computerName).hostname)

If (test-path 'HKLM:\SOFTWARE\Mozilla\ronin_puppet') {
    $stage = (Get-ItemProperty -path "HKLM:\SOFTWARE\Mozilla\ronin_puppet").bootstrap_stage
}
If (-Not (test-path 'HKLM:\SOFTWARE\Mozilla\ronin_puppet')) {
    Set-Logging
    Install-AzPreReq -DisableNameChecking
    $RoninRegSplat = @{
        worker_pool_id = $Worker_Pool_ID
        base_image = $Base_Image
        src_Organisation = $src_Organisation
        src_Repository = $src_Repository
        src_Branch = $Src_Branch
    }
    Set-RoninRegOptions @RoninRegSplat -image_provisioner "azure"
    exit 0
}
If (($stage -eq 'setup') -or ($stage -eq 'inprogress')) {
    Set-AzRoninRepo -DisableNameChecking
    Start-AzRoninPuppet
    exit 0
}
If ($stage -eq 'complete') {
    Write-Log -message  ('{0} ::Bootstrapping appears complete' -f $($MyInvocation.MyCommand.Name)) -severity 'DEBUG'
    <#
    $caption = ((Get-WmiObject Win32_OperatingSystem).caption)
    $caption = $caption.ToLower()
    $os_caption = $caption -replace ' ', '_'
    if ($os_caption -like "*windows_11*") {
        ## Target only windows 11 for tests at this time.
        Import-Module "$env:systemdrive\ronin\provisioners\windows\modules\Bootstrap\Bootstrap.psm1"
        Write-Output ("Processing {0}" -f $ENV:COMPUTERNAME)
        ## Remove old version of pester and install new version if not already running 5
        if ((Get-Module -Name Pester -ListAvailable).version.major -ne 5) {
            Set-PesterVersion
        }
        ## Change directory to tests
        Set-Location $env:systemdrive\ronin\test\integration\windows11
        ## Loop through each test and run it
        Get-ChildItem *.tests* | ForEach-Object {
            Invoke-RoninTest -Test $_.Fullname
        }
    }    
    #>
    exit 0
}
