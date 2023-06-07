Function Get-WinFactsDrives {
    [PSCustomObject]@{
        custom_win_z_drive = if ((Test-Path Z:\)) { "exists" } else { $null }
        custom_win_y_drive = if ((Test-Path Y:\)) { "exists" } else { $null }
    }
}