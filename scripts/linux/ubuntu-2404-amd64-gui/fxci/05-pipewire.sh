#!/bin/bash

set -exv

# enable audiotestsrc plugin in pipewire config
# used by gecko media tests to create dummy sound sources
sed -e '/^context.spa-libs = {/,/^}$/ s/#\(audiotestsrc\)/\1/' /usr/share/pipewire/pipewire.conf > /etc/pipewire/pipewire.conf
