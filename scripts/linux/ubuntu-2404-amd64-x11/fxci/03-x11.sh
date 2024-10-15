#!/bin/bash

set -exv

# init helpers
function retry {
  set +e
  local n=0
  local max=10
  while true; do
    "$@" && break || {
      if [[ $n -lt $max ]]; then
        ((n++))
        echo "Command failed" >&2
        sleep_time=$((2 ** n))
        echo "Sleeping $sleep_time seconds..." >&2
        sleep $sleep_time
        echo "Attempt $n/$max:" >&2
      else
        echo "Failed after $n attempts." >&2
        exit 1
      fi
    }
  done
  set -e
}

#
# dconf settings
#

cat > /etc/dconf/profile/user << EOF
user-db:user
system-db:local
EOF

mkdir /etc/dconf/db/local.d/
# dconf user settings
cat > /etc/dconf/db/local.d/00-tc-gnome-settings << EOF
# /org/gnome/desktop/session/idle-delay
[org/gnome/desktop/session]
idle-delay=uint32 0

# /org/gnome/desktop/lockdown/disable-lock-screen
[org/gnome/desktop/lockdown]
disable-lock-screen=true
EOF

# make dbus read the new configuration
sudo dconf update

# test
ls -hal /etc/dconf/db/

# used to modify specific blocks in .conf files
apt install -y crudini

# in [daemon] block of /etc/gdm3/custom.conf we need:
#
# WaylandEnable=false

crudini --set /etc/gdm3/custom.conf daemon WaylandEnable 'false'

# verify/test
cat /etc/gdm3/custom.conf
echo "----"
grep 'WaylandEnable' /etc/gdm3/custom.conf
grep 'WaylandEnable' /etc/gdm3/custom.conf | grep false
