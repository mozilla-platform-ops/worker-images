function  Set-ReleaseNotes2 {
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
		$LastDeployID,

        [String]
        $DeploymentId,

        [string[]]
        $Notes
    )
    Write-Host Are there notes
    Write-Host $Notes

	## Gather change log entries
    $repoUrl = "https://github.com/$Organization/$Repository"
    $repoPath = "C:\Ronin"
	#$repoPath = "C:\Ronin2"

    if (!(Test-Path $repoPath)) {
        git clone -q --single-branch --branch $Branch $repoUrl $repoPath
    } else {
		git config --global --add safe.directory C:/ronin
	}

    Set-Location -Path $repoPath
    git checkout $DeploymentId

    # Define URLs for GitHub, Jira, and Bugzilla
    $commitUrlBase = "https://github.com/$Organization/$Repository/commit/"
    $jiraUrlBase = "https://mozilla-hub.atlassian.net/browse/"
    $bugUrlBase = "https://bugzilla.mozilla.org/show_bug.cgi?id="

    # Get the date of the SinceHash commit
    $sinceDate = git show -s --format="%ad" $LastDeployID --date=format:"%Y-%m-%d"

    # Retrieve Git log of commits **between** SinceHash and NewHash

	#$commitLog = git log "$LastDeployID..$DeploymentId" --pretty=format:"Commit: %H`nAuthor: %an`nDate: %ad`n`n%s`n%b`n---" --all --since="$sinceDate"
    #$commitLog = git log "$LastDeployID^..$DeploymentId" --pretty=format:"Commit: %H`nAuthor: %an`nDate: %ad`n`n%s`n%b`n---" --all --since="$sinceDate"
    #$commitLog = git log "$LastDeployID...$DeploymentId" --ancestry-path --pretty=format:"Commit: %H`nAuthor: %an`nDate: %ad`n`n%s`n%b`n---" --all
    #write-host "$commitLog = git log "$LastDeployID...$DeploymentId" --ancestry-path --pretty=format:"Commit: %H`nAuthor: %an`nDate: %ad`n`n%s`n%b`n---" --all"

    $commitLog = (git log "$LastDeployID...$DeploymentId" --ancestry-path --pretty=format:"Commit: %H`nAuthor: %an`nDate: %ad`n`n%s`n%b`n---" --all) -join "`n"

    # Split commits by "Commit:"
    $commitEntries = $commitLog -split "(?=Commit: )"

    # Initialize an array to store commit objects
    $commitObjects = @()
    $currentCommit = $null


    foreach ($entry in $commitEntries) {
        $entry = $entry.Trim()
        if ($entry -eq "") { continue }

        if ($entry -match "^Commit: (?<Hash>\w{40})") {
        # Save previous commit
            if ($null -ne $currentCommit -and ($Config -eq "" -or $currentCommit.Details.Roles -contains $Config)) {
                $commitObjects += $currentCommit
            }

            $commitHash = $matches["Hash"]
            $commitUrl = "$commitUrlBase$commitHash"

            # Start new commit object
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

        # Parse current commit fields
        if ($null -ne $currentCommit) {
            if ($entry -match "^Author: (?<Author>.+)") {
                $author = $matches["Author"]
            }
            elseif ($entry -match "^Date: (?<Date>.+)") {
                $dateParts = $matches["Date"] -split "\s+"
                $formattedDate = "$($dateParts[0]) $($dateParts[1]) $($dateParts[2]) $($dateParts[4])"
                if ($author) {
                    $formattedDate += " by $author"
                }
                $currentCommit.Details.Date = $formattedDate
            }
            else {
		        if ($entry -match "(?im)^\s*roles?:?\s*(?<Roles>[^\r\n]+)") {
			        # Strip off anything after "Location:" or similar extra fields
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
                    $message = $matches["Message"].Trim()
                    $currentCommit.Details.Message = "$($currentCommit.Details.Type) - $message"
                }
            }
        }
    }

    # Add the last processed commit object if it contains the role
    if (
        $null -ne $currentCommit -and (
            $Config -eq "" -or 
            $Config.ToLower() -eq "all" -or 
            $currentCommit.Details.Roles -contains $Config
        )
    ) {
        $commitObjects += $currentCommit
        Write-Host "Keeping commit with roles: $($currentCommit.Details.Roles -join ', ')"
    } else {
        Write-Host "Skipping commit - roles: $($currentCommit.Details.Roles -join ', '), config: $Config"
    }
    ## The config will be the name of the configuration file (win11-64-2009) without the extension
    ## We'll use this to generate release notes for each OS

    Write-Log -message ('{0} :: Processing {1} {2} - {3:o}' -f $($MyInvocation.MyCommand.Name), $Config, $Version, (Get-Date).ToUniversalTime()) -severity 'DEBUG'

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
            $OSHeader = "Windows 10"
        }
        "*win_11_*" {
            $OSHeader = "Windows 11"
        }
        "*win_2022_*" {
            $OSHeader = "Windows 2022"
        }
        default {
            $null
        }
    }
	
	$Header = $OSHeader + " Image Build " + $Version

    if ($null -eq $OSVersion) {
        $reason = "Unable to determine OSVersion"
        Write-Log -message ('{0} :: {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), $reason, (Get-Date).ToUniversalTime()) -severity 'DEBUG'
    }

    $markdown += New-MDHeader -Text $Header -Level 1
    $markdown += "`n"
    $lines = @(
        "Config: $($Config)",
        "OS Name: $($Header) $($OSVersionExtended.DisplayVersion)",
        "OS Version: $($OSBuild)",
        "Organization: $($Organization)",
        "Repository: $($Repository)"
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

	## Not using MD commands for correct variable interpolation
    foreach ($commit in $commitObjects) {
        #$markdown += "#### [$($commit.Details.Message)]($($commit.URL))`n"
		$markdown += "[$($commit.Details.Message)]($($commit.URL))`n"
        if ($commit.Details.Jira -ne "No Ticket") {
            $markdown += "	**Jira:** [$($commit.Details.Jira)]($($commit.Details.JiraURL))`n"
        }
        if ($commit.Details.Bug -ne "") {
            $markdown += "	**Bug:** [$($commit.Details.Bug)]($($commit.Details.BugURL))`n"
        }
        $markdown += "	**Date:** $($commit.Details.Date)`n"
		$markdown += "`n`n"
        #$markdown += "`n---`n`n"
    }
	
	$markdown += New-MDHeader "Software Bill of Materials" -Level 2
	
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

    if ($Version) {
        Write-Log -message ('{0} :: Copying software_report.md to {1} - {2:o}' -f $($MyInvocation.MyCommand.Name), "(C:\$($Config)-$($Version).md)", (Get-Date).ToUniversalTime()) -severity 'DEBUG'
        ## Now copy the software markdown file elsewhere to prep for uploading to azure
        Copy-Item -Path "C:\software_report.md" -Destination "C:\$($Config)-$($Version).md"
    }
    else {
        ## Now copy the software markdown file elsewhere to prep for uploading to azure
        Copy-Item -Path "C:\software_report.md" -Destination "C:\$($Config).md"
    }

}
