#!/bin/bash
# Entry scripts select release binaries or compilation from a Taskcluster ref.
case "${1:-}" in
  release|source) build_mode="$1" ;;
  *) echo 'Expected release or source mode' >&2; exit 64 ;;
esac

set -exv
# exec &> /var/log/bootstrap.log
#exec > >(tee -a /var/log/bootstrap.log)

if [[ -z "${MY_CLOUD}" ]]; then
  echo "Error: MY_CLOUD environment variable not set. Expected one of: google, azure, aws." >&2
  exit 1
fi

if [[ "$build_mode" == source ]]; then
  TASKCLUSTER_REF="${TASKCLUSTER_REF:-main}"
  TASKCLUSTER_REPO='https://github.com/taskcluster/taskcluster'
else
    ## Get TASKCLUSTER_VERSION from the yaml file
    if [[ -z "${TASKCLUSTER_VERSION}" ]]; then
      echo "Error: TASKCLUSTER_VERSION environment variable not set." >&2
      exit 1
    fi

fi

start_time="$(date '+%s')"

case "$(uname -m)" in
  x86_64)
    ARCH=amd64
    ;;
  aarch64)
    ARCH=arm64
    ;;
  *)
    echo "Unsupported architecture '$(uname -m)' - currently bootstrap.sh only supports architectures x86_64 and aarch64" >&2
    exit 64
    ;;
esac
if [[ "$build_mode" == source ]]; then export ARCH; fi

apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any update
DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any upgrade -yq
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any remove -y docker docker.io containerd runc
# build-essential is needed for running `go test -race` with the -vet=off flag as of go1.19
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y apt-transport-https ca-certificates curl software-properties-common gzip python3-venv build-essential snapd crudini

# needed for kvm, see https://help.ubuntu.com/community/KVM/Installation
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils

# install docker
curl --fail --retry 10 --retry-all-errors -fsSL https://download.docker.com/linux/ubuntu/gpg -o /tmp/docker.asc
gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg /tmp/docker.asc
rm /tmp/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any update
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y docker-ce docker-ce-cli containerd.io
docker run --rm hello-world

# configure kvm vmware backdoor
# this enables a vmware compatible interface for kvm, and is needed for some fuzzing tasks
cat > /etc/modprobe.d/kvm-backdoor.conf << "EOF"
options kvm enable_vmware_backdoor=y
EOF

# configure core dumps to be in the process' current directory with filename 'core'
# (required for 3 legacy JS engine fuzzers)
echo "kernel.core_pattern = core" >> /etc/sysctl.d/90-custom.conf

# fix 'bugmon-process: error: rr needs /proc/sys/kernel/perf_event_paranoid <= 1, but it is 4'
echo 'kernel.perf_event_paranoid = 1' >> /etc/sysctl.d/90-custom.conf

# create group for running snap
groupadd snap_sudo
echo '%snap_sudo ALL=(ALL:ALL) NOPASSWD: /usr/bin/snap' | EDITOR='tee -a' visudo

if [[ "$build_mode" == source ]]; then
    # build generic-worker/livelog/start-worker/taskcluster-proxy from ${TASKCLUSTER_REF} commit / branch / tag etc
    apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y git tar
    curl --fail --retry 10 --retry-all-errors -fsSL 'https://dl.google.com/go/go1.26.0.linux-amd64.tar.gz' -o go.tar.gz
    tar xvfz go.tar.gz -C /usr/local
    export HOME=/root
    export GOPATH=~/go
    export GOROOT=/usr/local/go
    export PATH="${GOROOT}/bin:${GOPATH}/bin:${PATH}"
    export GCO_ENABLED=0
    git clone "${TASKCLUSTER_REPO}"
    cd taskcluster
    git checkout "${TASKCLUSTER_REF}"
    HEAD_REV="$(git rev-parse HEAD)"
    go build -tags multiuser -o "/usr/local/bin/generic-worker" -ldflags "-X main.revision=${HEAD_REV}" ./workers/generic-worker
    go build -o "/usr/local/bin/livelog" ./tools/livelog
    go build -o "/usr/local/bin/taskcluster-proxy" -ldflags "-X main.revision=${HEAD_REV}" ./tools/taskcluster-proxy
    go build -o "/usr/local/bin/start-worker" -ldflags "-X main.revision=${HEAD_REV}" ./tools/worker-runner/cmd/start-worker

