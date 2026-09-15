@{
    RootModule        = 'Bootstrap.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '675d9739-45eb-4a73-93fd-9dc4fea2fd20'
    Author            = 'Jonathan Moss'
    CompanyName       = 'Mozilla'
    Copyright         = '(c) Mozilla. All rights reserved.'
    Description       = 'PowerShell Module used to bootstrap puppet'
    FunctionsToExport = @(
        'Assert-IsBuilder',
        'Assert-IsTester',
        'Disable-AntiVirus',
        'Disable-Services',
        'Get-GenericWorkerVersion',
        'Get-InstalledSoftware',
        'Get-LivelogVersion',
        'Get-MozillaBuildPythonPackages',
        'Get-OSVersion',
        'Get-OSVersionExtended',
        'Get-OSVersionMarkDown',
        'Get-ProxyVersion',
        'Get-WinFactsCustomOS',
        'Get-WinFactsDirectories',
        'Get-WinFactsMozillaBuild',
        'Get-WorkerRunnerVersion',
        'Install-AzPreReq',
        'Invoke-DownloadWithRetry',
        'Invoke-RoninTest',
        'Move-StrapPuppetLogs',
        'Set-AzRoninRepo',
        'Set-Logging',
        'Set-PesterVersion',
        'Set-ReleaseNotes',
        'Set-RoninRegOptions',
        'Set-YAMLModule',
        'Show-TaskclusterBinaries',
        'Show-VCC2019',
        'Show-Win10SDK',
        'Show-Win10SDKAddon',
        'Show-Win11SDK',
        'Show-WinDotNet48',
        'Start-AzRoninPuppet',
        'Write-Log'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
