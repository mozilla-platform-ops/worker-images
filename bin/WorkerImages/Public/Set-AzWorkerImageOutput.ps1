function Set-AzWorkerImageOutput {
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]
        $CommitMessage
    )
    
    #Set-PSRepository PSGallery -InstallationPolicy Trusted
    #Install-Module powershell-yaml -ErrorAction Stop
    $Commit = ConvertFrom-Json $CommitMessage
    ## Handle the pools and pluck them out
    $keys_index = $commit.IndexOf("keys:")
    $keys = if ($keys_index -ne -1) {
        $keys_value = $commit.Substring($keys_index + 5).Trim()
        if ($keys_value -match ",") {
            $keys_array = $keys_value.Split(",")
            foreach ($key in $keys_array) {
                $key.Trim()
            }
        }
        else {
            $keys_value.Trim()
        }
    }
    Foreach ($key in $keys) {
        $YAML = Convertfrom-Yaml (Get-Content "config/$key.yaml" -raw)
        $locations = ($YAML.azure.locations | ConvertTo-Json -Compress)
        Write-Output "LOCATIONS=$locations" >> $ENV:GITHUB_OUTPUT
        Write-Output "KEY=$Key" >> $ENV:GITHUB_OUTPUT
    }
}