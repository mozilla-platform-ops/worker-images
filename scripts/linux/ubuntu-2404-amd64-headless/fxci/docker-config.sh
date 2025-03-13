#!/bin/sh

set -exv

# Configure docker to:
# 1) use /mnt for storage, which will be on fast ssds if available rather than
#    on the slower persistent drive
# 2) turn on ipv6
# 3) disable direct communication between containers
# 4) allow `unshare` syscall (bug 1938410)

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
--- default.json.orig	2025-03-13 10:38:57.624371088 +0100
+++ default.json	2025-03-13 10:39:36.060907381 +0100
@@ -398,6 +398,7 @@
 				"uname",
 				"unlink",
 				"unlinkat",
+				"unshare",
 				"utime",
 				"utimensat",
 				"utimensat_time64",
@@ -614,8 +615,7 @@
 				"setns",
 				"syslog",
 				"umount",
-				"umount2",
-				"unshare"
+				"umount2"
 			],
 			"action": "SCMP_ACT_ALLOW",
 			"includes": {
EOF
