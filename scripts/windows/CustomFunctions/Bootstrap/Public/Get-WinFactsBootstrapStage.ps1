function Get-WinFactsBootStrapStage {
    if (test-path "HKLM:\SOFTWARE\Mozilla\ronin_puppet") {
        $bootstrap_stage = (Get-ItemProperty "HKLM:\SOFTWARE\Mozilla\ronin_puppet").bootstrap_stage
        [PSCustomObject]@{
            custom_win_bootstrap_stage = $bootstrap_stage
        }
    }
    else {
        throw "HKLM:\SOFTWARE\Mozilla\ronin_puppet not found!"
    }
}