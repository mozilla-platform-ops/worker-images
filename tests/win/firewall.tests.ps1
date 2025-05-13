Describe "Firewall" {
    BeforeDiscovery {
        $Hiera = $Data.Hiera
    }

    It "ICMP is allowed" {
        (Get-NetFirewallRule -DisplayName "File and Printer Sharing (Echo Request - ICMPv4-In)").Enabled | Should -BeTrue
    }
}
