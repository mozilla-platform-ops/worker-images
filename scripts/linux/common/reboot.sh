#!/bin/bash

set -exv

# Activate package, module and service changes before image validation.
# A kernel upgrade is not required for this reboot.
shutdown -r now