param(
    [switch]$single,
    [switch]$pool,
    [string]$node,
    [string]$pool_name,

    # Environment + paths
    [string]$domain_suffix = "wintest2.releng.mdc1.mozilla.com",
    [string]$pxe_script    = "C:\PXE\SetPXE.ps1",
    [string]$audit_script  = "C:\management_scripts\pool_audit.ps1",
    [string]$yaml_url      = "https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/pools.yml",

    # Behavior flags
    [switch]$no_pxe_missing,  # skip pass 2
    [switch]$wipe_d,          # wipe D:\* when PXE-booting nodes
    [switch]$pxe_only,        # skip audit and PXE immediately in pass 1
    [int]$sleep_secs = 300,   # default 5 minutes between passes
    [switch]$quick,           # when set, reduce sleep to 30 seconds (except pass 1->2 which is fixed at 5s)

    # Dry-run + throttling
    [switch]$dry_run,                 # print actions only; no PXE, no reboot, no remote changes
    [int]$pxe_batch_size = 10,        # after this many PXE triggers, sleep
    [int]$pxe_batch_sleep_secs = 60,  # sleep duration after batch threshold

    [switch]$help
)

if ($quick) { $sleep_secs = 30 }

# ------------------ Globals / Tracking ------------------
$script:failed_ssh            = @()
$script:missing_audit_script  = @()
$script:wrong_config          = @()
$script:failed_script         = @()
$script:pxe_triggered         = @()
$script:retry_attempted       = @()
$script:retry_recovered       = @()
$script:pxe_inline_used       = @()
$script:doWipeD               = $false

# Dry-run + batching state
$script:would_pxe             = @()
$script:pxe_batch_count       = 0

# ------------------ Helpers ------------------
function Sleep-BetweenPasses {
    param([int]$Seconds,[string]$From = "",[string]$To = "")
    Write-Host ""
    if ($From -or $To) { Write-Host ("---- Sleeping {0}s before {1} -> {2} ----" -f $Seconds,$From,$To) }
    else { Write-Host ("---- Sleeping {0}s before next pass ----" -f $Seconds) }
    Start-Sleep -Seconds $Seconds
    Write-Host ""
}

