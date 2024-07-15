function Set-ReleaseNotes {
    [CmdletBinding()]
    param (
        [String]
        $Config
    )

    ## The config will be the name of the configuration file (win11-64-2009) without the extension
    ## We'll use this to generate release notes for each OS

    ## Let's install markdownPS just in case it isn't installed
    Set-MarkdownPSModule

    ## Let's get specific information about the OS
    $OSBuild = Get-OSVersionMarkDown

    ## Let's get all of the information about the OS
    $OSVersionExtended = Get-OSVersionExtended 

    ## Just return the OS version for manipulating the markdown header
    $OSVersion = Get-OSVersion

    ## Let's get the installed software installed on the OS
    $InstalledSoftware = Get-InstalledSoftwareMarkDown

    ## Let's get speciifc information about the Mozilla Build environment
    $mozillabuild = Get-WinFactsMozillaBuild

    ## Let's also get the python packages inside the Mozilla Build environment
    $pythonPackages = Get-MozillaBuildPythonPackages

    ## Now let's list out all software that isn't published by Microsoft
    $InstalledSoftware_NotMicrosoft = $InstalledSoftware | Where-Object {
        $PSItem.Publisher -notmatch "Microsoft"
    } | ForEach-Object {
        [PSCustomObject]@{
            Name    = $PSItem.DisplayName
            Version = $PSItem.DisplayVersion
        }
    } | Sort-Object -Property Name

    ## And now all software that is published by Microsoft
    $InstalledSoftware_Microsoft = $InstalledSoftware | Where-Object {
        $PSItem.Publisher -match "Microsoft"
    } | ForEach-Object {
        [PSCustomObject]@{
            Name    = $PSItem.DisplayName
            Version = $PSItem.DisplayVersion
        }
    } | Sort-Object -Property Name

    ## Let's create the markdown file
    $markdown = ""

    ## Start with the OS Information
    switch -Wildcard ($OSVersion) {
        "*win_10_*" {
            $Header = "Windows 10"
        }
        "*win_11_*" {
            $Header = "Windows 11"
        }
        "*win_2022_*" {
            $Header = "Windows 2022"
        }
        default {
            $null
        }
    }

    $markdown += New-MDHeader -Text $Header -Level 1
    $lines = @(
        "Config: $($Config)",
        "OS Name: $($Header) $($OSVersionExtended.DisplayVersion)",
        "OS Version: $($OSBuild)"
    )
    
    $markdown += New-MDList -Lines $lines -Style Unordered
    
    $markdown += New-MDHeader "Mozilla Build" -Level 2
    
    $lines2 = @(
        "Find more information about Mozilla Build on [Wiki](https://wiki.mozilla.org/MozillaBuild#Technical_Details)"
    )
    $markdown += New-MDAlert -Lines $lines2 -Style Important
    
    $lines3 = @(
        "Mozilla Build: $($mozillabuild.custom_win_mozbld_version)"
    )
    
    $markdown += New-MDList -Lines $lines3 -Style Unordered
    
    $markdown += New-MDHeader "Python Packages" -Level 3
    $markdown += "`n"
    $markdown += $pythonPackages | New-MDTable
    $markdown += "`n"
    
    $markdown += New-MDHeader "Installed Software (Not Microsoft)" -Level 2
    $markdown += "`n"
    $markdown += $InstalledSoftware_NotMicrosoft | New-MDTable
    
    $markdown += New-MDHeader "Installed Software (Microsoft)" -Level 2
    $markdown += "`n"
    $markdown += $InstalledSoftware_Microsoft | New-MDTable
    
    $markdown | Out-File "C:\software_report.md"

    ## Now copy the software markdown file elsewhere to prep for uploading to azure
    Copy-Item -Path "C:\software_report.md" -Destination "C:\$($Config).md"

    ## Upload it to Azure
    $ENV:AZCOPY_AUTO_LOGIN_TYPE = "SPN"
    $ENV:AZCOPY_SPA_APPLICATION_ID = $ENV:application_id
    $ENV:AZCOPY_SPA_CLIENT_SECRET = $ENV:client_secret
    $ENV:AZCOPY_TENANT_ID = $ENV:tenant_id
    
    Start-Process -FilePath "$ENV:systemdrive\azcopy.exe" -ArgumentList @(
        "copy",
        "C:\$($Config).md",
        "https://roninpuppetassets.blob.core.windows.net/packer"
    ) -Wait -NoNewWindow
}