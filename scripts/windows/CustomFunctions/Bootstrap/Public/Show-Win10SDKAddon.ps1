Function Show-Win10SDKAddon {
    Get-InstalledSoftware | Where-Object {
        $PSItem.DisplayName -eq "Windows SDK AddOn"
    }
}