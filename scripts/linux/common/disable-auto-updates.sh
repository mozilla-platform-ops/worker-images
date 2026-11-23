#!/bin/bash

# Workers are re-imaged, not patched. Turn off everything that would update
# packages or fetch update metadata on a running worker.
#
# Upgrades during a task are disruptive: needrestart restarts every service
# that maps a replaced library (including worker.service, killing the running
# task), and update downloads compete with tasks for CPU, disk, and network.
# https://github.com/taskcluster/community-tc-config/issues/1014

set -exv

# APT periodic jobs: unattended-upgrades, package list refresh, and downloads.
# Masking the timers alone would leave anything else that runs
# /usr/lib/apt/apt.systemd.daily free to upgrade, so zero the APT settings too.
cat > /etc/apt/apt.conf.d/99-worker-images-no-auto-updates << EOF
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF

# If something does upgrade packages, list stale services instead of
# restarting them.
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/99-worker-images.conf << 'EOF'
$nrconf{restart} = 'l';
EOF

# systemd units that upgrade packages or fetch update/news metadata. Not every
# unit exists on every image, so mask by name; masking a missing unit is fine.
units=(
  unattended-upgrades.service
  apt-daily.timer
  apt-daily.service
  apt-daily-upgrade.timer
  apt-daily-upgrade.service
  apt-news.service
  esm-cache.service
  ua-timer.timer
  ua-timer.service
  motd-news.timer
  motd-news.service
  update-notifier-download.timer
  update-notifier-motd.timer
  fwupd-refresh.timer
  fwupd-refresh.service
  packagekit-offline-update.service
  # Pulls and restarts containers labelled io.containers.autoupdate.
  podman-auto-update.timer
  podman-auto-update.service
  # Periodic background jobs that just compete with tasks for CPU and disk on
  # short-lived workers.
  man-db.timer
  dpkg-db-backup.timer
  e2scrub_all.timer
)
for unit in "${units[@]}"; do
  systemctl stop "$unit" || true
  systemctl mask "$unit"
done

# Hooks that run update checks (/usr/lib/update-notifier/apt-check, release
# upgrade checks) outside systemd: after every dpkg run, on every login (motd),
# from cron, and in the GNOME session. Divert them to *.disabled, which APT,
# run-parts, and XDG autostart all ignore, and which survives package upgrades.
hooks=(
  /etc/apt/apt.conf.d/99update-notifier
  /etc/update-motd.d/90-updates-available
  /etc/update-motd.d/91-release-upgrade
  /etc/update-motd.d/91-contract-ua-esm-status
  /etc/update-motd.d/95-hwe-eol
  /etc/cron.daily/update-notifier-common
  /etc/cron.weekly/update-notifier-common
  /etc/xdg/autostart/update-notifier.desktop
)
for hook in "${hooks[@]}"; do
  dpkg-divert --local --rename --divert "${hook}.disabled" --add "$hook"
done
pkill -x apt-check || true

# Ubuntu Pro client: no APT news or ESM advertising lookups.
if command -v pro > /dev/null; then
  pro config set apt_news=false || true
fi

# Snaps auto-refresh (and restart) on their own schedule; hold them forever.
if command -v snap > /dev/null; then
  snap refresh --hold
fi

# GNOME Software (GUI image) downloads and offers updates through PackageKit.
if [ -d /etc/dconf/db/local.d ]; then
  cat > /etc/dconf/db/local.d/10-tc-no-auto-updates << EOF
[org/gnome/software]
download-updates=false
download-updates-notify=false
allow-updates=false
first-run=false
EOF
  dconf update
fi
