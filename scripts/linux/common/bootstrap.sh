#!/bin/bash

set -exv

start_time="$(date '+%s')"


apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any update
DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any upgrade -yq
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any -y remove docker docker.io containerd runc
# build-essential is needed for running `go test -race` with the -vet=off flag as of go1.19
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y apt-transport-https ca-certificates curl software-properties-common gzip python3-venv build-essential

#apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils

# install docker
curl --fail --retry 10 --retry-all-errors -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.asc
gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg /tmp/docker.asc
rm /tmp/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any update
# Docker 29.7.x cannot load Kaniko-built Firefox task images containing
# absolute hardlink targets. Keep this pinned until moby/go-archive#100 ships
# in a Docker release: https://github.com/moby/go-archive/issues/99
DOCKER_VERSION='5:29.5.3-1~ubuntu.24.04~noble'
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y \
  "docker-ce=${DOCKER_VERSION}" \
  "docker-ce-cli=${DOCKER_VERSION}" \
  containerd.io
docker run --rm hello-world

# configure core dumps to be in the process' current directory with filename 'core'
# (required for 3 legacy JS engine fuzzers)
echo "kernel.core_pattern = core" >> /etc/sysctl.d/90-custom.conf

# fix 'bugmon-process: error: rr needs /proc/sys/kernel/perf_event_paranoid <= 1, but it is 4'
echo 'kernel.perf_event_paranoid = 1' >> /etc/sysctl.d/90-custom.conf

# create group for running snap
groupadd snap_sudo
echo '%snap_sudo ALL=(ALL:ALL) NOPASSWD: /usr/bin/snap' | EDITOR='tee -a' visudo

# instead of building from source, we can install the pre-built binary
cd /usr/local/bin
curl --fail --retry 10 --retry-all-errors -fsSL "https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/generic-worker-multiuser-linux-${TC_ARCH}" -o generic-worker
curl --fail --retry 10 --retry-all-errors -fsSL "https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/start-worker-linux-${TC_ARCH}" -o start-worker
curl --fail --retry 10 --retry-all-errors -fsSL "https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/livelog-linux-${TC_ARCH}" -o livelog
curl --fail --retry 10 --retry-all-errors -fsSL "https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/taskcluster-proxy-linux-${TC_ARCH}" -o taskcluster-proxy
chmod a+x generic-worker start-worker taskcluster-proxy livelog

mkdir -p /etc/generic-worker
mkdir -p /var/local/generic-worker
/usr/local/bin/generic-worker --version
/usr/local/bin/generic-worker new-ed25519-keypair --file /etc/generic-worker/ed25519_key

# ensure host 'taskcluster' resolves to localhost
echo 127.0.1.1 taskcluster >> /etc/hosts

# configure generic-worker to run on boot
cat > /lib/systemd/system/worker.service << EOF
[Unit]
Description=Start TC worker
# start once networking is online
Wants=network-online.target
After=network-online.target docker.service

[Service]
Type=simple
ExecStart=/usr/local/bin/start-worker /etc/start-worker.yml
# log to console to make output visible in cloud consoles, and syslog for ease of
# redirecting to external logging services
StandardOutput=journal+console
StandardError=journal+console
User=root

[Install]
RequiredBy=graphical.target
EOF

cat > /etc/start-worker.yml << EOF
provider:
    providerType: google
worker:
    implementation: generic-worker
    path: /usr/local/bin/generic-worker
    configPath: /etc/generic-worker/config
cacheOverRestarts: /etc/start-worker-cache.json
EOF

systemctl enable worker

#apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y podman
#apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y ubuntu-desktop ubuntu-gnome-desktop podman

# this is neccessary in GCP because after installing gnome desktop both NetworkManager and systemd-networkd are enabled
# which leads to https://bugs.launchpad.net/ubuntu/jammy/+source/systemd/+bug/2036358
systemctl disable systemd-networkd-wait-online.service

# avoid unnecessary shutdowns during worker startups
systemctl disable unattended-upgrades
systemctl disable apt-daily-upgrade.timer

end_time="$(date '+%s')"
echo "UserData execution took: $(($end_time - $start_time)) seconds"
