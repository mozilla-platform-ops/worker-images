function Install-PostInstallCleanup {
    param(
        [Parameter(Mandatory)] [string] $WindowsRoot,
        [string] $UnattendPath = (Join-Path $WindowsRoot 'Panther/unattend.xml')
    )
    $ErrorActionPreference = 'Stop'
    $scripts = Join-Path $WindowsRoot 'Setup/Scripts'
    New-Item -ItemType Directory -Path $scripts -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'post-install/Remove-BuildAccess.ps1') -Destination $scripts -Force
    $ns = 'urn:schemas-microsoft-com:unattend'
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    if (Test-Path -LiteralPath $UnattendPath) { $xml.Load($UnattendPath) }
    else { $xml.LoadXml('<unattend xmlns="urn:schemas-microsoft-com:unattend" />') }
    function Add-Element($Parent, $Name) {
        $element = $xml.CreateElement($Name, $ns)
        $Parent.AppendChild($element) | Out-Null
        return $element
    }
    $settings = $xml.SelectSingleNode("/*[local-name()='unattend']/*[local-name()='settings' and @pass='specialize']")
    if (-not $settings) {
        $settings = Add-Element $xml.DocumentElement 'settings'
        $settings.SetAttribute('pass', 'specialize')
    }
    $component = $settings.SelectSingleNode("*[local-name()='component' and @name='Microsoft-Windows-Deployment' and @processorArchitecture='amd64']")
    if (-not $component) {
        $component = Add-Element $settings 'component'
        foreach ($item in @{name='Microsoft-Windows-Deployment'; processorArchitecture='amd64'; publicKeyToken='31bf3856ad364e35'; language='neutral'; versionScope='nonSxS'}.GetEnumerator()) {
            $component.SetAttribute($item.Key, $item.Value)
        }
    }
    $commands = $component.SelectSingleNode("*[local-name()='RunSynchronous']")
    if (-not $commands) { $commands = Add-Element $component 'RunSynchronous' }
    $existing = $commands.SelectSingleNode("*[local-name()='RunSynchronousCommand']/*[local-name()='Path' and contains(text(),'Remove-BuildAccess.ps1')]")
    if (-not $existing) {
        $orders = @($commands.SelectNodes("*[local-name()='RunSynchronousCommand']/*[local-name()='Order']") | ForEach-Object { [int]$_.InnerText })
        $order = if ($orders.Count) { ($orders | Measure-Object -Maximum).Maximum + 1 } else { 1 }
        $command = Add-Element $commands 'RunSynchronousCommand'
        $command.SetAttribute('action', 'http://schemas.microsoft.com/WMIConfig/2002/State', 'add') | Out-Null
        (Add-Element $command 'Order').InnerText = [string]$order
        (Add-Element $command 'Path').InnerText = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%WINDIR%\Setup\Scripts\Remove-BuildAccess.ps1" -ForWindowsSetup'
        (Add-Element $command 'WillReboot').InnerText = 'OnRequest'
    }
    New-Item -ItemType Directory -Path (Split-Path $UnattendPath -Parent) -Force | Out-Null
    $xml.Save($UnattendPath)
}
