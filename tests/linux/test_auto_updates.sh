#!/bin/bash

# Verify disable-auto-updates.sh still holds after all later provisioning.

set -euxo pipefail

for unit in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service \
  motd-news.timer update-notifier-download.timer update-notifier-motd.timer \
  podman-auto-update.timer man-db.timer; do
  test "$(systemctl is-enabled "$unit" 2>/dev/null || true)" = masked
done

apt-config dump APT::Periodic | grep -Fx 'APT::Periodic::Unattended-Upgrade "0";'
apt-config dump APT::Periodic | grep -Fx 'APT::Periodic::Update-Package-Lists "0";'

if command -v snap > /dev/null; then
  snap refresh --time | grep -F 'hold: forever'
fi

# Nothing outside systemd should still run update-notifier's apt-check.
for hook in \
  /etc/apt/apt.conf.d/99update-notifier \
  /etc/update-motd.d/90-updates-available \
  /etc/update-motd.d/91-release-upgrade \
  /etc/xdg/autostart/update-notifier.desktop; do
  test ! -e "$hook"
done
if rg_out="$(grep -rlF apt-check /etc/apt/apt.conf.d /etc/update-motd.d /etc/cron.* /etc/xdg/autostart 2>/dev/null | grep -v '\.disabled$')"; then
  echo "apt-check still referenced by: $rg_out"
  exit 1
fi
