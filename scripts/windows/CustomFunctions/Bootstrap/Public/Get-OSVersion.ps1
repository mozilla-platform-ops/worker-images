function Get-OSVersion {
    $release_key = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ReleaseId
    $caption = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
    $caption = $caption.ToLower()
    $os_caption = $caption -replace ' ', '_'

    switch -Wildcard ($os_caption) {
        "*windows_10*" {
            -join ("win_10_", $release_key)
        }
        "*windows_11*" {
            -join ("win_11_", $release_key)
        }
        default {
            $null
        }
    }
}