function Set-ReleaseNotes {
    [CmdletBinding()]
    param (
        [String]
        $Config,

        [String]
        $Version,

        [String]
        $Branch,

        [String]
        $Organization,

        [String]
        $Repository,

        [String]
        $DeploymentId
    )

    ## The config will be the name of the configuration file (win11-64-2009) without the extension
    ## We'll use this to generate release notes for each OS

    Write-Log -message ('{0} :: Processing {1} {2} - {3:o}' -f $($MyInvocation.MyCommand.Name), $Config, $Version, (Get-Date).ToUniversalTime()) -severity 'DEBUG'

    function ConvertTo-MarkdownTable {
        param([object[]] $Rows)

        $Rows = @($Rows)
        if ($Rows.Count -eq 0) {
            return ""
        }

        $Properties = @($Rows[0].PSObject.Properties.Name)
        $Header = "| " + ($Properties -join " | ") + " |"
        $Separator = "| " + (($Properties | ForEach-Object { "---" }) -join " | ") + " |"
        $Body = $Rows | ForEach-Object {
            $Row = $_
            "| " + (($Properties | ForEach-Object { [string]$Row.$_ }) -join " | ") + " |"
        }

        return (@($Header, $Separator) + $Body) -join "`n"
    }

    ## Let's get specific information about the OS
    $OSBuild = Get-OSVersionMarkDown

    ## Let's get all of the information about the OS
    $OSVersionExtended = Get-OSVersionExtended

    ## Just return the OS version for manipulating the markdown header
    $OSVersion = Get-OSVersion

    ## Let's get the installed software installed on the OS
    $InstalledSoftware = Get-InstalledSoftware | Where-Object {
        ($psitem.DisplayName -match "\D") -and ($null -ne $psitem.DisplayVersion)
    }

    ## Let's get speciifc information about the Mozilla Build environment
    $mozillabuild = Get-WinFactsMozillaBuild

    ## Let's also get the python packages inside the Mozilla Build environment
    $pythonPackages = Get-MozillaBuildPythonPackages -RequirementsFile "C:\requirements.txt"

    ## Now let's list out all software that isn't published by Microsoft
    $InstalledSoftware_NotMicrosoft = $InstalledSoftware | Where-Object {
        $PSItem.Publisher -notmatch "Microsoft"
    } | ForEach-Object {
        [PSCustomObject]@{
            Name    = $PSItem.DisplayName
            Version = $PSItem.DisplayVersion
        }
    } | Sort-Object Name, Version -Unique

    ## And now all software that is published by Microsoft
    $InstalledSoftware_Microsoft = $InstalledSoftware | Where-Object {
        $PSItem.Publisher -match "Microsoft"
    } | ForEach-Object {
        [PSCustomObject]@{
            Name    = $PSItem.DisplayName
            Version = $PSItem.DisplayVersion
        }
    } | Sort-Object Name, Version -Unique

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
        "*win_2025_*" {
            $Header = "Windows Server 2025"
        }
        default {
            throw "Unrecognized OS version: $OSVersion"
        }
    }


    $markdown += "# $Header`n`n"
    $lines = @(
        "Config: $($Config)",
        "OS Name: $($Header) $($OSVersionExtended.DisplayVersion)",
        "OS Version: $($OSBuild)",
        "Organization: $($Organization)",
        "Repository: $($Repository)"
        "Branch: $($Branch)",
        "DeploymentId: $($DeploymentId)"
    )

    $markdown += (($lines | ForEach-Object { "- $_" }) -join "`n")
    $markdown += "`n`n"

    $markdown += "## Mozilla Build`n`n"
    $lines2 = @(
        "Find more information about Mozilla Build on [Wiki](https://wiki.mozilla.org/MozillaBuild#Technical_Details)"
    )
    $markdown += "> [!IMPORTANT]`n"
    $markdown += (($lines2 | ForEach-Object { "> $_" }) -join "`n")
    $markdown += "`n`n"

    $lines3 = @(
        "Mozilla Build: $($mozillabuild.custom_win_mozbld_version)"
    )

    $markdown += (($lines3 | ForEach-Object { "- $_" }) -join "`n")
    $markdown += "`n`n"

    $markdown += "### Taskcluster Packages Installed`n`n"
    $markdown += ConvertTo-MarkdownTable -Rows @(Show-TaskclusterBinaries)
    $markdown += "`n`n"

    $markdown += "### Python Packages`n`n"
    $markdown += ConvertTo-MarkdownTable -Rows @($pythonPackages)
    $markdown += "`n`n"

    $markdown += "## Installed Software (Not Microsoft)`n`n"
    $markdown += ConvertTo-MarkdownTable -Rows @($InstalledSoftware_NotMicrosoft)
    $markdown += "`n`n"

    $markdown += "## Installed Software (Microsoft)`n`n"
    $markdown += ConvertTo-MarkdownTable -Rows @($InstalledSoftware_Microsoft)

    $destination = if ($Version) { "C:\$Config-$Version.md" } else { "C:\$Config.md" }
    [System.IO.File]::WriteAllText($destination, $markdown, (New-Object System.Text.UTF8Encoding $false))
    Write-Output $markdown

}
