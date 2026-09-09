#!/bin/bash

set -exv

# needed for fxci talos/raptor tests

# no apt/deb prompts
export DEBIAN_FRONTEND=noninteractive

#
# install kernel headers
#

# problem: broken symlinks in directory below
#   ls -la ls /usr/src/linux-headers-5.15.0-1030-gcp
# fix:
#   sudo apt reinstall linux-gcp-headers-5.15.0-1030
#
# ensure kernel headers are present so dkms works
# - had issue where there were broken symlinks

kernel_version=$(uname -r)
header_package="linux-headers-$kernel_version"

sudo apt-get update
sudo apt-get -y reinstall linux-headers-gcp $header_package
#
# apt packages
#

# pre-reqs
apt-get install -y dkms kmod llvm sox libxcb1 nodejs xvfb apt-utils
# not working: linux-headers
# missing: lib32ncurses5 gstreamer


#
# enable v4loopback
#

# Required in GCP.
apt-get install linux-modules-extra-gcp -y

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


#
# configure audio loopback devices
#

# Configure audio loopback devices, with options enable=1,1,1...,1 index = 0,1,...,N
i=0
enable=''
index=''
while [ $i -lt ${NUM_LOOPBACK_AUDIO_DEVICES} ]; do
    enable="$enable,1"
    index="$index,$i"
    i=$((i + 1))
done
# slice off the leading `,` in each variable
enable=${enable:1}
index=${index:1}

echo "options snd-aloop enable=$enable index=$index" > /etc/modprobe.d/snd-aloop.conf
echo "snd-aloop" | tee --append /etc/modules

# test
modprobe snd-aloop
lsmod | grep snd_aloop
test -e /dev/snd/controlC$((NUM_LOOPBACK_AUDIO_DEVICES - 1))

#
# directories expected by talos
#
dirs="/builds /builds/slave /builds/slave/talos-data /builds/slave/talos-data/talos \
  /builds/git-shared /builds/hg-shared /builds/tooltool_cache"

mkdir -p $dirs
# task user changes... set to root for now
chown -R root:root $dirs
chmod -R 0777 $dirs

# test
ls -lad $dirs
