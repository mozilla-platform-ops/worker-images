Function Invoke-RoninTest {
    [CmdletBinding()]
    param (
        [Parameter()]
        [String]
        $Test,

        [String[]]
        $Tags,

        [String[]]
        $ExcludeTag,

        [Switch]
        $PassThru
    )
    $Container = New-PesterContainer -Path $test
    $config = New-PesterConfiguration
    $config.Run.Container = $Container
    $config.Filter.Tag = $Tags
    $config.TestResult.Enabled = $true
    $config.Output.Verbosity = "Detailed"
    if ($ExcludeTag) {
        $config.Filter.ExcludeTag = $ExcludeTag
    }
    if ($PassThru) {
        $config.Run.Passthru = $true
    }
    Invoke-Pester -Configuration $config
}

function Get-InstalledSoftware {
    [CmdletBinding()]
    [OutputType([PSObject])]
    param (
        # The computer to execute against. By default, Get-InstalledSoftware reads registry keys on the local computer.
        [Parameter(ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [String]$ComputerName = $env:COMPUTERNAME,

        # Attempt to start the remote registry service if it is not already running. This parameter will only take effect if the service is not disabled.
        [Switch]$StartRemoteRegistry,

        # Some software packages, such as DropBox install into a users profile rather than into shared areas. Get-InstalledSoftware can increase the search to include each loaded user hive.
        #
        # If a registry hive is not loaded it cannot be searched, this is a limitation of this search style.
        [Switch]$IncludeLoadedUserHives,

        # By default Get-InstalledSoftware will suppress the display of entries with minimal information. If no DisplayName is set it will be hidden from view. This behaviour may be changed using this parameter.
        [Switch]$IncludeBlankNames
    )

    $keys = 'Software\Microsoft\Windows\CurrentVersion\Uninstall',
    'Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall'

    # If the remote registry service is stopped before this script runs it will be stopped again afterwards.
    if ($StartRemoteRegistry) {
        $shouldStop = $false
        $service = Get-Service RemoteRegistry -Computer $ComputerName

        if ($service.Status -eq 'Stopped' -and $service.StartType -ne 'Disabled') {
            $shouldStop = $true
            $service | Start-Service
        }
    }

    $baseKeys = [System.Collections.Generic.List[Microsoft.Win32.RegistryKey]]::new()

    $baseKeys.Add([Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $ComputerName, 'Registry64'))
    if ($IncludeLoadedUserHives) {
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('Users', $ComputerName, 'Registry64')
            foreach ($name in $baseKey.GetSubKeyNames()) {
                if (-not $name.EndsWith('_Classes')) {
                    Write-Debug ('Opening {0}' -f $name)

                    try {
                        $baseKeys.Add($baseKey.OpenSubKey($name, $false))
                    }
                    catch {
                        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                            $_.Exception.GetType()::new(
                                ('Unable to access sub key {0} ({1})' -f $name, $_.Exception.InnerException.Message.Trim()),
                                $_.Exception
                            ),
                            'SubkeyAccessError',
                            'InvalidOperation',
                            $name
                        )
                        Write-Error -ErrorRecord $errorRecord
                    }
                }
            }
        }
        catch [Exception] {
            Write-Error -ErrorRecord $_
        }
    }

    foreach ($baseKey in $baseKeys) {
        Write-Verbose ('Reading {0}' -f $baseKey.Name)

        if ($basekey.Name -eq 'HKEY_LOCAL_MACHINE') {
            $username = 'LocalMachine'
        }
        else {
            # Attempt to resolve a SID
            try {
                [System.Security.Principal.SecurityIdentifier]$sid = Split-Path $baseKey.Name -Leaf
                $username = $sid.Translate([System.Security.Principal.NTAccount]).Value
            }
            catch {
                $username = Split-Path $baseKey.Name -Leaf
            }
        }

        foreach ($key in $keys) {
            try {
                $uninstallKey = $baseKey.OpenSubKey($key, $false)

                if ($uninstallKey) {
                    $is64Bit = $true
                    if ($key -match 'Wow6432Node') {
                        $is64Bit = $false
                    }

                    foreach ($name in $uninstallKey.GetSubKeyNames()) {
                        $packageKey = $uninstallKey.OpenSubKey($name)

                        $installDate = Get-Date
                        $dateString = $packageKey.GetValue('InstallDate')
                        if (-not $dateString -or -not [DateTime]::TryParseExact($dateString, 'yyyyMMdd', (Get-Culture), 'None', [Ref]$installDate)) {
                            $installDate = $null
                        }

                        [PSCustomObject]@{
                            Name            = $name
                            DisplayName     = $packageKey.GetValue('DisplayName')
                            DisplayVersion  = $packageKey.GetValue('DisplayVersion')
                            InstallDate     = $installDate
                            InstallLocation = $packageKey.GetValue('InstallLocation')
                            HelpLink        = $packageKey.GetValue('HelpLink')
                            Publisher       = $packageKey.GetValue('Publisher')
                            UninstallString = $packageKey.GetValue('UninstallString')
                            URLInfoAbout    = $packageKey.GetValue('URLInfoAbout')
                            Is64Bit         = $is64Bit
                            Hive            = $baseKey.Name
                            Path            = Join-Path $key $name
                            Username        = $username
                            ComputerName    = $ComputerName
                        }
                    }
                }
            }
            catch {
                Write-Error -ErrorRecord $_
            }
        }
    }

    # Stop the remote registry service if required
    if ($StartRemoteRegistry -and $shouldStop) {
        $service | Stop-Service
    }
}

