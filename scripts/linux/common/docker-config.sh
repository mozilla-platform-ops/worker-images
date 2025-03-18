#!/bin/sh

set -exv

# Configure docker to:
# 1) use /mnt for storage, which will be on fast ssds if available rather than
#    on the slower persistent drive
# 2) turn on ipv6
# 3) disable direct communication between containers
# 4) allow `unshare` syscall (bug 1938410)
# 5) allow `clone` syscall with CLONE_NEWIPC|CLONE_NEWUSER|CLONE_NEWNET
# 6) allow `get_mempolicy` syscall without CAP_SYS_NICE

cat << EOF > /etc/docker/daemon.json
{
  "data-root": "/mnt/var/lib/docker",
  "storage-driver": "overlay2",
  "seccomp-profile": "/etc/docker/seccomp.json",
  "ipv6": true,
  "fixed-cidr-v6": "fd15:4ba5:5a2b:100a::/64",
  "icc": false,
  "iptables": true
}
EOF

curl -f -L --retry 5 -o /etc/docker/seccomp.json https://github.com/moby/moby/raw/8701ff684fcb420751e8a018d4542a582295dd69/profiles/seccomp/default.json
patch /etc/docker/seccomp.json <<EOF
--- seccomp.json.orig	2025-03-13 10:38:57.624371088 +0100
+++ seccomp.json	2025-03-13 17:38:31.108879920 +0100
@@ -163,6 +163,7 @@
 				"getresuid",
 				"getresuid32",
 				"getrlimit",
+				"get_mempolicy",
 				"get_robust_list",
 				"getrusage",
 				"getsid",
@@ -398,6 +399,7 @@
 				"uname",
 				"unlink",
 				"unlinkat",
+				"unshare",
 				"utime",
 				"utimensat",
 				"utimensat_time64",
@@ -614,8 +616,7 @@
 				"setns",
 				"syslog",
 				"umount",
-				"umount2",
-				"unshare"
+				"umount2"
 			],
 			"action": "SCMP_ACT_ALLOW",
 			"includes": {
@@ -632,7 +633,7 @@
 			"args": [
 				{
 					"index": 0,
-					"value": 2114060288,
+					"value": 637665280,
 					"op": "SCMP_CMP_MASKED_EQ"
 				}
 			],
@@ -654,7 +655,7 @@
 			"args": [
 				{
 					"index": 1,
-					"value": 2114060288,
+					"value": 637665280,
 					"op": "SCMP_CMP_MASKED_EQ"
 				}
 			],
@@ -784,7 +785,6 @@
 		},
 		{
 			"names": [
-				"get_mempolicy",
 				"mbind",
 				"set_mempolicy",
 				"set_mempolicy_home_node"
EOF
