Function Show-VCC2022 {
    Get-InstalledSoftware | Where-Object {
        $PSItem.DisplayName -like "Microsoft Visual C++ 2015-2022*" -or
        $PSItem.DisplayName -like "Microsoft Visual C++ 2022*"
    }
}
