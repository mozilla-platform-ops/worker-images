function Set-WorkerImageOutput {
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]
        $CommitMessage
    )
    
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module powershell-yaml -ErrorAction Stop
    $Commit = (ConvertFrom-Json $CommitMessage) -split " "
    #$Commit = (ConvertFrom-Json '${{toJSON(github.event.head_commit.message)}}') -Split " "
    $Key = $Commit | Foreach-object {
        if ($_ -match "-") {
            $_
        }
    }
    $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
    $locations = ($YAML.azure.locations | ConvertTo-Json -Compress)
    Write-Output "LOCATIONS=$locations" >> $ENV:GITHUB_OUTPUT
}