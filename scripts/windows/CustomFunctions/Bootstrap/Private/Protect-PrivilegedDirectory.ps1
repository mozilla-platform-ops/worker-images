function Protect-PrivilegedDirectory {
    param([Parameter(Mandatory)][string] $Path)

    $directorySddl = 'O:BAG:BAD:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)'
    $fileSddl = 'O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)'
    $rootAcl = [System.Security.AccessControl.DirectorySecurity]::new()
    $rootAcl.SetSecurityDescriptorSddlForm($directorySddl)
    New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
    Set-Acl -LiteralPath $Path -AclObject $rootAcl -ErrorAction Stop

    Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop | ForEach-Object {
        $acl = if ($_.PSIsContainer) {
            [System.Security.AccessControl.DirectorySecurity]::new()
        } else {
            [System.Security.AccessControl.FileSecurity]::new()
        }
        $acl.SetSecurityDescriptorSddlForm($(if ($_.PSIsContainer) { $directorySddl } else { $fileSddl }))
        Set-Acl -LiteralPath $_.FullName -AclObject $acl -ErrorAction Stop
    }

    $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor
        [System.Security.AccessControl.AccessControlSections]::Owner
    # Windows may add the AI flag when applying this protected DACL.
    if (((Get-Acl -LiteralPath $Path -ErrorAction Stop).GetSecurityDescriptorSddlForm($sections) -replace 'D:PAI', 'D:P') -ne
        $rootAcl.GetSecurityDescriptorSddlForm($sections)) {
        throw "Failed to restrict $Path to SYSTEM and Administrators."
    }
}
