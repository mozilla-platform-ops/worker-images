# AuditAndPXE.ps1

Audit Windows worker nodes over **SSH** and, when needed, trigger a **PXE boot** to reprovision them.

The script runs in **passes**:

1. **Audit (via SSH)** – check for and run an audit script on each node.
   - If the audit script **exits non-zero** or its output contains **“bad”** → PXE the node.
   - If the audit script is **missing** → queue the node for PXE in Pass 2.
2. **PXE for missing-audit** – PXE any nodes that didn’t have the audit script (unless disabled).
3. **Retry SSH** – one more audit attempt for nodes that had SSH failures in earlier actions.


> By default the wait **between passes is 5 minutes**, except the wait **between Pass 1 → Pass 2 is always 5 seconds** to quickly PXE nodes missing the audit. Use `-quick` to shorten the other waits to **30 seconds**.  
> If Pass 2 actually PXEs any nodes, the script **does not sleep** before Pass 3.

---

## Table of Contents

- [Requirements](#requirements)
- [Recommended SSH config](#recommended-ssh-config)
- [Getting Started](#getting-started)
- [YAML Pool Definition](#yaml-pool-definition)
- [Usage](#usage)
- [Options](#options)
- [What Happens in Each Pass](#what-happens-in-each-pass)
- [PXE Triggering Details](#pxe-triggering-details)
- [Dry Run](#dry-run)
- [PXE Throttling](#pxe-throttling)
- [Output & Summary](#output--summary)
- [Exit Codes](#exit-codes)
- [Troubleshooting](#troubleshooting)

---

## Requirements

**Controller (where you run the script):**
- PowerShell 5.1+ (or PowerShell 7+)
- OpenSSH client (`ssh`) on `PATH`
- Network access to target nodes (TCP/22)
- Ability to parse YAML via `ConvertFrom-Yaml` (module/cmdlet must exist in your environment)

**Target nodes:**
- OpenSSH server (`sshd`) running and reachable
- Can run PowerShell via SSH
- Have `bcdedit` and (ideally) the `Microsoft.Windows.Bcd.Cmdlets` module
- Firmware BCD contains an **IPv4 PXE** entry

---

## Recommended SSH config

~~~sshconfig
Host *.wintest2.releng.mdc1.mozilla.com
  User administrator
  IdentityFile ~/.ssh/win_audit_id_rsa
~~~

---

## Getting Started

1. Save this orchestrator as `AuditAndPXE.ps1` on the controller host.
2. Confirm you can SSH to a node as an admin user:

   ~~~bash
   ssh nuc13-004.wintest2.releng.mdc1.mozilla.com hostname
   ~~~

3. Run the script for a single node or a pool (defined in YAML).

---

## YAML Pool Definition

Pools are read from:

- https://raw.githubusercontent.com/mozilla-platform-ops/worker-images/refs/heads/main/provisioners/windows/MDC1Windows/pools.yml

**Expected structure (simplified):**

~~~yaml
pools:
  - name: win11-64-24h2-hw-alpha
    description: Windows 11 24H2 hardware alpha pool
    image: win11-24h2
    hash: 1234567890abcdef
    nodes:
      - nuc13-004
      - nuc13-005
      # ...
~~~

> The audit pass provides `-git_hash`, `-worker_pool_id` (pool name), and `-image_name` (image) to your audit script.

---

## Usage

~~~powershell
# Single node audit → PXE as needed
.\AuditAndPXE.ps1 -single -node nuc13-004

# Entire pool
.\AuditAndPXE.ps1 -pool -pool_name win11-64-24h2-hw-alpha

# PXE immediately (skip audit) for a node
.\AuditAndPXE.ps1 -single -node nuc13-004 -pxe_only

# PXE immediately for a pool and wipe D:\ (dangerous)
.\AuditAndPXE.ps1 -pool -pool_name win11-64-24h2-hw-alpha -pxe_only -wipe_d

# Quick mode: cut inter-pass sleeps to 30s (Pass 1→2 still 5s)
.\AuditAndPXE.ps1 -pool -pool_name win11-64-24h2-hw-alpha -quick

# Dry run: show what would happen without changing anything
.\AuditAndPXE.ps1 -pool -pool_name win11-64-24h2-hw-alpha -dry_run

# Change PXE throttling: sleep 120s after every 5 successful PXE triggers
.\AuditAndPXE.ps1 -pool -pool_name win11-64-24h2-hw-alpha -pxe_batch_size 5 -pxe_batch_sleep_secs 120
~~~

---

## Options

| Option                  | Type    | Default                                | Description                                                                                   |
|-------------------------|---------|----------------------------------------|-----------------------------------------------------------------------------------------------|
| `-single`               | switch  | —                                      | Operate on a single node.                                                                     |
| `-pool`                 | switch  | —                                      | Operate on an entire pool of nodes.                                                           |
| `-node`                 | string  | —                                      | Node short name (e.g., `nuc13-004`).                                                          |
| `-pool_name`            | string  | —                                      | Pool name in the YAML file.                                                                   |
| `-domain_suffix`        | string  | `wintest2.releng.mdc1.mozilla.com`     | Domain appended to node names.                                                                |
| `-pxe_script`           | string  | `C:\PXE\SetPXE.ps1`                    | Remote path where the PXE helper is staged (file-based PXE).                                  |
| `-audit_script`         | string  | `C:\management_scripts\pool_audit.ps1` | Remote audit script path on nodes.                                                            |
| `-yaml_url`             | string  | *(see above)*                          | Pools YAML location.                                                                          |
| `-pxe_only`             | switch  | —                                      | Skip audit and PXE immediately in Pass 1.                                                     |
| `-no_pxe_missing`       | switch  | —                                      | Skip Pass 2 (PXE for nodes missing the audit script).                                         |
| `-wipe_d`               | switch  | —                                      | When PXEing, wipe `D:\*` on the node before reboot. **Dangerous.**                            |
| `-sleep_secs`           | int     | `300`                                  | Wait between passes (5 min). **Pass 1→2 is always 5s.**                                       |
| `-quick`                | switch  | —                                      | Shorten inter-pass waits to **30s** (Pass 1→2 still 5s).                                      |
| `-dry_run`              | switch  | —                                      | Print actions only; do not stage PXE helper, change boot order, wipe disks, or reboot.        |
| `-pxe_batch_size`       | int     | `10`                                   | After this many **successful PXE triggers**, sleep for `-pxe_batch_sleep_secs`.               |
| `-pxe_batch_sleep_secs` | int     | `60`                                   | Sleep duration after `-pxe_batch_size` successful PXE triggers.                               |
| `-help`                 | switch  | —                                      | Show inline help.                                                                             |

---

## What Happens in Each Pass

### Pass 1 – Audit (SSH) *(unless `-pxe_only`)*

- Builds FQDN with `-domain_suffix`.
- **Presence check for `-audit_script`.**
  - If missing → node is queued for **Pass 2 (PXE)**.
- If present, runs the audit:

  ~~~powershell
  & "C:\management_scripts\pool_audit.ps1" `
     -git_hash <pool hash> `
     -worker_pool_id <pool name> `
     -image_name <pool image>
  ~~~

- **Behavior:**
  - Exit `0` → considered healthy (**unless output contains “bad” → PXE**).
  - Exit `255` → treated as SSH failure (re-attempt in Pass 3).
  - Any other exit code → **PXE** the node.

**Wait after Pass 1:**
- If Pass 2 is enabled, **5 seconds** (fixed).
- If Pass 2 is skipped, wait `-sleep_secs` (or **30s** with `-quick`).

---

### Pass 1 – PXE-only mode (`-pxe_only`)

- Skips audit and triggers PXE immediately on the selected node(s) in Pass 1.
- Pass 2 is skipped (because PXE already happened in Pass 1).
- Script proceeds to Pass 3 (retry SSH failures once).

---

### Pass 2 – PXE for missing-audit *(unless disabled)*

- PXEs nodes that were detected as missing the audit script in Pass 1.
- If any PXE actions succeed in Pass 2, the script **does not sleep** before Pass 3.

---

### Pass 3 – Retry SSH

- Retries the audit for nodes that had SSH failures (exit `255`) in earlier SSH operations.
- Uses the short hostname to find the node’s pool entry in YAML and reruns the audit with that pool’s parameters.

---

## PXE Triggering Details

When the script decides a node should PXE, it uses **two approaches**:

1. **File-based PXE (preferred)**
   - Stages a helper script to `-pxe_script` (default `C:\PXE\SetPXE.ps1`) via base64 write over SSH.
   - Invokes it over SSH with `-WipeD True|False`.

2. **Inline PXE fallback** *(no remote file required)*
   - If staging fails (but SSH works) **or** file-based invocation returns an unexpected result, the script runs the same PXE logic inline over SSH.

The PXE logic:
- Imports `Microsoft.Windows.Bcd.Cmdlets`.
- Searches firmware BCD entries for an item whose **Description matches `IPv4`**.
- Sets `{fwbootmgr}` **BOOTSEQUENCE** to that entry GUID.
- Optionally wipes `D:\*`.
- Reboots in 5 seconds (`shutdown /r /t 5 /f`).
- Prints `PXE_TRIGGERED` (used as the success indicator).

---

## Dry Run

When `-dry_run` is set:
- Audits and presence checks still run (unless `-pxe_only`).
- Any time the script *would* PXE a node, it prints:

  `DRY RUN: would trigger PXE (Wipe D: <True|False>)`

- No PXE helper is staged, no boot order is modified, no `D:\*` wipe is performed, and no reboot is triggered.
- The summary includes a list of nodes that **would have PXE’d**.

---

## PXE Throttling

To avoid rebooting too many nodes at once, the script applies a controller-side throttle:

- After **`-pxe_batch_size` successful PXE triggers** (default **10**), it sleeps **`-pxe_batch_sleep_secs` seconds** (default **60**), then continues.
- This applies across all passes (PXE-only mode, audit-triggered PXE, and missing-audit PXE).
- Only **successful** PXE triggers count toward the batch threshold (success is determined by seeing `PXE_TRIGGERED`).

---

## Output & Summary

At the end you’ll see lists of:

- Nodes **missing the audit script**
- Nodes where **PXE was triggered (SSH)**
- Nodes that used **inline PXE** (fallback)
- Nodes with **SSH failures** (after retry)
- Nodes that **recovered on retry**
- Nodes flagged as **wrong config**
- Nodes with **audit/script issues**
- Nodes that **would have PXE’d** (dry run)

The script may exit `96` if a requested single node is not found in YAML; otherwise it completes and summarizes results.

---

## Exit Codes

- `0` – Completed; see summary for per-node outcomes
- `96` – Single requested node not found in YAML

---

## Troubleshooting

- **YAML parsing**: If `ConvertFrom-Yaml` is missing, install/enable the YAML module/cmdlet appropriate for your PowerShell environment.
- **ExecutionPolicy**: Remote PowerShell is run as `-ExecutionPolicy Bypass`, so creating/invoking `C:\PXE\SetPXE.ps1` should not be blocked by policy.
- **No IPv4 PXE entry**: The PXE logic expects an IPv4 PXE entry in firmware. Check with `bcdedit /enum firmware`. If missing, PXE cannot be triggered.
- **SSH auth**: Verify keys/creds and that `sshd` is running on targets.
- **Firewall**: Ensure TCP/22 (SSH) from the controller to the nodes is allowed.
- **Timing**: After PXE is triggered, nodes will reboot quickly — don’t expect successful SSH immediately afterward.