function Get-WinFactsSSHd {
    $service = 'sshd'

    $result = (Get-Service $service -ErrorAction SilentlyContinue)
    if ($null -eq $result) {
        $sshd_present = 'not_installed'
    }
    else {
        $sshd_present = 'installed'
    }

    [PSCustomObject]@{
        custom_win_sshd = $sshd_present
    }
}