function Get-OSVersion {
    $release_key = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ReleaseId
    $caption = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
    $caption = $caption.ToLower()
    $os_caption = $caption -replace ' ', '_'

    switch -Wildcard ($os_caption) {
        "*windows_10*" {
            -join ("win_10_", $release_key)
        }
        "*windows_11*" {
            -join ("win_11_", $release_key)
        }
        default {
            $null
        }
    }
}

Function Show-Win10SDK {
    $names = @(
        "Application Verifier x64 External Package",
        "Kits Configuration Installer",
        "MSI Development Tools",
        "SDK ARM Additions",
        "SDK ARM Redistributables",
        "SDK Debuggers",
        "Universal CRT Extension SDK",
        "Universal CRT Headers Libraries and Sources",
        "Universal CRT Redistributable",
        "Universal CRT Tools x64",
        "Universal CRT Tools x86",
        "Universal General MIDI DLS Extension SDK",
        "WinAppDeploy",
        "Windows App Certification Kit Native Components",
        "Windows App Certification Kit SupportedApiList x86",
        "Windows App Certification Kit x64",
        "Windows Desktop Extension SDK",
        "Windows Desktop Extension SDK Contracts",
        "Windows IoT Extension SDK",
        "Windows IoT Extension SDK Contracts",
        "Windows IP Over USB",
        "Windows Mobile Extension SDK",
        "Windows Mobile Extension SDK Contracts",
        "Windows SDK",
        "Windows SDK ARM Desktop Tools",
        "Windows SDK Desktop Headers arm",
        "Windows SDK Desktop Headers arm64",
        "Windows SDK Desktop Headers x64",
        "Windows SDK Desktop Headers x86",
        "Windows SDK Desktop Libs arm",
        "Windows SDK Desktop Libs arm64",
        "Windows SDK Desktop Libs x64",
        "Windows SDK Desktop Libs x86",
        "Windows SDK Desktop Tools arm64",
        "Windows SDK Desktop Tools x64",
        "Windows SDK Desktop Tools x86",
        "Windows SDK DirectX x64 Remote",
        "Windows SDK DirectX x86 Remote",
        "Windows SDK EULA",
        "Windows SDK Facade Windows WinMD Versioned",
        "Windows SDK for Windows Store Apps",
        "Windows SDK for Windows Store Apps Contracts",
        "Windows SDK for Windows Store Apps DirectX x86 Remote",
        "Windows SDK for Windows Store Apps Headers",
        "Windows SDK for Windows Store Apps Libs",
        "Windows SDK for Windows Store Apps Metadata",
        "Windows SDK for Windows Store Apps Tools",
        "Windows SDK for Windows Store Managed Apps Libs",
        "Windows SDK Modern Non-Versioned Developer Tools",
        "Windows SDK Modern Versioned Developer Tools",
        "Windows SDK Redistributables",
        "Windows SDK Signing Tools",
        "Windows Team Extension SDK",
        "Windows Team Extension SDK Contracts",
        "WinRT Intellisense Desktop - en-us",
        "WinRT Intellisense Desktop - Other Languages",
        "WinRT Intellisense IoT - en-us",
        "WinRT Intellisense IoT - Other Languages",
        "WinRT Intellisense Mobile - en-us",
        "WinRT Intellisense PPI - en-us",
        "WinRT Intellisense PPI - Other Languages",
        "WinRT Intellisense UAP - en-us",
        "WinRT Intellisense UAP - Other Languages",
        "WPT Redistributables",
        "WPTx64"
    )
    Get-InstalledSoftware | Where-Object {
        $PSItem.DisplayName -in $Names
    }
}

function Test-IsWin10 {
    (Get-OSVersion) -match "win_10"
}

function Test-IsWin11 {
    (Get-OSVersion) -match "win_11"
}

Function Show-WinDotNet48 {
    Get-InstalledSoftware | Where-Object {
        $PSItem.DisplayName -like "Microsoft .NET Framework 4.8*"
    }
}

Function Show-VCC2019 {
    Get-InstalledSoftware | Where-Object {
        $PSItem.DisplayName -like "Microsoft Visual C++ 2019*"
    }
}

Function Show-Win10SDKAddon {
    Get-InstalledSoftware | Where-Object {
        $PSItem.DisplayName -eq "Windows SDK AddOn"
    }
}