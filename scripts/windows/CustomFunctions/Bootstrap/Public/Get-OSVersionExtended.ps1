function Get-OSVersionExtended {
    [CmdletBinding()]
    param (

    )

    Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
}