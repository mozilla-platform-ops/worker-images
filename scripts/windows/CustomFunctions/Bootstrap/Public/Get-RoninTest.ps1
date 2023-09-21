function Get-RoninTest {
    [CmdletBinding()]
    param (
        [String]
        $Key
    )
    
    ## Get just the tests that are defined in the config
    $Hiera = Convertfrom-Yaml (Get-Content -Path "C:\ronin\data\roles\$key.yaml" -Raw)
    
    ## Loop through the tests based on which ones were selected
    $hiera.tests | ForEach-Object {
        $name = $psitem
        Get-ChildItem -Path "C:/Tests/*" -Filter $name
    }
}