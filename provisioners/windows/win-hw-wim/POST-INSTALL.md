Windows access cleanup runs synchronously as SYSTEM during the installed OS's
`specialize` pass. It does not depend on Ronin, bootstrap, or an interactive login.

The builders package `scripts/post-install/Remove-BuildAccess.ps1` and a matching
unattend command into baked WIMs, every edition of plain WIM exports, and ISO media
(via `sources/$OEM$/$$`). MDC1 deployment stages the same script and uses the hook
in `base-autounattend.xml`, including when deploying older images.

Cleanup removes build WinRM listeners, the build firewall rule, temporary WinRM/UAC
policy overrides, the BakeNetwork task/helper, and disables WinRM and the `packer`
account if present. It preserves deployment autologon and Ronin configuration.
Diagnostics go to `%WINDIR%\Temp\remove-build-access.log`.

The hook uses `WillReboot=OnRequest`: successful cleanup returns 0; a cleanup failure
returns 3, which terminates Windows Setup. It does not request a reboot.

These output configurations are amd64. Consumers supplying their own answer files
must retain the specialize command and payload; replacing the answer file can
bypass the hook. Applying a WIM without running Windows Setup/specialize also does
not execute it. The image retains build access configuration until this step runs.

The bake's Sysprep sequence and AppXSvc policy remain the same as main. Test a baked
WIM deployment and a non-Ronin ISO installation before rollout.
