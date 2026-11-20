# Windows hardware deployment

`OS-deploy.ps1` matches the node's reverse DNS hostname against `pools.yml`.
Nodes with missing deployment secrets, unregistered nodes, and nodes listed in
`Known-BAD` use the recovery pool for their hostname prefix. Without a matching
prefix, deployment uses `defaults.recovery_pool`. It logs a generated
`recovery-*` computer name when the hostname is unavailable. Pass
`-RecoveryPool <pool name>` at PXE deployment to select a different recovery image.

Recovery mode installs Windows and enables Administrator SSH with the existing
RelOps public key. The deploy log and the Windows Application log (source
`BootStrap`) record why worker bootstrap was skipped. Recovery mode persists
across reboots. Correct the reported issue, return repaired `Known-BAD` nodes to
the appropriate worker pool, and redeploy to resume normal bootstrap.
