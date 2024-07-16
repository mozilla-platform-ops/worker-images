function Get-OSVersionMarkDown {
    $OSCurrentVersion = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion')
    $result = "{0}.{1}" -f $OSCurrentVersion.CurrentBuildNumber, $OSCurrentVersion.UBR

    return $result

}