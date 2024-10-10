#!/bin/sh

# https://bugzilla.mozilla.org/show_bug.cgi?id=1922578
# ubuntu sets mmap_rnd_bits to 32, but tsan is not compatible with values >30,
# and docker doesn't let it disable ASLR entirely
echo 'vm.mmap_rnd_bits = 28' > /etc/sysctl.d/90-aslr.conf
