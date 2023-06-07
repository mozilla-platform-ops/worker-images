function Test-IsWin11 {
    (Get-OSVersion) -match "win_11"
}