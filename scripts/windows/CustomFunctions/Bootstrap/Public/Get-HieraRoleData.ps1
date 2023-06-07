function Get-HieraRoleData {
    param(
        [System.IO.FileInfo]
        [ValidateScript({
                if ( -Not ($_ | Test-Path) ) {
                    throw "File or folder does not exist"
                }
                if ($_ -notmatch "(\.yml|\.yaml)") {
                    throw "The file specified in the path argument must be either of type yml or yaml"
                }
                return $true
            })]
        $Path
    )
    
    ConvertFrom-Yaml (get-Content $Path -Raw)
}
