function Get-WinFactsOtherApps {
    $git = Get-Command "git.exe"
    if ($git) {
        $git_ver = "{0}.{1}.{2}" -f $git.Version.Major, $git.Version.Minor, $git.Version.Build
    }
    else {
        $git_ver = 0.0.0
    }
    
    [PSCustomObject]@{
        custom_win_git_version = $git_ver
    }
}