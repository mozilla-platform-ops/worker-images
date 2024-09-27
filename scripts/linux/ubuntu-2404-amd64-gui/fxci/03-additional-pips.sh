#!/bin/bash

set -exv

## The warning error: externally-managed-environment popped up on 24.04 when trying to install zstandard using pip3
## The --break-system-packages flag is used to ignore the warning error
## Not sure if this will break other things
## fetch-content needs zstandard
pip3 install zstandard --break-system-packages