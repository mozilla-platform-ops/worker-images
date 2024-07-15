function Get-StringPart {
    param (
        [Parameter(ValueFromPipeline)]
        [string] $toolOutput,
        [string] $Delimiter = " ",
        [int[]] $Part
    )
    $parts = $toolOutput.Split($Delimiter, [System.StringSplitOptions]::RemoveEmptyEntries)
    $selectedParts = $parts[$Part]
    return [string]::Join($Delimiter, $selectedParts)
}

function Get-OSVersion {
    $OSVersion = (Get-CimInstance -ClassName Win32_OperatingSystem).Version
    $OSBuild = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion' UBR).UBR
    return "$OSVersion Build $OSBuild"
}

Import-Module Bootstrap -Force

$installedsoftware = Get-InstalledSoftware | Where-Object {
    $PSItem.DisplayName -match "\D" -and $PSItem.DisplayVersion -ne $null
}

$notMicrosoft = $installedsoftware|?{$_.Publisher -notmatch "Microsoft"}

$Markdown = ""
