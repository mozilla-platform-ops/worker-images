#!/bin/bash

set -exv

# to enable snap testing

# create group
groupadd snap_sudo

# add sudoers entry for the group
echo '%snap_sudo ALL=(ALL:ALL) NOPASSWD: /usr/bin/snap' | EDITOR='tee -a' visudo