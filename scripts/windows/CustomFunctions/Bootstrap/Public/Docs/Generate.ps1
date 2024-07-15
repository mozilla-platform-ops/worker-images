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

<#
os build version
sp level
patch level
any version of mozilla build
git version, hg version, python version (whatever software we install)
dxdiag.exe output (gpu driver)
python package pip freeze (before task gets installed)
#>

Import-Module Bootstrap -Force

$dir = "/Users/jwmoss/code/mozilla/worker-images/scripts/windows/CustomFunctions/Bootstrap/Public/Docs"
$Windows = "Windows 11"
#$config = Get-Content "/Users/jwmoss/code/mozilla/worker-images/config/win11-64-2009.yaml" -raw | ConvertFrom-Yaml

$installedsoftware = Get-InstalledSoftware | Where-Object {
    $PSItem.DisplayName -match "\D" -and $PSItem.DisplayVersion -ne $null
}

$notMicrosoft = $installedsoftware|?{$_.Publisher -notmatch "Microsoft"}

$mozillabuild = Get-WinFactsMozillaBuild
$mozilla_build_version = $mozillabuild.custom_win_mozbld_vesion
$hg_version = $mozillabuild.custom_win_hg_version
$python_version = $mozillabuild.custom_win_python_version
$pip_version = $mozillabuild.custom_win_py3_pip_version
$git_version = (Get-WinFactsOtherApps).custom_win_git_version

$7zip  = $installedsoftware | Where-Object {
    $PSItem.DisplayName -like "*7-Zip*"
}

$vac = $installedsoftware | Where-Object {
    $PSItem.DisplayName -like "*Virtual Audio Cable*"
}

$gpg  = $installedsoftware | Where-Object {
    $PSItem.DisplayName -like "*Gpg4win*"
}

$mms = $installedsoftware | Where-Object {
    $PSItem.DisplayName -like "*Mozilla Maintenance*"
}

$nxlog = $installedsoftware | Where-Object {
    $PSItem.DisplayName -like "NXLog-CE*"
}

$puppet = $installedsoftware | Where-Object {
    $PSItem.DisplayName -like "Puppet*"
}

$pip_packages = Get-Content C:\requirements.txt | ForEach-Object {
    $split = $PSItem -split "=="
    $name = $split[0]
    $version = $split[1]
    [PSCustomObject]@{
        Name = $name
        Version = $version
    }
}

$Build_Info_Markdown = @"
# $($Windows)

- OS Version: $(Get-OSVersion)
- Image Version: 22621.3737.240607
"@

$Build_Info_Markdown | Out-File "C:\win11-64-2009.md"

$mozilla_build_markdown = @"

## Mozilla Build

- Mozilla Build $mozilla_build_version
  - For more details, visit [the docs](https://wiki.mozilla.org/MozillaBuild)
- Python $python_version

"@

Add-Content -Path "C:\win11-64-2009.md" -Value $mozilla_build_markdown
Add-Content -Path "C:\win11-64-2009.md" -Value "### Python Packages"
Add-Content -Path "C:\win11-64-2009.md" -Value ""

$pip_packages | Sort-Object -Property Name | ForEach-Object {
    Add-Content -Path "C:\win11-64-2009.md" -Value "- $($PSItem.Name) $($PSItem.Version)"
}

$base_software_stack = @"

## Installed Sofware

- 7-Zip $($7zip.DisplayVersion)
- Git $git_version
- Gpg4Win $($gpg.DisplayVersion)
- Mercurial $hg_version
- Mozilla Maintenance Service $($mms.DisplayVersion)
- NXLog-CE $($nxlog.DisplayVersion)
- Puppet Agent $($puppet.DisplayVersion)
- Virtual Audio Cable $($vac.DisplayVersion)
"@

Add-Content -Path "C:\win11-64-2009.md" -Value $base_software_stack

Start-Process -FilePath "C:\win11-64-2009.md"