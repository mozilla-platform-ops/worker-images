<#
Create $env:systemdrive\BootStrap
Download nxlog-ce-3.2.2329.msi to $env:systemdrive\BootStrap
Install nxlog-ce-3.2.2329.msi
Download nxlog.conf to $env:systemdrive\Program Files (x86)\nxlog\conf\
Download papertrail-bundle.pem to $env:systemdrive\Program Files (x86)\nxlog\cert\
Restart 'nxlog' service
#>

<#
Create $env:systemdrive\scratch
Download BootStrap_Azure_07-2022.zip to $env:systemdrive\scratch
Extract BootStrap_Azure_07-2022.zip to $env:systemdrive
Remove $env:systemdrive\scratch
Install Git-2.36.1-64-bit.exe
Install puppet-agent-6.0.0-x64.msi
#>

<#
Create HKLM:\SOFTWARE\Mozilla\ronin_puppet
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\image_provisioner
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\worker_pool_id
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\role
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\inmutable
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\last_run_exit
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\bootstrap_stage
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\source\Organisation
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\source\Repository
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\source\Branch
#>

<#
Clone https://github.com/$sourceOrg/$sourceRepo to $env:systemdrive\ronin
Checkout the branch under $env:systemdrive\ronin
Check for $env:systemdrive\ronin\manifests\nodes.pp and if not there copy $env:systemdrive\BootStrap\nodes.pp to it
Replace roles::role with roles::(value from HKLM:\SOFTWARE\Mozilla\ronin_puppet\role)
Copy $env:systemdrive\BootStrap\secrets\ to $env:systemdrive\ronin\data\secrets\
If Windows 10, set HKLM:SYSTEM\CurrentControlSet\Services\SecurityHealthService dword start value 4
If not Windows 2012, set HKLM:SYSTEM\CurrentControlSet\Services\sense dword start value 4
#>

<#
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\bootstrap_stage
Run puppet and check for logs under $env:systemdrive\logs\yyyyMMdd-HHmm-bootstrap-puppet.log
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\last_run_exit
Set HKLM:\SOFTWARE\Mozilla\ronin_puppet\bootstrap_stage
Check for last exit code to be 0 or 2
If worker pool is trusted, then remove the $env:systemdrive\generic-worker\ed25519-private.key
If worker pool is trusted, then block livelog outbound
If worker pool isn't trusted, set HKLM:\SOFTWARE\Mozilla\ronin_puppet\last_run_exit
Move logs from $env:systemdrive\logs\bootstrap
#>