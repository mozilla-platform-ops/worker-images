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
    $commitLog = git log "$LastDeployID...$DeploymentId" --ancestry-path --pretty=format:"Commit: %H`nAuthor: %an`nDate: %ad`n`n%s`n%b`n---" --all
    #write-host "$commitLog = git log "$LastDeployID...$DeploymentId" --ancestry-path --pretty=format:"Commit: %H`nAuthor: %an`nDate: %ad`n`n%s`n%b`n---" --all"

    #$commitLog = (git log "$LastDeployID...$DeploymentId" --ancestry-path --pretty=format:"Commit: %H`nAuthor: %an`nDate: %ad`n`n%s`n%b`n---" --all) -join "`n"

    # Split commits by "Commit:"
    $commitEntries = $commitLog -split "(?=Commit: )"
	Write-Host "Total commit entries found: $($commitEntries.Count)"
$commitEntries | ForEach-Object { Write-Host "---- ENTRY START ----`n$_`n---- ENTRY END ----" }

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
			$rawRoles = $matches["Roles"] -split "Location:" | Select-Object -First 1
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

# Don't forget the last commit
if ($null -ne $currentCommit -and ($Config -eq "" -or $currentCommit.Details.Roles -contains $Config)) {
    $commitObjects += $currentCommit
}

 

    ## Let's create the markdown file
    $markdown = ""




    foreach ($note in $Notes) {
        $markdown += "* $note`n"
    }
    $markdown += "`n"


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
	
	 $markdown | Out-File "C:\Users\markc\Desktop\2025\software_report.md"
}  