function Invoke-SSH {
    param(
        [Parameter(Mandatory)][string]$NodeName,
        [Parameter(Mandatory)][string]$Command
    )
    $output = & ssh -q -o ConnectTimeout=5 -o UserKnownHostsFile=empty.txt -o StrictHostKeyChecking=no $NodeName $Command
    [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

function Encode-PSCommand {
    param([Parameter(Mandatory)][string]$Command)
    $pref = @"
`$ProgressPreference='SilentlyContinue';
`$VerbosePreference='SilentlyContinue';
`$InformationPreference='SilentlyContinue';
`$WarningPreference='SilentlyContinue';
"@
    $full = "$pref $Command"
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($full)
    [Convert]::ToBase64String($bytes)
}

function Invoke-SSHPS {
    param([Parameter(Mandatory)][string]$NodeName,[Parameter(Mandatory)][string]$PsCommand)
    $enc = Encode-PSCommand -Command $PsCommand
    Invoke-SSH -NodeName $NodeName -Command ("powershell -NoLogo -NonInteractive -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc")
}

function Invoke-SSHPSFile {
    param(
        [Parameter(Mandatory)][string]$NodeName,
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$Arguments=@()
    )
    $pairs = @()
    for ($i=0; $i -lt $Arguments.Count; $i+=2) {
        $k=$Arguments[$i]; $v=$Arguments[$i+1]
        $pairs += "$k `"$v`""
    }
    $argLine = $pairs -join ' '
    $ps = "& `"$ScriptPath`" $argLine"
    Invoke-SSHPS -NodeName $NodeName -PsCommand $ps
}

function Quote-LiteralPath {
    param([Parameter(Mandatory)][string]$Path)
    return "'" + ($Path -replace "'", "''") + "'"
}

# register successful PXE trigger and apply batch sleep
function Register-PXETrigger {
    param(
        [Parameter(Mandatory)][string]$NodeName,
        [switch]$Inline
    )

    if ($script:pxe_triggered -notcontains $NodeName) { $script:pxe_triggered += $NodeName }
    if ($Inline -and $script:pxe_inline_used -notcontains $NodeName) { $script:pxe_inline_used += $NodeName }

    $script:pxe_batch_count++

    if ($pxe_batch_size -gt 0 -and $script:pxe_batch_count -ge $pxe_batch_size) {
        Write-Host ""
        Write-Host ("---- PXE batch threshold reached ({0} hosts). Sleeping {1}s ----" -f $pxe_batch_size, $pxe_batch_sleep_secs)
        Start-Sleep -Seconds $pxe_batch_sleep_secs
        Write-Host ""
        $script:pxe_batch_count = 0
    }
}

# ------------------ Embedded PXE Script Content ------------------
$pxeScriptContent = @'
param([string]$WipeD = 'False')
try {
  Import-Module Microsoft.Windows.Bcd.Cmdlets -ErrorAction Stop

  $data = (Get-BcdStore).Entries | ForEach-Object {
    $d = ($_.Elements | Where-Object { $_.Name -eq "Description" }).Value
    if ($d -match "IPv4") { $_ }
  }
  if (-not $data) { exit 999 }

  bcdedit /set "{fwbootmgr}" BOOTSEQUENCE "{$($data.Identifier.Guid)}"

  if ($WipeD -match '^(?i:true|1|yes|y)$') {
    try { Remove-Item "D:\*" -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }

  Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r','/t','5','/f' -WindowStyle Hidden
  'PXE_TRIGGERED'
} catch {
  exit 888
}
'@

# ------------------ Staging & Invoking PXE (two SSH calls) ------------------
function Stage-RemotePXEFile {
    param([Parameter(Mandatory)][string]$NodeName,[Parameter(Mandatory)][string]$RemotePath)

    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pxeScriptContent))
    $folder = [IO.Path]::GetDirectoryName($RemotePath)
    $file   = $RemotePath

    $ps = @"
New-Item -ItemType Directory -Force -Path '$folder' | Out-Null
`$b = '$b64'
[IO.File]::WriteAllBytes('$file',[Convert]::FromBase64String(`$b))
"@

    $res = Invoke-SSHPS -NodeName $NodeName -PsCommand $ps
    if ($res.ExitCode -eq 255) {
        if ($script:failed_ssh -notcontains $NodeName) { $script:failed_ssh += $NodeName }
        return @{Ok=$false; Msg="ssh failed"}
    }
    if ($res.ExitCode -ne 0) { return @{Ok=$false; Msg="stage failed"} }

    $verify = Invoke-SSHPS -NodeName $NodeName -PsCommand "[int](Get-Item -LiteralPath '$file').Length"
    if ($verify.ExitCode -eq 255) {
        if ($script:failed_ssh -notcontains $NodeName) { $script:failed_ssh += $NodeName }
        return @{Ok=$false; Msg="ssh failed"}
    }
    if ($verify.ExitCode -eq 0) {
        $lenRemote = [int]($verify.Output | Select-Object -First 1)
        $lenLocal  = [Text.Encoding]::UTF8.GetBytes($pxeScriptContent).Length
        if ($lenRemote -ne $lenLocal) { return @{Ok=$false; Msg="size mismatch"} }
    }
    return @{Ok=$true}
}

function Invoke-RemotePXE {
    param([Parameter(Mandatory)][string]$NodeName,[Parameter(Mandatory)][string]$RemotePath,[bool]$WipeD=$false)
    $args = if ($WipeD) { @('-WipeD','True') } else { @('-WipeD','False') }
    $run  = Invoke-SSHPSFile -NodeName $NodeName -ScriptPath $RemotePath -Arguments $args
    $out  = ($run.Output | Out-String)
    if ($run.ExitCode -eq 0 -and $out -match 'PXE_TRIGGERED') { return @{Ok=$true; Out=$out} }
    if ($run.ExitCode -eq 255) { return @{Ok=$false; Out=$out; Msg='ssh failed'} }
    return @{Ok=$false; Out=$out; Msg=("exit {0}" -f $run.ExitCode) }
}

