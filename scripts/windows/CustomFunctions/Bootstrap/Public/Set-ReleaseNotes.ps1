function Set-ReleaseNotes {
    [CmdletBinding()]
    param (
        [String]
        $Config,

        [String]
        $Version
    )

    ## The config will be the name of the configuration file (win11-64-2009) without the extension
    ## We'll use this to generate release notes for each OS

    Write-Log -message ('{0} :: Processing {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $Config, (Get-Date).ToUniversalTime()) -severity 'DEBUG'

    ## Let's install markdownPS just in case it isn't installed
    Set-MarkdownPSModule

    ## Let's get specific information about the OS
    $OSBuild = Get-OSVersionMarkDown
    if ($null -eq $OSBuild) {
        $reason = "Unable to find OSBuild"
        Write-Log -message ('{0} :: {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $reason, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }

    ## Let's get all of the information about the OS
    $OSVersionExtended = Get-OSVersionExtended 
    if ($null -eq $OSVersionExtended) {
        $reason = "Unable to find OSVersionExtended"
        Write-Log -message ('{0} :: {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $reason, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }

    ## Just return the OS version for manipulating the markdown header
    $OSVersion = Get-OSVersion
    if ($null -eq $OSVersion) {
        $reason = "Unable to find OSVersion"
        Write-Log -message ('{0} :: {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $reason, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }

    ## Let's get the installed software installed on the OS
    $InstalledSoftware = Get-InstalledSoftware | Where-Object {
        ($psitem.DisplayName -match "\D") -and ($null -ne $psitem.DisplayVersion)
    }
    if ($null -eq $InstalledSoftware) {
        $reason = "Unable to find Installed Software"
        Write-Log -message ('{0} :: {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $reason, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }

    ## Let's get speciifc information about the Mozilla Build environment
    $mozillabuild = Get-WinFactsMozillaBuild
    if ($null -eq $mozillabuild) {
        $reason = "Unable to find facts for win mozilla build"
        Write-Log -message ('{0} :: {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $reason, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }

    ## Let's also get the python packages inside the Mozilla Build environment
    $pythonPackages = Get-MozillaBuildPythonPackages -RequirementsFile "C:\requirements.txt"
    if ($null -eq $pythonPackages) {
        $reason = "Unable to find python packges in c:\requirements.txt"
        Write-Log -message ('{0} :: {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $reason, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }

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

    if ($null -eq $OSVersion) {
        $reason = "Unable to determine OSVersion"
        Write-Log -message ('{0} :: {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $reason, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }

    $markdown += New-MDHeader -Text $Header -Level 1
    $markdown += "`n"
    $lines = @(
        "Config: $($Config)",
        "OS Name: $($Header) $($OSVersionExtended.DisplayVersion)",
        "OS Version: $($OSBuild)"
    )
    
    $markdown += New-MDList -Lines $lines -Style Unordered
    
    $markdown += New-MDHeader "Mozilla Build" -Level 2
    $markdown += "`n"
    $lines2 = @(
        "Find more information about Mozilla Build on [Wiki](https://wiki.mozilla.org/MozillaBuild#Technical_Details)"
    )
    $markdown += New-MDAlert -Lines $lines2 -Style Important
    
    $lines3 = @(
        "Mozilla Build: $($mozillabuild.custom_win_mozbld_version)"
    )
    
    $markdown += New-MDList -Lines $lines3 -Style Unordered
    
    $markdown += New-MDHeader "Taskcluster Packages Installed" -Level 3
    $markdown += "`n"
    $markdown += Show-TaskclusterBinaries | New-MDTable
    $markdown += "`n"

    $markdown += New-MDHeader "Python Packages" -Level 3
    $markdown += "`n"
    $markdown += $pythonPackages | New-MDTable
    $markdown += "`n"
    
    $markdown += New-MDHeader "Installed Software (Not Microsoft)" -Level 2
    $markdown += "`n"
    $markdown += $InstalledSoftware_NotMicrosoft | New-MDTable
    $markdown += "`n"

    $markdown += New-MDHeader "Installed Software (Microsoft)" -Level 2
    $markdown += "`n"
    $markdown += $InstalledSoftware_Microsoft | New-MDTable
    
    $markdown | Out-File "C:\software_report.md"

    $markdown_content = Get-Content -Path "C:\software_report.md"
    if ($null -eq $markdown_content) {
        $reason = "Unable to find software_report.md"
        Write-Log -message ('{0} :: {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $reason, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }

    ## output the contents of the markdown file
    Get-Content -Path "C:\software_report.md"

    if (-Not (Test-Path "C:\software_report.md")) {
        $reason = "Unable to find software_report.md after copy-item"
        Write-Log -message ('{0} :: {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $reason, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }

    if ([String]::IsNullOrEmpty($Version)) {
        ## Now copy the software markdown file elsewhere to prep for uploading to azure
        Copy-Item -Path "C:\software_report.md" -Destination "C:\$($Config).md"
    }
    else {
        ## Now copy the software markdown file elsewhere to prep for uploading to azure
        Copy-Item -Path "C:\software_report.md" -Destination "C:\$($Config)-$($version).md"
    }

}