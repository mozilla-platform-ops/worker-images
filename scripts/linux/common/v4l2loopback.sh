#!/bin/bash

set -exv

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

kernel_version=$(uname -r)
header_package="linux-headers-$kernel_version"

retry apt-get update
retry apt-get -y reinstall linux-headers-gcp $header_package

# Ubuntu's v4l2loopback-dkms package does not build with kernel 7.0.
# Install a current upstream release with DKMS.
V4L2LOOPBACK_VERSION=0.15.4
retry apt-get install -y dkms v4l2loopback-utils
retry curl -fsSL "https://github.com/v4l2loopback/v4l2loopback/archive/refs/tags/v${V4L2LOOPBACK_VERSION}.tar.gz" \
  -o /tmp/v4l2loopback.tar.gz
tar xz -C /usr/src -f /tmp/v4l2loopback.tar.gz
rm -f /tmp/v4l2loopback.tar.gz
dkms add -m v4l2loopback -v "${V4L2LOOPBACK_VERSION}"
dkms build -m v4l2loopback -v "${V4L2LOOPBACK_VERSION}" -k "$kernel_version"
dkms install -m v4l2loopback -v "${V4L2LOOPBACK_VERSION}" -k "$kernel_version"
# verify
dkms status

retry apt-get install linux-modules-extra-gcp -y

# Configure video loopback devices
echo "options v4l2loopback devices=$NUM_LOOPBACK_VIDEO_DEVICES" > /etc/modprobe.d/v4l2loopback.conf
echo "videodev" | tee --append /etc/modules
echo "v4l2loopback" | tee --append /etc/modules

# test the results

modprobe videodev
lsmod | grep videodev

modprobe v4l2loopback
lsmod | grep v4l2loopback
# currently failing... only 7 devices... /dev/video7
test -e /dev/video$((NUM_LOOPBACK_VIDEO_DEVICES - 1))

## snd-aloop is unused since virtual devices in pulseaudio/pipewire don't require a kernel component

# # Configure audio loopback devices, with options enable=1,1,1...,1 index = 0,1,...,N
# i=0
# enable=''
# index=''
# while [ $i -lt ${NUM_LOOPBACK_AUDIO_DEVICES} ]; do
#     enable="$enable,1"
#     index="$index,$i"
#     i=$((i + 1))
# done
# # slice off the leading `,` in each variable
# enable=${enable:1}
# index=${index:1}

# echo "options snd-aloop enable=$enable index=$index" > /etc/modprobe.d/snd-aloop.conf
# echo "snd-aloop" | tee --append /etc/modules

# # test
# modprobe snd-aloop
# lsmod | grep snd_aloop
# test -e /dev/snd/controlC$((NUM_LOOPBACK_AUDIO_DEVICES - 1))
