function Assert-IsTester {
    $CustomOS = Get-WinFactsCustomOS
    switch ($CustomOS.custom_win_purpose) {
        "tester" {
            $true
        }
        Default {
            $false
        }
    }
}