else
    cd /usr/local/bin
    curl --fail --retry 10 --retry-all-errors -fsSL "https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/generic-worker-multiuser-linux-${ARCH}" -o generic-worker
    curl --fail --retry 10 --retry-all-errors -fsSL "https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/start-worker-linux-${ARCH}" -o start-worker
    curl --fail --retry 10 --retry-all-errors -fsSL "https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/livelog-linux-${ARCH}" -o livelog
    curl --fail --retry 10 --retry-all-errors -fsSL "https://github.com/taskcluster/taskcluster/releases/download/v${TASKCLUSTER_VERSION}/taskcluster-proxy-linux-${ARCH}" -o taskcluster-proxy
    chmod a+x generic-worker start-worker taskcluster-proxy livelog

fi

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
After=network-online.target

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
    providerType: ${MY_CLOUD}
worker:
    implementation: generic-worker
    path: /usr/local/bin/generic-worker
    configPath: /etc/generic-worker/config
cacheOverRestarts: /etc/start-worker-cache.json
EOF

systemctl enable worker

apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y ubuntu-desktop ubuntu-gnome-desktop podman gnome-initial-setup-

if [ "${MY_CLOUD}" == 'google' ]; then
    # this is neccessary in GCP because after installing gnome desktop both NetworkManager and systemd-networkd are enabled
    # which leads to https://bugs.launchpad.net/ubuntu/jammy/+source/systemd/+bug/2036358
    systemctl disable systemd-networkd-wait-online.service
fi

# set podman registries conf
(
  echo '[registries.search]'
  echo 'registries=["docker.io"]'
) >> /etc/containers/registries.conf

# v4l2loopback is out-of-tree and is not in linux-modules on kernel 7.0.
# Ubuntu's v4l2loopback-dkms package is too old to build against that
# kernel, so install a current upstream release via DKMS.
V4L2LOOPBACK_VERSION=0.15.4
apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y dkms "linux-headers-$(uname -r)"
curl --fail --retry 10 --retry-all-errors -fsSL "https://github.com/v4l2loopback/v4l2loopback/archive/refs/tags/v${V4L2LOOPBACK_VERSION}.tar.gz" \
  -o /tmp/v4l2loopback.tar.gz
tar xz -C /usr/src -f /tmp/v4l2loopback.tar.gz
rm -f /tmp/v4l2loopback.tar.gz
dkms add -m v4l2loopback -v "${V4L2LOOPBACK_VERSION}"
dkms build -m v4l2loopback -v "${V4L2LOOPBACK_VERSION}" -k "$(uname -r)"
dkms install -m v4l2loopback -v "${V4L2LOOPBACK_VERSION}" -k "$(uname -r)"
modprobe v4l2loopback
lsmod | grep v4l2loopback
echo 'v4l2loopback' >> /etc/modules

# needed for mutter to work with DRM rather than falling back to X11
grep -Fx vkms /etc/modules || echo vkms >> /etc/modules
# disable udev rule that tags platform-vkms with "mutter-device-ignore"
# ENV{ID_PATH}=="platform-vkms", TAG+="mutter-device-ignore"
sed '/platform-vkms/d' /lib/udev/rules.d/61-mutter.rules > /etc/udev/rules.d/61-mutter.rules

echo 'options snd-aloop enable=1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1 index=0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31' > /etc/modprobe.d/snd-aloop.conf
echo 'snd-aloop' >> /etc/modules

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
dconf update

#
# gdm3 settings
#
# in [daemon] block of /etc/gdm3/custom.conf we need:
#
# XorgEnable=false
crudini --set /etc/gdm3/custom.conf daemon XorgEnable 'false'

#
# gdm wait service file
#
# This hack is required because without we end up in a situation where the
# wayland seat is in a weird state and consequences are:
#    - either x11 session
#    - either xwayland fallback
#    - either wayland but with missing keyboard capability that breaks
#        things including copy/paste
mkdir -p /etc/systemd/system/gdm.service.d/
cat > /etc/systemd/system/gdm.service.d/gdm-wait.conf << EOF
[Unit]
Description=Extra 10s wait

[Service]
ExecStartPre=/bin/sleep 10
EOF

#
# write mutter's monitors.xml
#
cat > /etc/xdg/monitors.xml << EOF
<monitors version="2">
  <configuration>
    <logicalmonitor>
      <x>0</x>
      <y>0</y>
      <scale>1</scale>
      <primary>yes</primary>
      <monitor>
        <monitorspec>
          <connector>Virtual-1</connector>
          <vendor>unknown</vendor>
          <product>unknown</product>
          <serial>unknown</serial>
        </monitorspec>
        <mode>
          <width>1920</width>
          <height>1080</height>
          <rate>60.000</rate>
        </mode>
      </monitor>
    </logicalmonitor>
  </configuration>
</monitors>
EOF

# avoid unnecessary shutdowns during worker startups
systemctl disable unattended-upgrades

end_time="$(date '+%s')"
echo "UserData execution took: $(($end_time - $start_time)) seconds"

## Packer will handle the shutdown
# shutdown so that instance can be snapshotted
# shutdown -h now