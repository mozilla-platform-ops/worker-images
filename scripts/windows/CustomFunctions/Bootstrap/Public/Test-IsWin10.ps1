function Test-IsWin10 {
    (Get-OSVersion) -match "win_10"
}