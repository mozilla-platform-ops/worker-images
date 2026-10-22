# Runners ship yq, so CI does not install powershell-yaml from PSGallery.
function ConvertFrom-Yaml {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Yaml)
    $json = $Yaml | yq -o=json 'explode(.)' -
    if ($LASTEXITCODE -ne 0) { throw "yq failed with exit code $LASTEXITCODE" }
    $json | ConvertFrom-Json -AsHashtable
}
