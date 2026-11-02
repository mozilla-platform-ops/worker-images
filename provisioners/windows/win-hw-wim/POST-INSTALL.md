Windows access cleanup runs synchronously during installation. It does not depend
on Ronin, bootstrap, or an interactive login. Normal Windows Setup invokes it as
SYSTEM during `specialize`. Direct WIM deployment invokes it from WinPE after
DISM applies the image and before reboot.

The builders package `scripts/post-install/Remove-BuildAccess.ps1` and a matching
unattend command into baked WIMs, every edition of plain WIM exports, and ISO media
(via `sources/$OEM$/$$`). MDC1 deployment stages the same script and uses the hook
in `base-autounattend.xml`, including when deploying older images.

Cleanup removes build WinRM listeners, the build firewall rule, temporary WinRM/UAC
policy overrides, the BakeNetwork task/helper, and disables WinRM and the `packer`
account if present. It preserves deployment autologon and Ronin configuration.
Diagnostics go to `%WINDIR%\Temp\remove-build-access.log`.

Older WIMs can boot through their existing startup task without rerunning either
`specialize` or `SetupComplete`. MDC1's direct-WIM path therefore runs the same
script with `-OfflineWindowsRoot` against the applied OS. It loads SOFTWARE/SYSTEM
hives temporarily, removes WinRM listeners, build firewall rules and temporary
policies, disables WinRM in every control set, and removes the bake network helper.
A failure stops deployment before reboot. This mode does not edit account/SAM data;
it preserves the build account's already-disabled state from the bake.

The normal Setup hook uses `WillReboot=OnRequest`: successful cleanup returns 0;
a cleanup failure returns 3, which terminates Windows Setup. It does not request
a reboot.

These output configurations are amd64. Consumers supplying their own answer files
must retain the specialize command and payload. Custom direct-WIM deployment tools
must invoke offline cleanup after applying the image, as MDC1 does. The image
retains build access configuration until this step runs.

The bake's Sysprep sequence and AppXSvc policy remain the same as main. Test a baked
WIM deployment and a non-Ronin ISO installation before rollout.
