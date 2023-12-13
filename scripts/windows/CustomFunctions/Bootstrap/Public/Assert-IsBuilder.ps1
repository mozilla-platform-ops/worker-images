function Assert-IsBuilder {
    $CustomOS = Get-WinFactsCustomOS
    switch ($CustomOS.custom_win_purpose) {
        "builder" {
            $true
        }
        Default {
            $false
        }
    }
}