# ------------------ Inline PXE Fallback (no file needed) ------------------
function Invoke-InlinePXE {
    param(
        [Parameter(Mandatory)][string]$NodeName,
        [bool]$WipeD=$false
    )
    # Same logic as $pxeScriptContent, executed inline
    $inline = @"
try {
  Import-Module Microsoft.Windows.Bcd.Cmdlets -ErrorAction Stop
  \$data = (Get-BcdStore).Entries | ForEach-Object {
    \$d = (\$_.Elements | Where-Object { \$_.Name -eq 'Description' }).Value
    if (\$d -match 'IPv4') { \$_ }
  }
  if (-not \$data) { exit 999 }

  bcdedit /set '{fwbootmgr}' BOOTSEQUENCE "{\$($data.Identifier.Guid)}"

  if ('$WipeD' -match '^(?i:true|1|yes|y)$') {
    try { Remove-Item 'D:\*' -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }

  Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r','/t','5','/f' -WindowStyle Hidden
  'PXE_TRIGGERED'
} catch {
  exit 888
}
"@
    $res = Invoke-SSHPS -NodeName $NodeName -PsCommand $inline
    $out = ($res.Output | Out-String)
    if ($res.ExitCode -eq 0 -and $out -match 'PXE_TRIGGERED') {
        return @{ Ok=$true; Out=$out }
    }
    if ($res.ExitCode -eq 255) { return @{ Ok=$false; Out=$out; Msg='ssh failed' } }
    return @{ Ok=$false; Out=$out; Msg=("exit {0}" -f $res.ExitCode) }
}

function Set-RemotePXE {
    param([Parameter(Mandatory)][string]$NodeName,[bool]$WipeD=$script:doWipeD)

    if ($dry_run) {
        Write-Host "[$NodeName] DRY RUN: would trigger PXE (Wipe D: $WipeD)."
        if ($script:would_pxe -notcontains $NodeName) { $script:would_pxe += $NodeName }
        return
    }

    # 1) Try to stage the file version
    $stage = Stage-RemotePXEFile -NodeName $NodeName -RemotePath $pxe_script

    if (-not $stage.Ok) {
        # If staging failed but SSH worked, try inline fallback immediately
        if ($stage.Msg -ne 'ssh failed') {
            Write-Host "[$NodeName] PXE stage failed ($($stage.Msg)); attempting inline PXE..."
            $inline = Invoke-InlinePXE -NodeName $NodeName -WipeD:$WipeD
            if ($inline.Ok) {
                Write-Host "[$NodeName] PXE (inline) invoked."
                Register-PXETrigger -NodeName $NodeName -Inline
                Start-Sleep -Seconds 5
                return
            } else {
                if ($inline.Msg -eq 'ssh failed') {
                    Write-Host "[$NodeName] SSH failed during inline PXE."
                    if ($script:failed_ssh -notcontains $NodeName) { $script:failed_ssh += $NodeName }
                } else {
                    Write-Host "[$NodeName] Inline PXE returned unexpected result: $($inline.Msg)"
                }
                return
            }
        } else {
            Write-Host "[$NodeName] SSH failed during PXE stage."
            if ($script:failed_ssh -notcontains $NodeName) { $script:failed_ssh += $NodeName }
            return
        }
    }

    # 2) File staged OK – try file-based invoke
    $invoke = Invoke-RemotePXE -NodeName $NodeName -RemotePath $pxe_script -WipeD:$WipeD
    if ($invoke.Ok) {
        Write-Host "[$NodeName] PXE script invoked."
        Register-PXETrigger -NodeName $NodeName
        Start-Sleep -Seconds 5
        return
    }

    # 3) File-based invoke failed: try inline fallback (unless SSH failed)
    if ($invoke.Msg -eq 'ssh failed') {
        Write-Host "[$NodeName] SSH failed when invoking PXE."
        if ($script:failed_ssh -notcontains $NodeName) { $script:failed_ssh += $NodeName }
        return
    }

    Write-Host "[$NodeName] PXE script returned unexpected result: $($invoke.Msg); attempting inline PXE..."
    $inline2 = Invoke-InlinePXE -NodeName $NodeName -WipeD:$WipeD
    if ($inline2.Ok) {
        Write-Host "[$NodeName] PXE (inline) invoked."
        Register-PXETrigger -NodeName $NodeName -Inline
        Start-Sleep -Seconds 5
    } else {
        if ($inline2.Msg -eq 'ssh failed') {
            Write-Host "[$NodeName] SSH failed during inline PXE."
            if ($script:failed_ssh -notcontains $NodeName) { $script:failed_ssh += $NodeName }
        } else {
            Write-Host "[$NodeName] Inline PXE returned unexpected result: $($inline2.Msg)"
        }
    }
}

# ------------------ First Pass helpers ------------------
function Invoke-AuditScript {
    param(
        [Parameter(Mandatory)] [string]$AuditScript,
        [Parameter(Mandatory)] [string]$GitHash,
        [Parameter(Mandatory)] [string]$WorkerPool,
        [Parameter(Mandatory)] [string]$NodeName,
        [Parameter(Mandatory)] [string]$Image_Name
    )

    # Presence check
    $qPath    = Quote-LiteralPath $AuditScript
    $psExists = "if (Test-Path -LiteralPath $qPath) { 'EXISTS' } else { 'MISSING' }"
    $check = Invoke-SSHPS -NodeName $NodeName -PsCommand $psExists

    if ($check.ExitCode -eq 255) {
        Write-Host "[$NodeName] SSH connection failed for audit presence check."
        if ($script:failed_ssh -notcontains $NodeName) { $script:failed_ssh += $NodeName }
        return
    }
    if ($check.ExitCode -ne 0) {
        Write-Host "[$NodeName] Audit presence check failed (exit $($check.ExitCode))."
        $script:failed_script += $NodeName
        Set-RemotePXE -NodeName $NodeName -WipeD:$script:doWipeD
        return
    }

    if ($check.Output -notmatch 'EXISTS') {
        Write-Host "[$NodeName] Audit script missing ($AuditScript)."
        if ($script:missing_audit_script -notcontains $NodeName) { $script:missing_audit_script += $NodeName }
        return
    }

    # Run audit script
    $args = @('-git_hash',$GitHash,'-worker_pool_id',$WorkerPool,'-image_name',$Image_Name)
    try {
        $run = Invoke-SSHPSFile -NodeName $NodeName -ScriptPath $AuditScript -Arguments $args
        $result = ($run.Output | Out-String)

        switch ($run.ExitCode) {
            0 {
                Write-Host "[$NodeName] Audit script completed successfully."

                # Filter out any line containing 'good' (case-insensitive)
                $lines    = $result -split "(`r`n|`n|`r)"
                $filtered = $lines | Where-Object { $_.Trim() -and $_ -notmatch '(?i)\bgood\b' }
                if ($filtered -and $filtered.Count -gt 0) {
                    Write-Host "[$NodeName] Audit output:"
                    $filtered | ForEach-Object { Write-Host "  $_" }
                }

                if ($result -match '(?i)\bbad\b') {
                    if ($dry_run) { Write-Host "[$NodeName] Audit reported bad/wrong config; DRY RUN: would trigger PXE." }
                    else          { Write-Host "[$NodeName] Audit reported bad/wrong config; triggering PXE." }

                    $script:wrong_config += $NodeName
                    Set-RemotePXE -NodeName $NodeName -WipeD:$script:doWipeD
                }
            }
            255 {
                Write-Host "[$NodeName] SSH connection failed when running audit."
                if ($script:failed_ssh -notcontains $NodeName) { $script:failed_ssh += $NodeName }
            }
            default {
                if ($dry_run) { Write-Host "[$NodeName] Audit script failed (exit $($run.ExitCode)); DRY RUN: would trigger PXE." }
                else          { Write-Host "[$NodeName] Audit script failed (exit $($run.ExitCode)); triggering PXE." }

                $script:failed_script += $NodeName
                Set-RemotePXE -NodeName $NodeName -WipeD:$script:doWipeD
            }
        }
    } catch {
        Write-Host "[$NodeName] Error running audit: $($_.Exception.Message)"
        $script:failed_script += $NodeName
        Set-RemotePXE -NodeName $NodeName -WipeD:$script:doWipeD
    }
}

function Invoke-PXEForMissingAudit {
    $targets = $script:missing_audit_script | Sort-Object -Unique
    if (-not $targets.Count) { Write-Host "No nodes missing the audit script. Skipping second pass."; return $false }
    Write-Host "Starting second pass: PXE-booting nodes missing the audit script..."
    foreach ($n in $targets) {
        Write-Host "PXE on $n"
        Set-RemotePXE -NodeName $n -WipeD:$script:doWipeD
    }
    return $true
}

function Invoke-RetryFailedSSH {
    $targets = $script:failed_ssh | Sort-Object -Unique
    if (-not $targets.Count) { Write-Host "No SSH failures to retry. Skipping third pass."; return }

    Write-Host "Starting third pass: retrying SSH on previously failed nodes..."
    $script:retry_attempted = $targets
    $script:failed_ssh = @()

    foreach ($fqdn in $targets) {
        Write-Host "Retrying $fqdn"
        $short = $fqdn -replace ("\." + [regex]::Escape($domain_suffix) + "$"), ""
        $wp = $YAML.pools | Where-Object { $_.nodes -contains $short }
        if (-not $wp) { Write-Host "[$fqdn] Not found in YAML; leaving in failed SSH."; $script:failed_ssh += $fqdn; continue }
        Invoke-AuditScript -AuditScript $audit_script -GitHash $wp.hash -WorkerPool $wp.name -Image_Name $wp.image -NodeName $fqdn
        if ($script:failed_ssh -notcontains $fqdn) { $script:retry_recovered += $fqdn }
    }
}

# ------------------ CLI UX ------------------
if (-not $single -and -not $pool -and -not $help) {
    $choice = Read-Host "Neither single nor pool parameters were provided. Enter `n'1' - single node `n'2' - entire pool `n'3' - help `n'q' - quit `n"
    switch ($choice) { '1' { $single=$true } '2' { $pool=$true } '3' { $help=$true } 'q' { Write-Host "Exiting script."; exit } default { Write-Host "Invalid choice."; $help=$true } }
}

if ($help) {
@"
Usage: script.ps1 [options]

Options:
  -single                 : Operate on a single node.
  -node                   : Node name when using -single.
  -pool                   : Operate on an entire pool of nodes.
  -pool_name              : Pool name when using -pool.
  -pxe_only               : Skip audit presence check and immediately PXE the selected nodes in pass 1.
  -wipe_d                 : Wipe D:\* on nodes when triggering PXE (SSH).
  -no_pxe_missing         : Skip pass 2 (PXE for nodes missing audit).
  -sleep_secs <n>         : Sleep between passes (default 300; use -quick for 30s).
  -quick                  : Shortcut to set sleep between passes to 30 seconds. (Pass 1->2 is always 5s.)

  -dry_run                : DRY RUN mode (no PXE, no reboot, no remote file writes).
  -pxe_batch_size <n>     : After <n> successful PXE triggers, sleep (default 10).
  -pxe_batch_sleep_secs <n>: Sleep length after threshold (default 60).

  -help                   : Show this help.

SSH config example:
  Host *.$domain_suffix
    User administrator
    IdentityFile ~/.ssh/win_audit_id_rsa
"@ | Write-Host
    exit
}

# ------------------ Pool Data ------------------
Write-Host "Pulling pool data from $yaml_url"
$YAML = Invoke-WebRequest -Uri $yaml_url | ConvertFrom-Yaml

# ------------------ Wipe-D decision ------------------
if ($single) {
    if ([string]::IsNullOrWhiteSpace($node)) {
        $node = Read-Host "Enter a value for 'node'"
        if ([string]::IsNullOrWhiteSpace($node)) { Write-Host "No value provided for 'node'. Exiting."; exit }
    }
    $node_name = "$node.$domain_suffix"
    $WorkerPool=$null; $hash=$null; $image_name=$null
    foreach ($wp in $YAML.pools) {
        if ($wp.nodes -contains $node) { $WorkerPool=$wp.name; $hash=$wp.hash; $image_name=$wp.image; break }
    }
    if (-not $WorkerPool) { Write-Host "Node name not found in YAML."; exit 96 }

    if ($wipe_d) { $script:doWipeD = $true } else { $ans = Read-Host "Wipe D:\ during PXE for $node_name ? (y/N)"; if ($ans -match '^(?i)y(es)?$') { $script:doWipeD = $true } }
}
elseif ($pool) {
    if ([string]::IsNullOrWhiteSpace($pool_name)) {
        Write-Host "Pool name required. Available pools:"
        foreach ($wp in $YAML.pools) { Write-Host $wp.name; if ($wp.PSObject.Properties.Name -contains 'Description') { Write-Host "Description: $($wp.Description)" }; Write-Host }
        $pool_name = Read-Host "Enter pool name"
        if ([string]::IsNullOrWhiteSpace($pool_name)) { Write-Host "No pool name provided. Exiting."; exit }
    }
    $pool_names = @($YAML.pools.name)
    if ($pool_names -notcontains $pool_name) { Write-Host "$pool_name is not a valid pool name. Exiting."; exit }
    if ($wipe_d) { $script:doWipeD = $true } else { $ans = Read-Host "Wipe D:\ during PXE for pool '$pool_name'? (y/N)"; if ($ans -match '^(?i)y(es)?$') { $script:doWipeD = $true } }
}

# ------------------ First pass ------------------
if ($pxe_only) {
    Write-Host ""
    Write-Host "------------------------------------------------------------"
    Write-Host "            FIRST PASS (PXE-ONLY MODE VIA SSH)              "
    Write-Host "                 Wipe D: $($script:doWipeD)                 "
    Write-Host "                 Dry run: $dry_run                          "
    Write-Host "------------------------------------------------------------"
    Write-Host ""

    if ($single) {
        Write-Host "PXE (no audit) on $node_name"
        Set-RemotePXE -NodeName $node_name -WipeD:$script:doWipeD
    }
    if ($pool) {
        $nodes = ($YAML.pools | Where-Object { $_.name -eq $pool_name }).nodes
        foreach ($n in $nodes) {
            $node_name = "$n.$domain_suffix"
            Write-Host "PXE (no audit) on $node_name"
            Set-RemotePXE -NodeName $node_name -WipeD:$script:doWipeD
        }
    }
    Sleep-BetweenPasses -Seconds $sleep_secs -From "PASS 1 (PXE-only)" -To "PASS 3 (Retry SSH)"
}
else {
    if ($single) {
        Write-Host "Connecting to $node_name"
        Invoke-AuditScript -AuditScript $audit_script -GitHash $hash -WorkerPool $WorkerPool -Image_Name $image_name -NodeName $node_name
    }
    if ($pool) {
        $nodes      = ($YAML.pools | Where-Object { $_.name -eq $pool_name }).nodes
        $hash       = ($YAML.pools | Where-Object { $_.name -eq $pool_name }).hash
        $image_name = ($YAML.pools | Where-Object { $_.name -eq $pool_name }).image
        foreach ($n in $nodes) {
            $node_name = "$n.$domain_suffix"
            Write-Host "Connecting to $node_name"
            Invoke-AuditScript -AuditScript $audit_script -GitHash $hash -WorkerPool $pool_name -Image_Name $image_name -NodeName $node_name
        }
    }

    if (-not $no_pxe_missing) {
        # Pass 1 -> Pass 2 is ALWAYS 5 seconds
        Sleep-BetweenPasses -Seconds 5 -From "PASS 1 (Audit)" -To "PASS 2 (PXE missing audit)"
    } else {
        # If we're skipping pass 2, use normal sleep to pass 3
        Sleep-BetweenPasses -Seconds $sleep_secs -From "PASS 1 (Audit)" -To "PASS 3 (Retry SSH)"
    }
}

# ------------------ Second pass (PXE for missing audit) ------------------
if (-not $pxe_only) {
    if (-not $no_pxe_missing) {
        Write-Host ""
        Write-Host "------------------------------------------------------------"
        Write-Host "                    SECOND PASS (PXE)                       "
        Write-Host "        Nodes missing the audit script will PXE now         "
        Write-Host "             Wipe D: $($script:doWipeD)                     "
        Write-Host "             Dry run: $dry_run                              "
        Write-Host "------------------------------------------------------------"
        Write-Host ""

        $didPXE = Invoke-PXEForMissingAudit

        if (-not $didPXE) {
            Write-Host ""
            Sleep-BetweenPasses -Seconds $sleep_secs -From "PASS 2 (PXE missing audit)" -To "PASS 3 (Retry SSH)"
        } else {
            Write-Host "Skipping sleep after PASS 2 (PXE for missing audit) because PXE was triggered."
        }
    }
} else {
    Write-Host ""
    Write-Host "---- Skipping second pass (already forced PXE in pass 1) ----"
    Write-Host ""
}

# ------------------ Third pass (retry SSH) ------------------
Write-Host ""
Write-Host "------------------------------------------------------------"
Write-Host "            THIRD PASS (RETRY SSH FAILURES ONCE)            "
Write-Host "------------------------------------------------------------"
Write-Host ""
Invoke-RetryFailedSSH
Write-Host ""

# ------------------ Final Summaries ------------------
Write-Host ""
Write-Host "==== SUMMARY ===="
Write-Host "Dry run: $dry_run"
Write-Host "PXE Wipe D setting: $($script:doWipeD)"
Write-Host ("PXE batch throttle: size={0}, sleep={1}s" -f $pxe_batch_size, $pxe_batch_sleep_secs)
Write-Host ""

Write-Host "Nodes with missing audit script ($audit_script):"
if ($script:missing_audit_script.Count) { ($script:missing_audit_script | Sort-Object -Unique) | ForEach-Object { Write-Host "- $_" } } else { Write-Host "- none" }

Write-Host ""
Write-Host "Nodes where PXE boot was triggered (SSH):"
if ($script:pxe_triggered.Count) { ($script:pxe_triggered | Sort-Object -Unique) | ForEach-Object { Write-Host "- $_" } } else { Write-Host "- none" }

Write-Host ""
Write-Host "Nodes that used inline PXE (fallback without remote file):"
if ($script:pxe_inline_used.Count) { ($script:pxe_inline_used | Sort-Object -Unique) | ForEach-Object { Write-Host "- $_" } } else { Write-Host "- none" }

Write-Host ""
Write-Host "Nodes with failed SSH connection (after retry):"
if ($script:failed_ssh.Count) { ($script:failed_ssh | Sort-Object -Unique) | ForEach-Object { Write-Host "- $_" } } else { Write-Host "- none" }

Write-Host ""
Write-Host "Nodes that recovered on SSH retry:"
if ($script:retry_recovered.Count) { ($script:retry_recovered | Sort-Object -Unique) | ForEach-Object { Write-Host "- $_" } } else { Write-Host "- none" }

Write-Host ""
Write-Host "Nodes with wrong config:"
if ($script:wrong_config.Count) { ($script:wrong_config | Sort-Object -Unique) | ForEach-Object { Write-Host "- $_" } } else { Write-Host "- none" }

Write-Host ""
Write-Host "Nodes with script issues:"
if ($script:failed_script.Count) { ($script:failed_script | Sort-Object -Unique) | ForEach-Object { Write-Host "- $_" } } else { Write-Host "- none" }

Write-Host ""
Write-Host "Nodes that would have PXE’d (dry run):"
if ($script:would_pxe.Count) { ($script:would_pxe | Sort-Object -Unique) | ForEach-Object { Write-Host "- $_" } } else { Write-Host "- none" }