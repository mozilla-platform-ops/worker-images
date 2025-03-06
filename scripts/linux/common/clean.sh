#!/bin/bash

set -exv

rm -rf /usr/src/*

# Do one final package cleanup, just in case.
apt-get autoremove -y --purge
