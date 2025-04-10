function Set-ReleaseNotes2 {
    [CmdletBinding()]
    param (
        [String] $Config,
        [String] $Version,
        [String] $Branch,
        [String] $Organization,
        [String] $Repository,
        [String] $LastDeployID,
        [String] $DeploymentId,
        [string[]] $Notes
    )

    Write-Host "Are there notes:"
    $Notes | ForEach-Object { Write-Host "  $_" }

    ## Setup Git repo
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
    $commitLog = (git log "$LastDeployID...$DeploymentId" --ancestry-path --pretty=format:"Commit: %H`nAuthor: %an`nDate: %ad`n`n%s`n%b`n---" --all) -join "`n"

    $commitEntries = $commitLog -split "(?=Commit: )"
    $commitObjects = @()
    $currentCommit = $null

    foreach ($entry in $commitEntries) {
        $entry = $entry.Trim()
        if ($entry -eq "") { continue }

        if ($entry -match "^Commit: (?<Hash>\w{40})") {
            if ($null -ne $currentCommit -and (
                $Config -eq "" -or
                $Config.ToLower() -eq "all" -or
                $currentCommit.Details.Roles -contains $Config
            )) {
                $commitObjects += $currentCommit
                Write-Host "✅ Keeping commit with roles: $($currentCommit.Details.Roles -join ', ')"
            } else {
                if ($null -ne $currentCommit) {
                    Write-Host "❌ Skipping commit - roles: $($currentCommit.Details.Roles -join ', '), config: $Config"
                }
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
            if ($entry -match "^Author: (?<Author>.+)") {
                $author = $matches["Author"]
            } elseif ($entry -match "^Date: (?<Date>.+)") {
                $dateParts = $matches["Date"] -split "\s+"
                $formattedDate = "$($dateParts[0]) $($dateParts[1]) $($dateParts[2]) $($dateParts[4])"
                if ($author) { $formattedDate += " by $author" }
                $currentCommit.Details.Date = $formattedDate
            } else {
                if ($entry -match "(?im)^\s*roles?:?\s*(?<Roles>[^\r\n]+)") {
                    $rawRoles = ($matches["Roles"] -split "(?i)location:")[0]
                    $currentCommit.Details.Roles = ($rawRoles -split ",") | ForEach-Object { $_.Trim() }
                    Write-Host "Parsed roles: $($currentCommit.Details.Roles -join ', ')"
                }
                if ($entry -match "^(?<Type>[A-Z]+):?\s") {
                    $currentCommit.Details.Type = $matches["Type"]
                }
                if ($entry -match "(?i)Jira:?\s*(?<Jira>[A-Za-z0-9-]+)") {
                    $jira = $matches["Jira"]
                    $currentCommit.Details.Jira = $jira
                    $currentCommit.Details.JiraURL = "$jiraUrlBase$jira"
                }
                if ($entry -match "(?i)Bug:?\s*(?<Bug>\d{5,})") {
                    $bug = $matches["Bug"]
                    $currentCommit.Details.Bug = $bug
                    $currentCommit.Details.BugURL = "$bugUrlBase$bug"
                }
                if ($entry -match "(?i)MSG:?\s*(?<Message>.+)$") {
                    $msg = $matches["Message"].Trim()
                    $currentCommit.Details.Message = "$($currentCommit.Details.Type) - $msg"
                }
            }
        }
    }

    # Handle the last commit
    if ($null -ne $currentCommit -and (
        $Config -eq "" -or
        $Config.ToLower() -eq "all" -or
        $currentCommit.Details.Roles -contains $Config
    )) {
        $commitObjects += $currentCommit
        Write-Host "✅ Keeping last commit with roles: $($currentCommit.Details.Roles -join ', ')"
    }

    Write-Host "`n🧩 Total commits added: $($commitObjects.Count)"
    Write-Host "📝 Notes: $($Notes -join ' | ')"

    ## OS and metadata
    Set-MarkdownPSModule
    $OSBuild = Get-OSVersionMarkDown
    $OSVersionExtended = Get-OSVersionExtended 
    $OSVersion = Get-OSVersion
    $InstalledSoftware = Get-InstalledSoftware | Where-Object {
        ($_.DisplayName -match "\D") -and ($_.DisplayVersion)
    }
    $mozillabuild = Get-WinFactsMozillaBuild
    $pythonPackages = Get-MozillaBuildPythonPackages -RequirementsFile "C:\requirements.txt"

    $InstalledSoftware_NotMicrosoft = $InstalledSoftware | Where-Object {
        $_.Publisher -notmatch "Microsoft"
    } | Sort-Object Name, DisplayVersion -Unique

    $InstalledSoftware_Microsoft = $InstalledSoftware | Where-Object {
        $_.Publisher -match "Microsoft"
    } | Sort-Object Name, DisplayVersion -Unique

    ## Build markdown
    $markdown = ""
    switch -Wildcard ($OSVersion) {
        "*win_10_*"   { $OSHeader = "Windows 10" }
        "*win_11_*"   { $OSHeader = "Windows 11" }
        "*win_2022_*" { $OSHeader = "Windows 2022" }
    }
    $Header = "$OSHeader Image Build $Version"
    $markdown += New-MDHeader -Text $Header -Level 1 + "`n"

    $lines = @(
        "Config: $($Config)",
        "OS Name: $($Header) $($OSVersionExtended.DisplayVersion)",
        "OS Version: $($OSBuild)",
        "Organization: $($Organization)",
        "Repository: $($Repository)",
        "Branch: $($Branch)",
        "DeploymentId: $($DeploymentId)"
    )
    $markdown += New-MDHeader "Previous Version Notes" -Level 2
    foreach ($note in $Notes) {
        $markdown += "* $note`n"
    }
    $markdown += "`n"
    $markdown += New-MDList -Lines $lines -Style Unordered
    $markdown += New-MDHeader "Change Log" -Level 2

    foreach ($commit in $commitObjects) {
        $markdown += "[$($commit.Details.Message)]($($commit.URL))`n"
        if ($commit.Details.Jira -ne "No Ticket") {
            $markdown += "  **Jira:** [$($commit.Details.Jira)]($($commit.Details.JiraURL))`n"
        }
        if ($commit.Details.Bug -ne "") {
            $markdown += "  **Bug:** [$($commit.Details.Bug)]($($commit.Details.BugURL))`n"
        }
        $markdown += "  **Date:** $($commit.Details.Date)`n`n"
    }

    $markdown += New-MDHeader "Software Bill of Materials" -Level 2
    $markdown += New-MDHeader "Mozilla Build" -Level 2 + "`n"
    $markdown += New-MDAlert -Lines @("Find more information about Mozilla Build on [Wiki](https://wiki.mozilla.org/MozillaBuild#Technical_Details)") -Style Important
    $markdown += New-MDList -Lines @("Mozilla Build: $($mozillabuild.custom_win_mozbld_version)") -Style Unordered

    $markdown += New-MDHeader "Taskcluster Packages Installed" -Level 3 + "`n"
    $markdown += Show-TaskclusterBinaries | New-MDTable + "`n"
    $markdown += New-MDHeader "Python Packages" -Level 3 + "`n"
    $markdown += $pythonPackages | New-MDTable + "`n"

    $markdown += New-MDHeader "Installed Software (Not Microsoft)" -Level 2 + "`n"
    $markdown += $InstalledSoftware_NotMicrosoft | New-MDTable + "`n"
    $markdown += New-MDHeader "Installed Software (Microsoft)" -Level 2 + "`n"
    $markdown += $InstalledSoftware_Microsoft | New-MDTable

    ## Save and display
    $outputPath = "C:\software_report.md"
    $markdown | Out-File -FilePath $outputPath -Encoding UTF8
    Get-Content -Path $outputPath

    if ($Version) {
        Copy-Item -Path $outputPath -Destination "C:\$($Config)-$($Version).md"
    } else {
        Copy-Item -Path $outputPath -Destination "C:\$($Config).md"
    }
}
