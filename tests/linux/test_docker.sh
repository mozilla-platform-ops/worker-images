#!/bin/bash

set -exv

## Make sure docker can run a container and it didn't mess up during the packer vm build
docker run --rm hello-world