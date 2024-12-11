#!/bin/sh

# https://bugs.launchpad.net/ubuntu/+source/apparmor/+bug/2046844
# The firefox sandbox relies on unprivileged user namespaces
echo 'kernel.apparmor_restrict_unprivileged_userns = 0' > /etc/sysctl.d/90-userns.conf
