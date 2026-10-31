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

# Re-assert this bring-up on EVERY boot, not just first logon. The bake's windows-restart
# provisioners reboot the guest mid-build; the NAT NIC then re-classifies as 'Public' and
# NTLM WinRM stops answering, so Packer times out at "waiting for machine to restart".
# A SYSTEM startup task re-runs this script each boot so WinRM is back before Packer
# reconnects. Idempotent (self-registers on first logon); removed by sysprep-generalize.ps1.
$self = if ($PSCommandPath) { $PSCommandPath } else { 'C:\Windows\Setup\Scripts\set-bake-network.ps1' }
try {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $self)
    $trg = New-ScheduledTaskTrigger -AtStartup
    $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $st  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    Register-ScheduledTask -TaskName 'BakeNetwork' -Action $act -Trigger $trg -Principal $pri -Settings $st -Force | Out-Null
    Write-BakeLog 'registered BakeNetwork startup task (re-asserts network/WinRM on every boot)'
}
catch { Write-BakeLog ('WARN: could not register BakeNetwork startup task: ' + $_.Exception.Message) }

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

# Classify the NAT link as Private. This is THE critical WinRM enabler: the NAT link
# comes up 'Public' (no gateway/domain for NLA to identify), and on a Public network
# NTLM auth to a local account fails with 0x8009030d ("A specified logon session does
# not exist") — which is exactly what makes Packer hang at "Waiting for WinRM". With the
# profile Private (+ LocalAccountTokenFilterPolicy set in the specialize pass), NTLM to
# the local build account works. Set-NetConnectionProfile only takes once NLA has
# actually categorized the adapter, which lags first logon, so RETRY until it sticks.
for ($j = 0; $j -lt 30; $j++) {
    Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object {
        Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue
    }
    $cats = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Select-Object -Expand NetworkCategory)
    if ($cats.Count -gt 0 -and -not ($cats | Where-Object { $_ -ne 'Private' })) { break }
    Start-Sleep -Seconds 3
}
Write-BakeLog ("network profile(s): " + ((Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { $_.Name + '=' + $_.NetworkCategory }) -join ', '))

# Belt-and-suspenders: WinRM service policy keys enable Basic + unencrypted regardless
# of the network profile (they bypass the interactive 'network is Public' guard), so a
# Basic-auth fallback also works if NTLM/Private ever fails. Harmless with NTLM.
$winrmPol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WinRM\Service'
New-Item -Path $winrmPol -Force -ErrorAction SilentlyContinue | Out-Null
Set-ItemProperty -Path $winrmPol -Name AllowBasic -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path $winrmPol -Name AllowUnencryptedTraffic -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue

# Bring up the WinRM HTTP listener. Explicit `winrm create Listener` (unlike
# Enable-PSRemoting / winrm quickconfig) does NOT check the network-connection profile,
# so it works regardless. Idempotent.
cmd.exe /c 'sc config WinRM start= auto' | Out-Null
cmd.exe /c 'net start WinRM' 2>$null | Out-Null
cmd.exe /c 'winrm create winrm/config/Listener?Address=*+Transport=HTTP' 2>$null | Out-Null
netsh advfirewall firewall add rule name="WinRM-HTTP-In-5985" dir=in action=allow protocol=TCP localport=5985 | Out-Null

$ok = $false
try { $ok = [bool](Get-NetFirewallRule -DisplayName 'WinRM-HTTP-In-5985' -ErrorAction SilentlyContinue) } catch {}
Write-BakeLog ("set-bake-network: done (ip_assigned={0}, fw_rule={1})" -f $assigned, $ok)
