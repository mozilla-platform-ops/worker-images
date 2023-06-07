Function Show-WinDotNet48 {
    Get-InstalledSoftware | Where-Object {
        $PSItem.DisplayName -like "Microsoft .NET Framework 4.8*"
    }
}
