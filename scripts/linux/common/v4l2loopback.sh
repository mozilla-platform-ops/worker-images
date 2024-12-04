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

retry apt-get install -y v4l2loopback-dkms v4l2loopback-utils
# verify
dkms status

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