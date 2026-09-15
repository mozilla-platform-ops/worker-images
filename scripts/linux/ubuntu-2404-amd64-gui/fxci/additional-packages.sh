#!/bin/bash

set -exv

# add additional packages

MISC_PACKAGES=()
# essentials
MISC_PACKAGES+=(build-essential curl git gnupg-agent jq mercurial)
# python things
MISC_PACKAGES+=(python3-pip python3-certifi python3-psutil)
# PyAutoGUI imports MouseInfo on Linux, which requires tkinter. Keep
# python3-dev available for packages that still need native extension headers.
MISC_PACKAGES+=(python3-tk python3-dev)
# Xlib events are not respected by Wayland even with Xwayland, so DTE tests
# drive input through Wayland directly. wtype handles keystrokes, xdotool
# covers the Xwayland path, and wayland-utils ships diagnostic helpers.
MISC_PACKAGES+=(wtype wayland-utils xdotool)
# zstd packages
MISC_PACKAGES+=(zstd python3-zstd)
# install zstandard to avoid installing via pip and breaking via PEP 668 https://peps.python.org/pep-0668/
MISC_PACKAGES+=(python3-zstandard)
MISC_PACKAGES+=(apt-transport-https ca-certificates software-properties-common)
# docker-worker needs this for unpacking lz4 images, perhaps uneeded but shouldn't hurt
MISC_PACKAGES+=(liblz4-tool)
# needed for runtests.py: error: Missing binary pactl required for --use-test-media-devices
MISC_PACKAGES+=(pulseaudio-utils)
# random bits
MISC_PACKAGES+=(libhunspell-1.7-0 libhunspell-dev)

apt-get -o Acquire::Retries=10 -o APT::Update::Error-Mode=any install -y "${MISC_PACKAGES[@]}"