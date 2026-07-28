# set-bake-network.ps1 — build-only network bring-up for the bake VM.
#
# Dropped into the base image at C:\Windows\Setup\Scripts\ by prepare-base-vhdx.ps1
# and invoked from the unattend's FirstLogonCommands (oobeSystem). It assigns the
# static IP the NAT switch expects (no DHCP on wim-nat) and re-asserts the WinRM
# HTTP listener + firewall so Packer can connect.
#
# Why here and not (only) in the specialize pass: during specialize the NIC is
# frequently not yet enumerated/"Up", so New-NetIPAddress silently no-ops and the
# guest is left on an APIPA 169.254.x.x address that the host can't reach — Packer
# then hangs forever at "Waiting for WinRM". Running at first logon (network stack
# fully initialized) with a retry loop makes the assignment deterministic.
#
# All of this is build-only and scrubbed by sysprep-generalize.ps1 before capture,
# so it never ships in the golden WIM.

$ip  = '192.168.234.10'
$pfx = 24
$gw  = '192.168.234.1'
$log = 'C:\Windows\Temp\bake-network.log'

function Write-BakeLog([string] $m) {
    "{0} {1}" -f (Get-Date -Format o), $m | Out-File -FilePath $log -Append -Encoding utf8
}

Write-BakeLog 'set-bake-network: start'

$assigned = $false
for ($i = 0; $i -lt 60; $i++) {
    $a = Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    if (-not $a) { $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1 }
    if ($a) {
        Write-BakeLog ("adapter={0} ifIndex={1} status={2}" -f $a.Name, $a.ifIndex, $a.Status)
        if (-not (Get-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip -ErrorAction SilentlyContinue)) {
            # drop any self-assigned APIPA lease first so the static add is clean
            Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -like '169.254.*' } |
                Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
            New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip -PrefixLength $pfx -DefaultGateway $gw -ErrorAction SilentlyContinue | Out-Null
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses '8.8.8.8', '1.1.1.1' -ErrorAction SilentlyContinue
        }
        if (Get-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $ip -ErrorAction SilentlyContinue) {
            Write-BakeLog ("static IP {0}/{1} gw {2} assigned" -f $ip, $pfx, $gw)
            $assigned = $true
            break
        }
    }
    Start-Sleep -Seconds 2
}

if (-not $assigned) { Write-BakeLog 'WARNING: never assigned static IP (no Up adapter?)' }

# Re-assert WinRM regardless — idempotent, and a safety net if the specialize-pass
# listener setup did not stick. Explicit `winrm create Listener` (unlike
# Enable-PSRemoting / winrm quickconfig) does NOT check the network-connection
# profile, so it works even when the NAT link is classified 'Public'.
cmd.exe /c 'sc config WinRM start= auto' | Out-Null
cmd.exe /c 'net start WinRM' 2>$null | Out-Null
cmd.exe /c 'winrm create winrm/config/Listener?Address=*+Transport=HTTP' 2>$null | Out-Null
cmd.exe /c 'winrm set winrm/config/service/auth @{Basic="true"}' 2>$null | Out-Null
cmd.exe /c 'winrm set winrm/config/service @{AllowUnencrypted="true"}' 2>$null | Out-Null
netsh advfirewall firewall add rule name="WinRM-HTTP-In-5985" dir=in action=allow protocol=TCP localport=5985 | Out-Null

Write-BakeLog 'set-bake-network: done'
