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

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Log -message ('{0} :: begin - {1:o}' -f $($MyInvocation.MyCommand.Name), (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) started at $((Get-Date).ToUniversalTime().ToString('o')) =========="
    trap {
        $stopwatch.Stop()
        $elapsedMinutes = [int][math]::Floor($stopwatch.Elapsed.TotalMinutes)
        $elapsedSeconds = $stopwatch.Elapsed.Seconds
        Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $elapsedMinutes, $elapsedSeconds) -severity 'DEBUG'
        Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $elapsedMinutes minutes, $elapsedSeconds seconds =========="
        throw $_
    }
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
    } | Sort-Object -Property Name | Sort-Object Name, Version | Group-Object Name, Version | ForEach-Object { $_.Group[0] }

    ## And now all software that is published by Microsoft
    $InstalledSoftware_Microsoft = $InstalledSoftware | Where-Object {
        $PSItem.Publisher -match "Microsoft"
    } | ForEach-Object {
        [PSCustomObject]@{
            Name    = $PSItem.DisplayName
            Version = $PSItem.DisplayVersion
        }
    } | Sort-Object -Property Name | Sort-Object Name, Version | Group-Object Name, Version | ForEach-Object { $_.Group[0] }

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

    Write-Log -message ('{0} :: Copying software_report.md to {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), "(C:\$($Config).md)", (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Copy-Item -Path "C:\software_report.md" -Destination "C:\$($Config).md"

    $stopwatch.Stop()
    $elapsedMinutes = [int][math]::Floor($stopwatch.Elapsed.TotalMinutes)
    $elapsedSeconds = $stopwatch.Elapsed.Seconds
    Write-Log -message ('{0} :: completed in {1} minutes, {2} seconds' -f $($MyInvocation.MyCommand.Name), $elapsedMinutes, $elapsedSeconds) -severity 'DEBUG'
    Write-Host "========== $($MyInvocation.MyCommand.Name) completed in $elapsedMinutes minutes, $elapsedSeconds seconds =========="
}
