function Set-ReleaseNotes2 {
    [CmdletBinding()]
    param (
        [String] $Config,
        [String] $Version,
        [String] $Branch,
        [String] $Organization,
        [String] $Repository,
        [String] $LastDeployID,
        [String] $DeploymentId
    )

    $repoUrl = "https://github.com/$Organization/$Repository"
    $repoPath = "C:\Ronin"

    if (!(Test-Path $repoPath)) {
        git clone -q --single-branch --branch $Branch $repoUrl $repoPath
    } else {
        git config --global --add safe.directory C:/ronin
    }

    Set-Location -Path $repoPath
    git checkout $DeploymentId

    $commitUrlBase = "https://github.com/$Organization/$Repository/commit/"
    $jiraUrlBase = "https://mozilla-hub.atlassian.net/browse/"
    $bugUrlBase = "https://bugzilla.mozilla.org/show_bug.cgi?id="

    $sinceDate = git show -s --format="%ad" $LastDeployID --date=format:"%Y-%m-%d"
    $commitLog = git log "$LastDeployID^..$DeploymentId" --pretty=format:"Commit: %H`nAuthor: %an`nDate: %ad`n`n%s`n%b`n---" --all --since="$sinceDate"

    $commitEntries = $commitLog -split "(?=Commit: )"
    $commitObjects = @()
    $currentCommit = $null

    foreach ($entry in $commitEntries) {
        $entry = $entry.Trim()
        if ($entry -eq "") { continue }

        if ($entry -match "(?i)^Commit: (?<Hash>\w{40})") {
            if ($null -ne $currentCommit -and ($Config -eq "" -or $currentCommit.Details.Roles -icontains $Config)) {
                $commitObjects += $currentCommit
            }

            $commitHash = $matches["Hash"]
            $commitUrl = "$commitUrlBase$commitHash"

            $currentCommit = [PSCustomObject]@{
                URL     = $commitUrl
                Details = @{
                    Jira    = "No Ticket"
                    JiraURL = ""
                    Bug     = ""
                    BugURL  = ""
                    Date    = ""
                    Message = ""
                    Roles   = @()
                    Type    = "Uncategorized"
                }
            }
            continue
        }

        if ($null -ne $currentCommit) {
            if ($entry -match "(?i)^Author: (?<Author>.+)") {
                $author = $matches["Author"]
            } elseif ($entry -match "(?i)^Date: (?<Date>.+)") {
                $dateParts = $matches["Date"] -split "\s+"
                $formattedDate = "$($dateParts[0]) $($dateParts[1]) $($dateParts[2]) $($dateParts[4])"
                if ($author) {
                    $formattedDate += " by $author"
                }
                $currentCommit.Details.Date = $formattedDate
            }

            # Robust Jira + MSG + Bug parsing from subject/body line
            if ($entry -match "(?im)^(?<Line>[A-Z]+:\s*Jira:[A-Za-z0-9-]+.*?MSG[:\s]+.+)$") {
                $line = $matches["Line"]
                if ($line -match "^(?i)(?<Type>[A-Z]+):\s*Jira:(?<Jira>[A-Za-z0-9-]+).*?(Bug(?<Bug>\d+))?.*?MSG[:\s]+(?<Message>.+)$") {
                    $currentCommit.Details.Type = $matches["Type"]
                    $currentCommit.Details.Jira = $matches["Jira"]
                    $currentCommit.Details.JiraURL = "$jiraUrlBase$($matches["Jira"])"
                    $currentCommit.Details.Message = "$($currentCommit.Details.Type) - $($matches["Message"])"

                    if ($matches["Bug"]) {
                        $bugNumber = $matches["Bug"]
                        $currentCommit.Details.Bug = $bugNumber
                        $currentCommit.Details.BugURL = "$bugUrlBase$bugNumber"
                    }
                }
            }

            # Match inline (BugXXXX) at the end of the message
            if ($currentCommit.Details.Message -match "(?i)\(Bug(?<Bug>\d+)\)") {
                $bugNumber = $matches["Bug"]
                $currentCommit.Details.Bug = $bugNumber
                $currentCommit.Details.BugURL = "$bugUrlBase$bugNumber"
                $currentCommit.Details.Message = $currentCommit.Details.Message -replace "(?i)\(Bug\d+\)", ""
            }

            # Case-insensitive role parsing with flexible spacing
            elseif ($entry -match "(?im)^roles?\s*:\s*(?<Roles>.+)") {
                $currentCommit.Details.Roles = ($matches["Roles"] -split ",") | ForEach-Object { $_.Trim() }
            }
        }
    }

    if ($null -ne $currentCommit -and ($Config -eq "" -or $currentCommit.Details.Roles -icontains $Config)) {
        $commitObjects += $currentCommit
    }

    Write-Log -message ('{0} :: Processing {1} {2} - {3:o}' -f $($MyInvocation.MyCommand.Name), $Config, $Version, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    Set-MarkdownPSModule

    $OSBuild = Get-OSVersionMarkDown
    $OSVersionExtended = Get-OSVersionExtended
    $OSVersion = Get-OSVersion
    $InstalledSoftware = Get-InstalledSoftware | Where-Object {
        ($psitem.DisplayName -match "\D") -and ($null -ne $psitem.DisplayVersion)
    }

    $mozillabuild = Get-WinFactsMozillaBuild
    $pythonPackages = Get-MozillaBuildPythonPackages -RequirementsFile "C:\requirements.txt"

    $InstalledSoftware_NotMicrosoft = $InstalledSoftware | Where-Object {
        $PSItem.Publisher -notmatch "Microsoft"
    } | ForEach-Object {
        [PSCustomObject]@{ Name = $PSItem.DisplayName; Version = $PSItem.DisplayVersion }
    } | Sort-Object Name, Version | Group-Object Name, Version | ForEach-Object { $_.Group[0] }

    $InstalledSoftware_Microsoft = $InstalledSoftware | Where-Object {
        $PSItem.Publisher -match "Microsoft"
    } | ForEach-Object {
        [PSCustomObject]@{ Name = $PSItem.DisplayName; Version = $PSItem.DisplayVersion }
    } | Sort-Object Name, Version | Group-Object Name, Version | ForEach-Object { $_.Group[0] }

    $markdown = ""
    switch -Wildcard ($OSVersion) {
        "*win_10_*"  { $OSHeader = "Windows 10" }
        "*win_11_*"  { $OSHeader = "Windows 11" }
        "*win_2022_*"{ $OSHeader = "Windows 2022" }
        default      { $null }
    }

    $Header = "$OSHeader Image Build $Version"
    $markdown += New-MDHeader -Text $Header -Level 1
    $markdown += "`n"

    $lines = @(
        "Config: $($Config)",
        "OS Name: $($Header) $($OSVersionExtended.DisplayVersion)",
        "OS Version: $($OSBuild)",
        "Organization: $($Organization)",
        "Repository: $($Repository)",
        "Branch: $($Branch)",
        "DeploymentId: $($DeploymentId)"
    )

    $markdown += New-MDList -Lines $lines -Style Unordered
    $markdown += New-MDHeader "Change Log" -Level 2

    foreach ($commit in $commitObjects) {
        $markdown += "[$($commit.Details.Message)]($($commit.URL))`n"
        if ($commit.Details.Jira -ne "No Ticket") {
            $markdown += "	**Jira:** [$($commit.Details.Jira)]($($commit.Details.JiraURL))`n"
        }
        if ($commit.Details.Bug -ne "") {
            $markdown += "	**Bug:** [$($commit.Details.Bug)]($($commit.Details.BugURL))`n"
        }
        $markdown += "	**Date:** $($commit.Details.Date)`n`n"
    }

    $markdown += New-MDHeader "Software Bill of Materials" -Level 2
    $markdown += New-MDHeader "Mozilla Build" -Level 2
    $markdown += "`n"
    $markdown += New-MDAlert -Lines @("Find more information about Mozilla Build on [Wiki](https://wiki.mozilla.org/MozillaBuild#Technical_Details)") -Style Important
    $markdown += New-MDList -Lines @("Mozilla Build: $($mozillabuild.custom_win_mozbld_version)") -Style Unordered
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

    Get-Content -Path "C:\software_report.md"

    if ($Version) {
        Copy-Item -Path "C:\software_report.md" -Destination "C:\$($Config)-$($Version).md"
    } else {
        Copy-Item -Path "C:\software_report.md" -Destination "C:\$($Config).md"
    }
}

