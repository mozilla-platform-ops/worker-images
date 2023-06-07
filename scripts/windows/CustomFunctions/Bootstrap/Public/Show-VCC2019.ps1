Function Show-VCC2019 {
    Get-InstalledSoftware | Where-Object {
        $PSItem.DisplayName -like "Microsoft Visual C++ 2019*"
    }
}