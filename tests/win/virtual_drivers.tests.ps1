Describe "VB-CABLE Virtual Audio Device" {
    BeforeAll {
        # ronin_puppet RELOPS-2437 (#1234) replaced Virtual Audio Cable 4.64
        # with VB-CABLE pack 45, which registers as a system driver and a
        # MEDIA PnP device rather than an entry in installed software.
        $ServiceName = "VBAudioVACMME"
        $DeviceName  = "VB-Audio Virtual Cable"
        $Driver = Get-CimInstance Win32_SystemDriver -Filter "Name='$ServiceName'" -ErrorAction SilentlyContinue
        $Device = Get-PnpDevice -Class MEDIA -ErrorAction SilentlyContinue |
            Where-Object { $PSItem.FriendlyName -eq $DeviceName }
    }
    It "VB-CABLE system driver ($ServiceName) is installed" {
        $Driver | Should -Not -BeNullOrEmpty
    }
    It "VB-Audio Virtual Cable MEDIA device is present" {
        $Device | Should -Not -BeNullOrEmpty
    }
}
