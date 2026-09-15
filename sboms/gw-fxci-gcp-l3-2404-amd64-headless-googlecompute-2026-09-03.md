# Production deployment record

- Production image name: `gw-fxci-gcp-l3-2404-amd64-headless-googlecompute-2026-09-03`
- Alpha source image name: `gw-fxci-gcp-l3-2404-amd64-headless-googlecompute-alpha`
- Promotion timestamp: `2026-09-03T11:51:32Z`
- Promotion copied the alpha image without rebuilding the filesystem.
- SHA-256 of the unmodified alpha SBOM: `79502a3388d2231b6222b2313c029bd8044548e9b596322eaaefcb0ab703a049`

---
# Linux worker image SBOM

## Build provenance

- Image name: gw-fxci-gcp-l3-2404-amd64-headless-googlecompute-alpha
- Taskcluster version: 108.0.0
- Taskcluster ref: unknown
- Architecture: AMD64
- Source image family: ubuntu-2404-lts-amd64
- GCP project: fxci-production-level3-workers
- GCP zone: us-west1-a

## Operating system

- OS: Ubuntu 24.04.4 LTS (Noble Numbat)
- Kernel: Linux 6.17.0-1022-gcp x86_64 GNU/Linux
- Machine architecture: x86_64

## Taskcluster tools

| Name | Version |
| --- | --- |
| generic-worker | generic-worker (multiuser engine) 108.0.0 [ revision: https://github.com/taskcluster/taskcluster/commits/ae7697a5449cc29e7d41ae62ef6e5f725b929ed3 ] |
| start-worker | start-worker 108.0.0 |
| livelog | livelog 108.0.0 |
| taskcluster-proxy | Taskcluster proxy 108.0.0 (git revision ae7697a5449cc29e7d41ae62ef6e5f725b929ed3) |

## Python packages

| Name | Version |
| --- | --- |
| attrs | 23.2.0 |
| Automat | 22.10.0 |
| Babel | 2.10.3 |
| bcc | 0.29.1 |
| bcrypt | 3.2.2 |
| blinker | 1.7.0 |
| boto3 | 1.34.46 |
| botocore | 1.34.46 |
| certifi | 2023.11.17 |
| chardet | 5.2.0 |
| click | 8.1.6 |
| cloud-init | 26.1 |
| colorama | 0.4.6 |
| command-not-found | 0.3 |
| configobj | 5.0.8 |
| constantly | 23.10.4 |
| cryptography | 41.0.7 |
| dbus-python | 1.3.2 |
| distro | 1.9.0 |
| distro-info | 1.7+build1 |
| httplib2 | 0.20.4 |
| hyperlink | 21.0.0 |
| idna | 3.6 |
| incremental | 22.10.0 |
| Jinja2 | 3.1.2 |
| jmespath | 1.0.1 |
| jsonpatch | 1.32 |
| jsonpointer | 2.0 |
| jsonschema | 4.10.3 |
| launchpadlib | 1.11.0 |
| lazr.restfulclient | 0.14.6 |
| lazr.uri | 1.0.6 |
| markdown-it-py | 3.0.0 |
| MarkupSafe | 2.1.5 |
| mdurl | 0.1.2 |
| mercurial | 6.7.2 |
| netaddr | 0.8.0 |
| netifaces | 0.11.0 |
| oauthlib | 3.2.2 |
| packaging | 24.0 |
| pexpect | 4.9.0 |
| pip | 24.0 |
| psutil | 5.9.8 |
| ptyprocess | 0.7.0 |
| pyasn1 | 0.4.8 |
| pyasn1-modules | 0.2.8 |
| Pygments | 2.17.2 |
| PyGObject | 3.48.2 |
| PyHamcrest | 2.1.0 |
| PyJWT | 2.7.0 |
| pyOpenSSL | 23.2.0 |
| pyparsing | 3.1.1 |
| pyrsistent | 0.20.0 |
| pyserial | 3.5 |
| python-apt | 2.7.7+ubuntu5.2 |
| python-dateutil | 2.8.2 |
| python-debian | 0.1.49+ubuntu2 |
| python-magic | 0.4.27 |
| pytz | 2024.1 |
| PyYAML | 6.0.1 |
| requests | 2.31.0 |
| rich | 13.7.1 |
| s3transfer | 0.10.1 |
| service-identity | 24.1.0 |
| setuptools | 68.1.2 |
| six | 1.16.0 |
| sos | 4.10.2 |
| ssh-import-id | 5.11 |
| systemd-python | 235 |
| Twisted | 24.3.0 |
| typing_extensions | 4.10.0 |
| ubuntu-pro-client | 8001 |
| ufw | 0.36.2 |
| unattended-upgrades | 0.1 |
| urllib3 | 2.0.7 |
| wadllib | 1.3.6 |
| wheel | 0.42.0 |
| zope.interface | 6.1 |
| zstandard | 0.22.0 |
| zstd | 1.5.5.1 |

## dpkg packages

| Name | Version | Architecture |
| --- | --- | --- |
| adduser | 3.137ubuntu1 | all |
| apparmor | 4.0.1really4.0.1-0ubuntu0.24.04.7 | amd64 |
| apport | 2.28.3-0ubuntu0.1 | all |
| apport-core-dump-handler | 2.28.3-0ubuntu0.1 | all |
| apport-symptoms | 0.25 | all |
| appstream | 1.0.2-1build6 | amd64 |
| apt | 2.8.3 | amd64 |
| apt-transport-https | 2.8.3 | all |
| apt-utils | 2.8.3 | amd64 |
| base-files | 13ubuntu10.4 | amd64 |
| base-passwd | 3.6.3build1 | amd64 |
| bash | 5.2.21-2ubuntu4 | amd64 |
| bash-completion | 1:2.11-8 | all |
| bc | 1.07.1-3ubuntu4 | amd64 |
| bcache-tools | 1.0.8-5build1 | amd64 |
| bind9-dnsutils | 1:9.18.39-0ubuntu0.24.04.7 | amd64 |
| bind9-host | 1:9.18.39-0ubuntu0.24.04.7 | amd64 |
| bind9-libs:amd64 | 1:9.18.39-0ubuntu0.24.04.7 | amd64 |
| binutils | 2.42-4ubuntu2.10 | amd64 |
| binutils-common:amd64 | 2.42-4ubuntu2.10 | amd64 |
| binutils-x86-64-linux-gnu | 2.42-4ubuntu2.10 | amd64 |
| bpfcc-tools | 0.29.1+ds-1ubuntu7 | all |
| bpftrace | 0.20.2-1ubuntu4.3 | amd64 |
| bsdextrautils | 2.39.3-9ubuntu6.6 | amd64 |
| bsdutils | 1:2.39.3-9ubuntu6.6 | amd64 |
| btrfs-progs | 6.6.3-1.1build2 | amd64 |
| build-essential | 12.10ubuntu1 | amd64 |
| busybox-initramfs | 1:1.36.1-6ubuntu3.1 | amd64 |
| busybox-static | 1:1.36.1-6ubuntu3.1 | amd64 |
| byobu | 6.11-0ubuntu1.1 | all |
| bzip2 | 1.0.8-5.1ubuntu0.1 | amd64 |
| ca-certificates | 20260601~24.04.1 | all |
| chrony | 4.5-1ubuntu4.2 | amd64 |
| cloud-guest-utils | 0.33-1 | all |
| cloud-init | 26.1-0ubuntu1~24.04.1 | all |
| cloud-initramfs-copymods | 0.49~24.04.1 | all |
| cloud-initramfs-dyn-netconf | 0.49~24.04.1 | all |
| command-not-found | 23.04.0 | all |
| console-setup | 1.226ubuntu1.1 | all |
| console-setup-linux | 1.226ubuntu1.1 | all |
| containerd.io | 2.3.4-1~ubuntu.24.04~noble | amd64 |
| coreutils | 9.4-3ubuntu6.3 | amd64 |
| cpio | 2.15+dfsg-1ubuntu2.1 | amd64 |
| cpp | 4:13.2.0-7ubuntu1 | amd64 |
| cpp-13 | 13.3.0-6ubuntu2~24.04.1 | amd64 |
| cpp-13-x86-64-linux-gnu | 13.3.0-6ubuntu2~24.04.1 | amd64 |
| cpp-x86-64-linux-gnu | 4:13.2.0-7ubuntu1 | amd64 |
| cron | 3.0pl1-184ubuntu2 | amd64 |
| cron-daemon-common | 3.0pl1-184ubuntu2 | all |
| cryptsetup | 2:2.7.0-1ubuntu4.2 | amd64 |
| cryptsetup-bin | 2:2.7.0-1ubuntu4.2 | amd64 |
| cryptsetup-initramfs | 2:2.7.0-1ubuntu4.2 | all |
| curl | 8.5.0-2ubuntu10.13 | amd64 |
| dash | 0.5.12-6ubuntu5 | amd64 |
| dbus | 1.14.10-4ubuntu4.1 | amd64 |
| dbus-bin | 1.14.10-4ubuntu4.1 | amd64 |
| dbus-daemon | 1.14.10-4ubuntu4.1 | amd64 |
| dbus-session-bus-common | 1.14.10-4ubuntu4.1 | all |
| dbus-system-bus-common | 1.14.10-4ubuntu4.1 | all |
| dbus-user-session | 1.14.10-4ubuntu4.1 | amd64 |
| debconf | 1.5.86ubuntu1 | all |
| debconf-i18n | 1.5.86ubuntu1 | all |
| debianutils | 5.17build1 | amd64 |
| dhcpcd-base | 1:10.0.6-1ubuntu3.2 | amd64 |
| dictionaries-common | 1.29.7 | all |
| diffutils | 1:3.10-1ubuntu0.1 | amd64 |
| dirmngr | 2.4.4-2ubuntu17.4 | amd64 |
| distro-info | 1.7build1 | amd64 |
| distro-info-data | 0.72-0ubuntu0.24.04.1 | all |
| dkms | 3.0.11-1ubuntu13 | all |
| dmeventd | 2:1.02.185-3ubuntu3.2 | amd64 |
| dmidecode | 3.5-3ubuntu0.1 | amd64 |
| dmsetup | 2:1.02.185-3ubuntu3.2 | amd64 |
| docker-buildx-plugin | 0.37.0-1~ubuntu.24.04~noble | amd64 |
| docker-ce | 5:29.5.3-1~ubuntu.24.04~noble | amd64 |
| docker-ce-cli | 5:29.5.3-1~ubuntu.24.04~noble | amd64 |
| docker-ce-rootless-extras | 5:29.7.2-1~ubuntu.24.04~noble | amd64 |
| docker-compose-plugin | 5.5.0-1~ubuntu.24.04~noble | amd64 |
| dosfstools | 4.2-1.1build1 | amd64 |
| dpkg | 1.22.6ubuntu6.6 | amd64 |
| dpkg-dev | 1.22.6ubuntu6.6 | all |
| dracut-install | 060+5-1ubuntu3.3 | amd64 |
| e2fsprogs | 1.47.0-2.4~exp1ubuntu4.1 | amd64 |
| e2fsprogs-l10n | 1.47.0-2.4~exp1ubuntu4.1 | all |
| eatmydata | 131-1ubuntu1 | all |
| ed | 1.20.1-1 | amd64 |
| efibootmgr | 18-1build2 | amd64 |
| eject | 2.39.3-9ubuntu6.6 | amd64 |
| emacsen-common | 3.0.5 | all |
| ethtool | 1:6.7-1build1 | amd64 |
| fakeroot | 1.33-1 | amd64 |
| fdisk | 2.39.3-9ubuntu6.6 | amd64 |
| file | 1:5.45-3build1 | amd64 |
| finalrd | 9build1 | all |
| findutils | 4.9.0-5build1 | amd64 |
| fio | 3.36-1ubuntu0.1 | amd64 |
| fontconfig-config | 2.15.0-1.1ubuntu2 | amd64 |
| fonts-dejavu-core | 2.37-8 | all |
| fonts-dejavu-mono | 2.37-8 | all |
| fonts-ubuntu-console | 0.869+git20240321-0ubuntu1 | all |
| friendly-recovery | 0.2.42 | all |
| ftp | 20230507-2build3 | all |
| fuse3 | 3.14.0-5build1 | amd64 |
| g++ | 4:13.2.0-7ubuntu1 | amd64 |
| g++-13 | 13.3.0-6ubuntu2~24.04.1 | amd64 |
| g++-13-x86-64-linux-gnu | 13.3.0-6ubuntu2~24.04.1 | amd64 |
| g++-x86-64-linux-gnu | 4:13.2.0-7ubuntu1 | amd64 |
| gawk | 1:5.2.1-2ubuntu0.1 | amd64 |
| gcc | 4:13.2.0-7ubuntu1 | amd64 |
| gcc-13 | 13.3.0-6ubuntu2~24.04.1 | amd64 |
| gcc-13-base:amd64 | 13.3.0-6ubuntu2~24.04.1 | amd64 |
| gcc-13-x86-64-linux-gnu | 13.3.0-6ubuntu2~24.04.1 | amd64 |
| gcc-14-base:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| gcc-x86-64-linux-gnu | 4:13.2.0-7ubuntu1 | amd64 |
| gdisk | 1.0.10-1build1 | amd64 |
| gettext-base | 0.21-14ubuntu2 | amd64 |
| gir1.2-girepository-2.0:amd64 | 1.80.1-1 | amd64 |
| gir1.2-glib-2.0:amd64 | 2.80.0-6ubuntu3.8 | amd64 |
| gir1.2-packagekitglib-1.0 | 1.2.8-2ubuntu1.5 | amd64 |
| git | 1:2.43.0-1ubuntu7.3 | amd64 |
| git-man | 1:2.43.0-1ubuntu7.3 | all |
| gnupg | 2.4.4-2ubuntu17.4 | all |
| gnupg-agent | 2.4.4-2ubuntu17.4 | all |
| gnupg-l10n | 2.4.4-2ubuntu17.4 | all |
| gnupg-utils | 2.4.4-2ubuntu17.4 | amd64 |
| google-compute-engine | 20260121.00-0ubuntu1~24.04.0 | all |
| google-compute-engine-oslogin | 20260116.00-0ubuntu1~24.04.0 | amd64 |
| google-guest-agent | 20250116.00-0ubuntu1~24.04.4 | amd64 |
| google-osconfig-agent | 20251028.00-0ubuntu2~24.04.0 | amd64 |
| gpg | 2.4.4-2ubuntu17.4 | amd64 |
| gpg-agent | 2.4.4-2ubuntu17.4 | amd64 |
| gpg-wks-client | 2.4.4-2ubuntu17.4 | amd64 |
| gpgconf | 2.4.4-2ubuntu17.4 | amd64 |
| gpgsm | 2.4.4-2ubuntu17.4 | amd64 |
| gpgv | 2.4.4-2ubuntu17.4 | amd64 |
| grep | 3.11-4build1 | amd64 |
| groff-base | 1.23.0-3build2 | amd64 |
| grub-common | 2.12-1ubuntu7.3 | amd64 |
| grub-efi-amd64-bin | 2.12-1ubuntu7.3 | amd64 |
| grub-efi-amd64-signed | 1.202.5+2.12-1ubuntu7.3 | amd64 |
| grub-gfxpayload-lists | 0.7build2 | amd64 |
| grub-pc | 2.12-1ubuntu7.3 | amd64 |
| grub-pc-bin | 2.12-1ubuntu7.3 | amd64 |
| grub2-common | 2.12-1ubuntu7.3 | amd64 |
| gstreamer1.0-tools | 1.24.2-1ubuntu0.1 | amd64 |
| gzip | 1.12-1ubuntu3.2 | amd64 |
| hdparm | 9.65+ds-1build1 | amd64 |
| hostname | 3.23+nmu2ubuntu2 | amd64 |
| htop | 3.3.0-4build1 | amd64 |
| hunspell-en-us | 1:2020.12.07-2 | all |
| hwdata | 0.379-1 | all |
| ibverbs-providers:amd64 | 50.0-2ubuntu0.2 | amd64 |
| ieee-data | 20220827.1 | all |
| inetutils-telnet | 2:2.5-3ubuntu4.2 | amd64 |
| info | 7.1-3build2 | amd64 |
| init | 1.66ubuntu1 | amd64 |
| init-system-helpers | 1.66ubuntu1 | all |
| initramfs-tools | 0.142ubuntu25.8 | all |
| initramfs-tools-bin | 0.142ubuntu25.8 | amd64 |
| initramfs-tools-core | 0.142ubuntu25.8 | all |
| install-info | 7.1-3build2 | amd64 |
| iproute2 | 6.1.0-1ubuntu6.4 | amd64 |
| iptables | 1.8.10-3ubuntu2 | amd64 |
| iputils-ping | 3:20240117-1ubuntu0.1 | amd64 |
| iputils-tracepath | 3:20240117-1ubuntu0.1 | amd64 |
| iso-codes | 4.16.0-1 | all |
| javascript-common | 11+nmu1 | all |
| jq | 1.7.1-3ubuntu0.24.04.2 | amd64 |
| kbd | 2.6.4-2ubuntu2 | amd64 |
| keyboard-configuration | 1.226ubuntu1.1 | all |
| keyboxd | 2.4.4-2ubuntu17.4 | amd64 |
| klibc-utils | 2.0.13-4ubuntu0.2 | amd64 |
| kmod | 31+20240202-2ubuntu7.2 | amd64 |
| kpartx | 0.9.4-5ubuntu8.2 | amd64 |
| krb5-locales | 1.20.1-6ubuntu2.8 | all |
| landscape-common | 24.02-0ubuntu5.7 | amd64 |
| less | 590-2ubuntu2.1 | amd64 |
| libacl1:amd64 | 2.3.2-1build1.1 | amd64 |
| libaio1t64:amd64 | 0.3.113-6build1.1 | amd64 |
| libalgorithm-diff-perl | 1.201-1 | all |
| libalgorithm-diff-xs-perl:amd64 | 0.04-8build3 | amd64 |
| libalgorithm-merge-perl | 0.08-5 | all |
| libaom3:amd64 | 3.8.2-2ubuntu0.1 | amd64 |
| libapparmor1:amd64 | 4.0.1really4.0.1-0ubuntu0.24.04.7 | amd64 |
| libappstream5:amd64 | 1.0.2-1build6 | amd64 |
| libapt-pkg6.0t64:amd64 | 2.8.3 | amd64 |
| libargon2-1:amd64 | 0~20190702+dfsg-4build1 | amd64 |
| libasan8:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| libassuan0:amd64 | 2.5.6-1build1 | amd64 |
| libatm1t64:amd64 | 1:2.5.1-5.1build1 | amd64 |
| libatomic1:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| libattr1:amd64 | 1:2.5.2-1ubuntu0.1 | amd64 |
| libaudit-common | 1:3.1.2-2.1build1.1 | all |
| libaudit1:amd64 | 1:3.1.2-2.1build1.1 | amd64 |
| libbinutils:amd64 | 2.42-4ubuntu2.10 | amd64 |
| libblkid1:amd64 | 2.39.3-9ubuntu6.6 | amd64 |
| libboost-iostreams1.83.0:amd64 | 1.83.0-2.1ubuntu3.2 | amd64 |
| libboost-thread1.83.0:amd64 | 1.83.0-2.1ubuntu3.2 | amd64 |
| libbpf1:amd64 | 1:1.3.0-2build2 | amd64 |
| libbpfcc:amd64 | 0.29.1+ds-1ubuntu7 | amd64 |
| libbrotli1:amd64 | 1.1.0-2build2 | amd64 |
| libbsd0:amd64 | 0.12.1-1build1.1 | amd64 |
| libbz2-1.0:amd64 | 1.0.8-5.1ubuntu0.1 | amd64 |
| libc-bin | 2.39-0ubuntu8.8 | amd64 |
| libc-dev-bin | 2.39-0ubuntu8.8 | amd64 |
| libc-devtools | 2.39-0ubuntu8.8 | amd64 |
| libc6-dev:amd64 | 2.39-0ubuntu8.8 | amd64 |
| libc6:amd64 | 2.39-0ubuntu8.8 | amd64 |
| libcap-ng0:amd64 | 0.8.4-2build2 | amd64 |
| libcap2-bin | 1:2.66-5ubuntu2.4 | amd64 |
| libcap2:amd64 | 1:2.66-5ubuntu2.4 | amd64 |
| libcbor0.10:amd64 | 0.10.2-1.2ubuntu2 | amd64 |
| libcc1-0:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| libclang-cpp18 | 1:18.1.3-1ubuntu1 | amd64 |
| libclang1-18 | 1:18.1.3-1ubuntu1 | amd64 |
| libcom-err2:amd64 | 1.47.0-2.4~exp1ubuntu4.1 | amd64 |
| libcrypt-dev:amd64 | 1:4.4.36-4build1 | amd64 |
| libcrypt1:amd64 | 1:4.4.36-4build1 | amd64 |
| libcryptsetup12:amd64 | 2:2.7.0-1ubuntu4.2 | amd64 |
| libctf-nobfd0:amd64 | 2.42-4ubuntu2.10 | amd64 |
| libctf0:amd64 | 2.42-4ubuntu2.10 | amd64 |
| libcurl3t64-gnutls:amd64 | 8.5.0-2ubuntu10.13 | amd64 |
| libcurl4t64:amd64 | 8.5.0-2ubuntu10.13 | amd64 |
| libdaxctl1:amd64 | 77-2ubuntu2 | amd64 |
| libdb5.3t64:amd64 | 5.3.28+dfsg2-7 | amd64 |
| libdbus-1-3:amd64 | 1.14.10-4ubuntu4.1 | amd64 |
| libdebconfclient0:amd64 | 0.271ubuntu3 | amd64 |
| libdeflate0:amd64 | 1.19-1build1.1 | amd64 |
| libdevmapper-event1.02.1:amd64 | 2:1.02.185-3ubuntu3.2 | amd64 |
| libdevmapper1.02.1:amd64 | 2:1.02.185-3ubuntu3.2 | amd64 |
| libdpkg-perl | 1.22.6ubuntu6.6 | all |
| libdrm-common | 2.4.125-1ubuntu0.1~24.04.2 | all |
| libdrm2:amd64 | 2.4.125-1ubuntu0.1~24.04.2 | amd64 |
| libduktape207:amd64 | 2.7.0+tests-0ubuntu3 | amd64 |
| libdw1t64:amd64 | 0.190-1.1ubuntu0.1 | amd64 |
| libeatmydata1:amd64 | 131-1ubuntu1 | amd64 |
| libedit2:amd64 | 3.1-20230828-1build1 | amd64 |
| libefiboot1t64:amd64 | 38-3.1build1 | amd64 |
| libefivar1t64:amd64 | 38-3.1build1 | amd64 |
| libelf1t64:amd64 | 0.190-1.1ubuntu0.1 | amd64 |
| liberror-perl | 0.17029-2 | all |
| libestr0:amd64 | 0.1.11-1build1 | amd64 |
| libevdev2:amd64 | 1.13.1+dfsg-1build1 | amd64 |
| libevent-core-2.1-7t64:amd64 | 2.1.12-stable-9ubuntu2.1 | amd64 |
| libexpat1-dev:amd64 | 2.6.1-2ubuntu0.4 | amd64 |
| libexpat1:amd64 | 2.6.1-2ubuntu0.4 | amd64 |
| libext2fs2t64:amd64 | 1.47.0-2.4~exp1ubuntu4.1 | amd64 |
| libfakeroot:amd64 | 1.33-1 | amd64 |
| libfastjson4:amd64 | 1.2304.0-1build1 | amd64 |
| libfdisk1:amd64 | 2.39.3-9ubuntu6.6 | amd64 |
| libffi8:amd64 | 3.4.6-1build1 | amd64 |
| libfido2-1:amd64 | 1.14.0-1build3 | amd64 |
| libfile-fcntllock-perl | 0.22-4ubuntu5 | amd64 |
| libfontconfig1:amd64 | 2.15.0-1.1ubuntu2 | amd64 |
| libfreetype6:amd64 | 2.13.2+dfsg-1ubuntu0.1 | amd64 |
| libfribidi0:amd64 | 1.0.13-3build1 | amd64 |
| libfuse3-3:amd64 | 3.14.0-5build1 | amd64 |
| libgcc-13-dev:amd64 | 13.3.0-6ubuntu2~24.04.1 | amd64 |
| libgcc-s1:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| libgcrypt20:amd64 | 1.10.3-2ubuntu0.2 | amd64 |
| libgd3:amd64 | 2.3.3-9ubuntu5 | amd64 |
| libgdbm-compat4t64:amd64 | 1.23-5.1build1 | amd64 |
| libgdbm6t64:amd64 | 1.23-5.1build1 | amd64 |
| libgfapi0:amd64 | 11.1-4ubuntu0.1 | amd64 |
| libgfrpc0:amd64 | 11.1-4ubuntu0.1 | amd64 |
| libgfxdr0:amd64 | 11.1-4ubuntu0.1 | amd64 |
| libgirepository-1.0-1:amd64 | 1.80.1-1 | amd64 |
| libglib2.0-0t64:amd64 | 2.80.0-6ubuntu3.8 | amd64 |
| libglib2.0-bin | 2.80.0-6ubuntu3.8 | amd64 |
| libglib2.0-data | 2.80.0-6ubuntu3.8 | all |
| libglusterfs0:amd64 | 11.1-4ubuntu0.1 | amd64 |
| libgmp10:amd64 | 2:6.3.0+dfsg-2ubuntu6.1 | amd64 |
| libgnutls30t64:amd64 | 3.8.3-1.1ubuntu3.6 | amd64 |
| libgomp1:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| libgpg-error-l10n | 1.47-3build2.1 | all |
| libgpg-error0:amd64 | 1.47-3build2.1 | amd64 |
| libgpm2:amd64 | 1.20.7-11 | amd64 |
| libgprofng0:amd64 | 2.42-4ubuntu2.10 | amd64 |
| libgssapi-krb5-2:amd64 | 1.20.1-6ubuntu2.8 | amd64 |
| libgstreamer1.0-0:amd64 | 1.24.2-1ubuntu0.1 | amd64 |
| libheif-plugin-aomdec:amd64 | 1.17.6-1ubuntu4.8 | amd64 |
| libheif-plugin-aomenc:amd64 | 1.17.6-1ubuntu4.8 | amd64 |
| libheif1:amd64 | 1.17.6-1ubuntu4.8 | amd64 |
| libhogweed6t64:amd64 | 3.9.1-2.2build1.1 | amd64 |
| libhunspell-1.7-0:amd64 | 1.7.2+really1.7.2-10build3 | amd64 |
| libhunspell-dev:amd64 | 1.7.2+really1.7.2-10build3 | amd64 |
| libhwasan0:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| libibverbs1:amd64 | 50.0-2ubuntu0.2 | amd64 |
| libicu74:amd64 | 74.2-1ubuntu3.1 | amd64 |
| libidn2-0:amd64 | 2.3.7-2build1.1 | amd64 |
| libinih1:amd64 | 55-1ubuntu2 | amd64 |
| libintl-perl | 1.33-1build3 | all |
| libintl-xs-perl | 1.33-1build3 | amd64 |
| libip4tc2:amd64 | 1.8.10-3ubuntu2 | amd64 |
| libip6tc2:amd64 | 1.8.10-3ubuntu2 | amd64 |
| libisl23:amd64 | 0.26-3build1.1 | amd64 |
| libisns0t64:amd64 | 0.101-0.3build3 | amd64 |
| libitm1:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| libjansson4:amd64 | 2.14-2build2 | amd64 |
| libjbig0:amd64 | 2.1-6.1ubuntu2 | amd64 |
| libjpeg-turbo8:amd64 | 2.1.5-2ubuntu2 | amd64 |
| libjpeg8:amd64 | 8c-2ubuntu11 | amd64 |
| libjq1:amd64 | 1.7.1-3ubuntu0.24.04.2 | amd64 |
| libjs-jquery | 3.6.1+dfsg+~3.5.14-1 | all |
| libjs-sphinxdoc | 7.2.6-6 | all |
| libjs-underscore | 1.13.4~dfsg+~1.11.4-3 | all |
| libjson-c5:amd64 | 0.17-1build1 | amd64 |
| libk5crypto3:amd64 | 1.20.1-6ubuntu2.8 | amd64 |
| libkeyutils1:amd64 | 1.6.3-3build1 | amd64 |
| libklibc:amd64 | 2.0.13-4ubuntu0.2 | amd64 |
| libkmod2:amd64 | 31+20240202-2ubuntu7.2 | amd64 |
| libkrb5-3:amd64 | 1.20.1-6ubuntu2.8 | amd64 |
| libkrb5support0:amd64 | 1.20.1-6ubuntu2.8 | amd64 |
| libksba8:amd64 | 1.6.6-1build1 | amd64 |
| libldap-common | 2.6.10+dfsg-0ubuntu0.24.04.1 | all |
| libldap2:amd64 | 2.6.10+dfsg-0ubuntu0.24.04.1 | amd64 |
| liblerc4:amd64 | 4.0.0+ds-4ubuntu2 | amd64 |
| libllvm18:amd64 | 1:18.1.3-1ubuntu1 | amd64 |
| liblmdb0:amd64 | 0.9.31-1build1 | amd64 |
| liblocale-gettext-perl | 1.07-6ubuntu5 | amd64 |
| liblsan0:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| liblvm2cmd2.03:amd64 | 2.03.16-3ubuntu3.2 | amd64 |
| liblz4-1:amd64 | 1.9.4-1build1.1 | amd64 |
| liblz4-tool | 1.9.4-1build1.1 | all |
| liblzma5:amd64 | 5.6.1+really5.4.5-1ubuntu0.3 | amd64 |
| liblzo2-2:amd64 | 2.10-2build4 | amd64 |
| libmagic-mgc | 1:5.45-3build1 | amd64 |
| libmagic1t64:amd64 | 1:5.45-3build1 | amd64 |
| libmaxminddb0:amd64 | 1.9.1-1build1 | amd64 |
| libmd0:amd64 | 1.1.0-2build1.1 | amd64 |
| libmnl0:amd64 | 1.0.5-2build1 | amd64 |
| libmodule-find-perl | 0.16-2 | all |
| libmodule-scandeps-perl | 1.35-1ubuntu0.24.04.1 | all |
| libmount1:amd64 | 2.39.3-9ubuntu6.6 | amd64 |
| libmpc3:amd64 | 1.3.1-1build1.1 | amd64 |
| libmpfr6:amd64 | 4.2.1-1build1.1 | amd64 |
| libmspack0t64:amd64 | 0.11-1.1build1 | amd64 |
| libnbd0 | 1.20.0-1 | amd64 |
| libncurses6:amd64 | 6.4+20240113-1ubuntu2.2 | amd64 |
| libncursesw6:amd64 | 6.4+20240113-1ubuntu2.2 | amd64 |
| libndctl6:amd64 | 77-2ubuntu2 | amd64 |
| libnetfilter-conntrack3:amd64 | 1.0.9-6build1 | amd64 |
| libnetplan1:amd64 | 1.1.2-8ubuntu1~24.04.2 | amd64 |
| libnettle8t64:amd64 | 3.9.1-2.2build1.1 | amd64 |
| libnewt0.52:amd64 | 0.52.24-2ubuntu2 | amd64 |
| libnfnetlink0:amd64 | 1.0.2-2build1 | amd64 |
| libnftables1:amd64 | 1.0.9-1ubuntu0.1 | amd64 |
| libnftnl11:amd64 | 1.2.6-2build1 | amd64 |
| libnghttp2-14:amd64 | 1.59.0-1ubuntu0.4 | amd64 |
| libnl-3-200:amd64 | 3.7.0-0.3build1.1 | amd64 |
| libnl-genl-3-200:amd64 | 3.7.0-0.3build1.1 | amd64 |
| libnl-route-3-200:amd64 | 3.7.0-0.3build1.1 | amd64 |
| libnpth0t64:amd64 | 1.6-3.1build1 | amd64 |
| libnss-systemd:amd64 | 255.4-1ubuntu8.17 | amd64 |
| libntfs-3g89t64:amd64 | 1:2022.10.3-1.2ubuntu3.2 | amd64 |
| libnuma1:amd64 | 2.0.18-1ubuntu0.24.04.1 | amd64 |
| libnvme1t64 | 1.8-3ubuntu1 | amd64 |
| libonig5:amd64 | 6.9.9-1build1 | amd64 |
| libopeniscsiusr | 2.1.9-3ubuntu5.4 | amd64 |
| libp11-kit0:amd64 | 0.25.3-4ubuntu2.2 | amd64 |
| libpackagekit-glib2-18:amd64 | 1.2.8-2ubuntu1.5 | amd64 |
| libpam-cap:amd64 | 1:2.66-5ubuntu2.4 | amd64 |
| libpam-modules-bin | 1.5.3-5ubuntu5.7 | amd64 |
| libpam-modules:amd64 | 1.5.3-5ubuntu5.7 | amd64 |
| libpam-runtime | 1.5.3-5ubuntu5.7 | all |
| libpam-systemd:amd64 | 255.4-1ubuntu8.17 | amd64 |
| libpam0g:amd64 | 1.5.3-5ubuntu5.7 | amd64 |
| libparted2t64:amd64 | 3.6-4build1 | amd64 |
| libpcap0.8t64:amd64 | 1.10.4-4.1ubuntu3 | amd64 |
| libpci3:amd64 | 1:3.10.0-2build1 | amd64 |
| libpcre2-8-0:amd64 | 10.42-4ubuntu2.1 | amd64 |
| libperl5.38t64:amd64 | 5.38.2-3.2ubuntu0.4 | amd64 |
| libpipeline1:amd64 | 1.5.7-2 | amd64 |
| libplymouth5:amd64 | 24.004.60-1ubuntu7.2 | amd64 |
| libpmem1:amd64 | 1.13.1-1.1ubuntu2 | amd64 |
| libpmemobj1:amd64 | 1.13.1-1.1ubuntu2 | amd64 |
| libpng16-16t64:amd64 | 1.6.43-5ubuntu0.6 | amd64 |
| libpolkit-agent-1-0:amd64 | 124-2ubuntu1.24.04.3 | amd64 |
| libpolkit-gobject-1-0:amd64 | 124-2ubuntu1.24.04.3 | amd64 |
| libpopt0:amd64 | 1.19+dfsg-1build1 | amd64 |
| libproc-processtable-perl:amd64 | 0.636-1build3 | amd64 |
| libproc2-0:amd64 | 2:4.0.4-4ubuntu3.3 | amd64 |
| libpsl5t64:amd64 | 0.21.2-1.1build1 | amd64 |
| libpython3-dev:amd64 | 3.12.3-0ubuntu2.1 | amd64 |
| libpython3-stdlib:amd64 | 3.12.3-0ubuntu2.1 | amd64 |
| libpython3.12-dev:amd64 | 3.12.3-1ubuntu0.16 | amd64 |
| libpython3.12-minimal:amd64 | 3.12.3-1ubuntu0.16 | amd64 |
| libpython3.12-stdlib:amd64 | 3.12.3-1ubuntu0.16 | amd64 |
| libpython3.12t64:amd64 | 3.12.3-1ubuntu0.16 | amd64 |
| libquadmath0:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| librados2 | 19.2.3-0ubuntu0.24.04.3 | amd64 |
| librbd1 | 19.2.3-0ubuntu0.24.04.3 | amd64 |
| librdmacm1t64:amd64 | 50.0-2ubuntu0.2 | amd64 |
| libreadline8t64:amd64 | 8.2-4build1 | amd64 |
| libreiserfscore0t64 | 1:3.6.27-7.1build1 | amd64 |
| librtmp1:amd64 | 2.4+20151223.gitfa8646d.1-2build7 | amd64 |
| libsasl2-2:amd64 | 2.1.28+dfsg1-5ubuntu3.1 | amd64 |
| libsasl2-modules-db:amd64 | 2.1.28+dfsg1-5ubuntu3.1 | amd64 |
| libsasl2-modules:amd64 | 2.1.28+dfsg1-5ubuntu3.1 | amd64 |
| libseccomp2:amd64 | 2.5.5-1ubuntu3.1 | amd64 |
| libselinux1:amd64 | 3.5-2ubuntu2.1 | amd64 |
| libsemanage-common | 3.5-1build5 | all |
| libsemanage2:amd64 | 3.5-1build5 | amd64 |
| libsensors-config | 1:3.6.0-9build1 | all |
| libsensors5:amd64 | 1:3.6.0-9build1 | amd64 |
| libsepol2:amd64 | 3.5-2build1 | amd64 |
| libsframe1:amd64 | 2.42-4ubuntu2.10 | amd64 |
| libsgutils2-1.46-2:amd64 | 1.46-3ubuntu4 | amd64 |
| libsharpyuv0:amd64 | 1.3.2-0.4build3 | amd64 |
| libsigsegv2:amd64 | 2.14-1ubuntu2 | amd64 |
| libslang2:amd64 | 2.3.3-3build2 | amd64 |
| libsmartcols1:amd64 | 2.39.3-9ubuntu6.6 | amd64 |
| libsodium23:amd64 | 1.0.18-1ubuntu0.24.04.1 | amd64 |
| libsort-naturally-perl | 1.03-4 | all |
| libsqlite3-0:amd64 | 3.45.1-1ubuntu2.7 | amd64 |
| libss2:amd64 | 1.47.0-2.4~exp1ubuntu4.1 | amd64 |
| libssh-4:amd64 | 0.10.6-2ubuntu0.5 | amd64 |
| libssl3t64:amd64 | 3.0.13-0ubuntu3.15 | amd64 |
| libstdc++-13-dev:amd64 | 13.3.0-6ubuntu2~24.04.1 | amd64 |
| libstdc++6:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| libstemmer0d:amd64 | 2.2.0-4build1 | amd64 |
| libsystemd-shared:amd64 | 255.4-1ubuntu8.17 | amd64 |
| libsystemd0:amd64 | 255.4-1ubuntu8.17 | amd64 |
| libtasn1-6:amd64 | 4.19.0-3ubuntu0.24.04.2 | amd64 |
| libterm-readkey-perl | 2.38-2build4 | amd64 |
| libtext-charwidth-perl:amd64 | 0.04-11build3 | amd64 |
| libtext-iconv-perl:amd64 | 1.7-8build3 | amd64 |
| libtext-wrapi18n-perl | 0.06-10 | all |
| libtiff6:amd64 | 4.5.1+git230720-4ubuntu2.5 | amd64 |
| libtinfo6:amd64 | 6.4+20240113-1ubuntu2.2 | amd64 |
| libtirpc-common | 1.3.4+ds-1.1build1 | all |
| libtirpc3t64:amd64 | 1.3.4+ds-1.1build1 | amd64 |
| libtraceevent1-plugin:amd64 | 1:1.8.2-1ubuntu2.1 | amd64 |
| libtraceevent1:amd64 | 1:1.8.2-1ubuntu2.1 | amd64 |
| libtracefs1:amd64 | 1.8.0-1ubuntu1 | amd64 |
| libtsan2:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| libubsan1:amd64 | 14.2.0-4ubuntu2~24.04.1 | amd64 |
| libuchardet0:amd64 | 0.0.8-1build1 | amd64 |
| libudev1:amd64 | 255.4-1ubuntu8.17 | amd64 |
| libunistring5:amd64 | 1.1-2build1.1 | amd64 |
| libunwind8:amd64 | 1.6.2-3build1.1 | amd64 |
| liburcu8t64:amd64 | 0.14.0-3.1build1 | amd64 |
| libusb-1.0-0:amd64 | 2:1.0.27-1 | amd64 |
| libutempter0:amd64 | 1.2.1-3build1 | amd64 |
| libuuid1:amd64 | 2.39.3-9ubuntu6.6 | amd64 |
| libuv1t64:amd64 | 1.48.0-1.1build1 | amd64 |
| libv4l-0t64:amd64 | 1.26.1-4build3 | amd64 |
| libv4l2rds0t64:amd64 | 1.26.1-4build3 | amd64 |
| libv4lconvert0t64:amd64 | 1.26.1-4build3 | amd64 |
| libwebp7:amd64 | 1.3.2-0.4build3 | amd64 |
| libwrap0:amd64 | 7.6.q-33 | amd64 |
| libx11-6:amd64 | 2:1.8.7-1build1 | amd64 |
| libx11-data | 2:1.8.7-1build1 | all |
| libxau6:amd64 | 1:1.0.9-1build6 | amd64 |
| libxcb1:amd64 | 1.15-1ubuntu2 | amd64 |
| libxdmcp6:amd64 | 1:1.1.3-0ubuntu6 | amd64 |
| libxext6:amd64 | 2:1.3.4-1build2 | amd64 |
| libxkbcommon0:amd64 | 1.6.0-1build1 | amd64 |
| libxml2:amd64 | 2.9.14+dfsg-1.3ubuntu3.8 | amd64 |
| libxmlb2:amd64 | 0.3.24-1~ubuntu0.24.04.1 | amd64 |
| libxmlsec1t64-openssl:amd64 | 1.2.39-5build2 | amd64 |
| libxmlsec1t64:amd64 | 1.2.39-5build2 | amd64 |
| libxmuu1:amd64 | 2:1.1.3-3build2 | amd64 |
| libxpm4:amd64 | 1:3.5.17-1ubuntu0.24.04.1 | amd64 |
| libxslt1.1:amd64 | 1.1.39-0exp1ubuntu0.24.04.3 | amd64 |
| libxtables12:amd64 | 1.8.10-3ubuntu2 | amd64 |
| libxxhash0:amd64 | 0.8.2-2build1 | amd64 |
| libyaml-0-2:amd64 | 0.2.5-1build1 | amd64 |
| libzstd1:amd64 | 1.5.5+dfsg2-2build1.1 | amd64 |
| linux-base | 4.5ubuntu9+24.04.2 | all |
| linux-gcp | 6.17.0-1022.25 | amd64 |
| linux-gcp-6.17-headers-6.17.0-1022 | 6.17.0-1022.25 | amd64 |
| linux-gcp-6.17-tools-6.17.0-1022 | 6.17.0-1022.25 | amd64 |
| linux-headers-6.17.0-1022-gcp | 6.17.0-1022.25 | amd64 |
| linux-headers-gcp | 6.17.0-1022.25 | amd64 |
| linux-image-6.17.0-1022-gcp | 6.17.0-1022.25 | amd64 |
| linux-image-gcp | 6.17.0-1022.25 | amd64 |
| linux-libc-dev:amd64 | 6.8.0-138.138 | amd64 |
| linux-modules-6.17.0-1022-gcp | 6.17.0-1022.25 | amd64 |
| linux-modules-extra-6.17.0-1022-gcp | 6.17.0-1022.25 | amd64 |
| linux-modules-extra-gcp | 6.17.0-1022.25 | amd64 |
| linux-tools-6.17.0-1022-gcp | 6.17.0-1022.25 | amd64 |
| linux-tools-common | 6.8.0-138.138 | all |
| locales | 2.39-0ubuntu8.8 | all |
| login | 1:4.13+dfsg1-4ubuntu3.2 | amd64 |
| logrotate | 3.21.0-2build1 | amd64 |
| logsave | 1.47.0-2.4~exp1ubuntu4.1 | amd64 |
| lsb-release | 12.0-2 | all |
| lshw | 02.19.git.2021.06.19.996aaad9c7-2ubuntu0.24.04.1 | amd64 |
| lsof | 4.95.0-1build3 | amd64 |
| lto-disabled-list | 47 | all |
| lvm2 | 2.03.16-3ubuntu3.2 | amd64 |
| lxd-agent-loader | 0.7ubuntu0.1 | all |
| lxd-installer | 4ubuntu0.1 | all |
| lz4 | 1.9.4-1build1.1 | amd64 |
| make | 4.3-4.1build2 | amd64 |
| man-db | 2.12.0-4build2 | amd64 |
| manpages | 6.7-2 | all |
| manpages-dev | 6.7-2 | all |
| mawk | 1.3.4.20240123-1build1 | amd64 |
| mdadm | 4.3-1ubuntu2.1 | amd64 |
| media-types | 10.1.0 | all |
| mercurial | 6.7.2-1ubuntu2.2 | amd64 |
| mercurial-common | 6.7.2-1ubuntu2.2 | all |
| mokutil | 0.6.0-2build3 | amd64 |
| motd-news-config | 13ubuntu10.4 | all |
| mount | 2.39.3-9ubuntu6.6 | amd64 |
| mtr-tiny | 0.95-1.1ubuntu0.1 | amd64 |
| multipath-tools | 0.9.4-5ubuntu8.2 | amd64 |
| nano | 7.2-2ubuntu0.2 | amd64 |
| ncurses-base | 6.4+20240113-1ubuntu2.2 | all |
| ncurses-bin | 6.4+20240113-1ubuntu2.2 | amd64 |
| ncurses-term | 6.4+20240113-1ubuntu2.2 | all |
| needrestart | 3.6-7ubuntu4.5 | all |
| netbase | 6.4 | all |
| netcat-openbsd | 1.226-1ubuntu2 | amd64 |
| netplan-generator | 1.1.2-8ubuntu1~24.04.2 | amd64 |
| netplan.io | 1.1.2-8ubuntu1~24.04.2 | amd64 |
| networkd-dispatcher | 2.2.4-1 | all |
| nftables | 1.0.9-1ubuntu0.1 | amd64 |
| ntfs-3g | 1:2022.10.3-1.2ubuntu3.2 | amd64 |
| numactl | 2.0.18-1ubuntu0.24.04.1 | amd64 |
| nvme-cli | 2.8-1ubuntu0.1 | amd64 |
| open-iscsi | 2.1.9-3ubuntu5.4 | amd64 |
| open-vm-tools | 2:13.0.10-0ubuntu0.24.04.1 | amd64 |
| openssh-client | 1:9.6p1-3ubuntu13.18 | amd64 |
| openssh-server | 1:9.6p1-3ubuntu13.18 | amd64 |
| openssh-sftp-server | 1:9.6p1-3ubuntu13.18 | amd64 |
| openssl | 3.0.13-0ubuntu3.15 | amd64 |
| os-prober | 1.81ubuntu4 | amd64 |
| overlayroot | 0.49~24.04.1 | all |
| packagekit | 1.2.8-2ubuntu1.5 | amd64 |
| packagekit-tools | 1.2.8-2ubuntu1.5 | amd64 |
| packages-microsoft-prod | 1.2-ubuntu24.04 | all |
| parallel | 20231122+ds-1 | all |
| parted | 3.6-4build1 | amd64 |
| passwd | 1:4.13+dfsg1-4ubuntu3.2 | amd64 |
| pastebinit | 1.6.2-1 | all |
| patch | 2.7.6-7build3 | amd64 |
| pci.ids | 0.0~2024.03.31-1ubuntu0.1 | all |
| pciutils | 1:3.10.0-2build1 | amd64 |
| perl | 5.38.2-3.2ubuntu0.4 | amd64 |
| perl-base | 5.38.2-3.2ubuntu0.4 | amd64 |
| perl-modules-5.38 | 5.38.2-3.2ubuntu0.4 | all |
| pigz | 2.8-1 | amd64 |
| pinentry-curses | 1.2.1-3ubuntu5 | amd64 |
| plymouth | 24.004.60-1ubuntu7.2 | amd64 |
| plymouth-theme-ubuntu-text | 24.004.60-1ubuntu7.2 | amd64 |
| polkitd | 124-2ubuntu1.24.04.3 | amd64 |
| pollinate | 4.33-3.1ubuntu1.3 | all |
| powermgmt-base | 1.37ubuntu0.1 | all |
| powershell | 7.6.5-1.deb | amd64 |
| procps | 2:4.0.4-4ubuntu3.3 | amd64 |
| psmisc | 23.7-1build1 | amd64 |
| publicsuffix | 20231001.0357-0.1 | all |
| python-apt-common | 2.7.7ubuntu5.2 | all |
| python-babel-localedata | 2.10.3-3build1 | all |
| python3 | 3.12.3-0ubuntu2.1 | amd64 |
| python3-apport | 2.28.3-0ubuntu0.1 | all |
| python3-apt | 2.7.7ubuntu5.2 | amd64 |
| python3-attr | 23.2.0-2 | all |
| python3-automat | 22.10.0-2 | all |
| python3-babel | 2.10.3-3build1 | all |
| python3-bcrypt | 3.2.2-1build1 | amd64 |
| python3-blinker | 1.7.0-1 | all |
| python3-boto3 | 1.34.46+dfsg-1ubuntu1 | all |
| python3-botocore | 1.34.46+repack-1ubuntu1 | all |
| python3-bpfcc | 0.29.1+ds-1ubuntu7 | all |
| python3-certifi | 2023.11.17-1 | all |
| python3-cffi-backend:amd64 | 1.16.0-2build1 | amd64 |
| python3-chardet | 5.2.0+dfsg-1 | all |
| python3-click | 8.1.6-2 | all |
| python3-colorama | 0.4.6-4 | all |
| python3-commandnotfound | 23.04.0 | all |
| python3-configobj | 5.0.8-3 | all |
| python3-constantly | 23.10.4-1 | all |
| python3-cryptography | 41.0.7-4ubuntu0.4 | amd64 |
| python3-dateutil | 2.8.2-3ubuntu1 | all |
| python3-dbus | 1.3.2-5build3 | amd64 |
| python3-debconf | 1.5.86ubuntu1 | all |
| python3-debian | 0.1.49ubuntu2 | all |
| python3-dev | 3.12.3-0ubuntu2.1 | amd64 |
| python3-distro | 1.9.0-1 | all |
| python3-distro-info | 1.7build1 | all |
| python3-distupgrade | 1:24.04.28 | all |
| python3-gdbm:amd64 | 3.12.3-0ubuntu1 | amd64 |
| python3-gi | 3.48.2-1 | amd64 |
| python3-hamcrest | 2.1.0-1 | all |
| python3-httplib2 | 0.20.4-3ubuntu0.1 | all |
| python3-hyperlink | 21.0.0-5 | all |
| python3-idna | 3.6-2ubuntu0.2 | all |
| python3-incremental | 22.10.0-1 | all |
| python3-jinja2 | 3.1.2-1ubuntu1.3 | all |
| python3-jmespath | 1.0.1-1 | all |
| python3-json-pointer | 2.0-0ubuntu1 | all |
| python3-jsonpatch | 1.32-3 | all |
| python3-jsonschema | 4.10.3-2ubuntu1 | all |
| python3-jwt | 2.7.0-1ubuntu0.1 | all |
| python3-launchpadlib | 1.11.0-6 | all |
| python3-lazr.restfulclient | 0.14.6-1 | all |
| python3-lazr.uri | 1.0.6-3 | all |
| python3-magic | 2:0.4.27-3 | all |
| python3-markdown-it | 3.0.0-2 | all |
| python3-markupsafe | 2.1.5-1build2 | amd64 |
| python3-mdurl | 0.1.2-1 | all |
| python3-minimal | 3.12.3-0ubuntu2.1 | amd64 |
| python3-netaddr | 0.8.0-2ubuntu1 | all |
| python3-netifaces:amd64 | 0.11.0-2build3 | amd64 |
| python3-netplan | 1.1.2-8ubuntu1~24.04.2 | amd64 |
| python3-newt:amd64 | 0.52.24-2ubuntu2 | amd64 |
| python3-oauthlib | 3.2.2-1 | all |
| python3-openssl | 23.2.0-1ubuntu0.1 | all |
| python3-packaging | 24.0-1 | all |
| python3-pexpect | 4.9-2 | all |
| python3-pip | 24.0+dfsg-1ubuntu1.3 | all |
| python3-pip-whl | 24.0+dfsg-1ubuntu1.3 | all |
| python3-pkg-resources | 68.1.2-2ubuntu1.2 | all |
| python3-problem-report | 2.28.3-0ubuntu0.1 | all |
| python3-psutil | 5.9.8-2build2 | amd64 |
| python3-ptyprocess | 0.7.0-5 | all |
| python3-pyasn1 | 0.4.8-4ubuntu0.3 | all |
| python3-pyasn1-modules | 0.2.8-1 | all |
| python3-pygments | 2.17.2+dfsg-1 | all |
| python3-pyparsing | 3.1.1-1 | all |
| python3-pyrsistent:amd64 | 0.20.0-1build2 | amd64 |
| python3-requests | 2.31.0+dfsg-1ubuntu1.1 | all |
| python3-rich | 13.7.1-1 | all |
| python3-s3transfer | 0.10.1-1ubuntu2 | all |
| python3-serial | 3.5-2 | all |
| python3-service-identity | 24.1.0-1 | all |
| python3-setuptools | 68.1.2-2ubuntu1.2 | all |
| python3-setuptools-whl | 68.1.2-2ubuntu1.2 | all |
| python3-six | 1.16.0-4 | all |
| python3-software-properties | 0.99.49.4 | all |
| python3-systemd | 235-1build4 | amd64 |
| python3-twisted | 24.3.0-1ubuntu0.2 | all |
| python3-typing-extensions | 4.10.0-1 | all |
| python3-tz | 2024.1-2 | all |
| python3-update-manager | 1:24.04.12 | all |
| python3-urllib3 | 2.0.7-1ubuntu0.7 | all |
| python3-venv | 3.12.3-0ubuntu2.1 | amd64 |
| python3-wadllib | 1.3.6-5 | all |
| python3-wheel | 0.42.0-2 | all |
| python3-yaml | 6.0.1-2build2 | amd64 |
| python3-zope.interface | 6.1-1build1 | amd64 |
| python3-zstandard | 0.22.0-1build1 | amd64 |
| python3-zstd | 1.5.5.1-1build1 | amd64 |
| python3.12 | 3.12.3-1ubuntu0.16 | amd64 |
| python3.12-dev | 3.12.3-1ubuntu0.16 | amd64 |
| python3.12-minimal | 3.12.3-1ubuntu0.16 | amd64 |
| python3.12-venv | 3.12.3-1ubuntu0.16 | amd64 |
| readline-common | 8.2-4build1 | all |
| rpcsvc-proto | 1.4.2-0ubuntu7 | amd64 |
| rsync | 3.2.7-1ubuntu1.5 | amd64 |
| rsyslog | 8.2312.0-3ubuntu9.3 | amd64 |
| run-one | 1.17-0ubuntu2 | all |
| sbsigntool | 0.9.4-3.1ubuntu7 | amd64 |
| screen | 4.9.1-1ubuntu1 | amd64 |
| secureboot-db | 1.9build1 | amd64 |
| sed | 4.9-2ubuntu0.24.04.1 | amd64 |
| sensible-utils | 0.0.22 | all |
| sg3-utils | 1.46-3ubuntu4 | amd64 |
| sg3-utils-udev | 1.46-3ubuntu4 | all |
| sgml-base | 1.31 | all |
| shared-mime-info | 2.4-4 | amd64 |
| shim-signed | 1.58+15.8-0ubuntu1 | amd64 |
| snapd | 2.76.3+ubuntu24.04 | amd64 |
| software-properties-common | 0.99.49.4 | all |
| sosreport | 4.10.2-0ubuntu0~24.04.1 | amd64 |
| squashfs-tools | 1:4.6.1-1build1 | amd64 |
| ssh-import-id | 5.11-0ubuntu2.24.04.1 | all |
| strace | 6.8-0ubuntu2 | amd64 |
| sudo | 1.9.15p5-3ubuntu5.24.04.2 | amd64 |
| sysstat | 12.6.1-2 | amd64 |
| systemd | 255.4-1ubuntu8.17 | amd64 |
| systemd-dev | 255.4-1ubuntu8.17 | all |
| systemd-hwe-hwdb | 255.1.7 | all |
| systemd-resolved | 255.4-1ubuntu8.17 | amd64 |
| systemd-sysv | 255.4-1ubuntu8.17 | amd64 |
| sysvinit-utils | 3.08-6ubuntu3 | amd64 |
| tar | 1.35+dfsg-3ubuntu0.4 | amd64 |
| tcpdump | 4.99.4-3ubuntu4.24.04.1 | amd64 |
| telnet | 0.17+2.5-3ubuntu4.2 | all |
| thin-provisioning-tools | 0.9.0-2ubuntu5.1 | amd64 |
| time | 1.9-0.2build1 | amd64 |
| tmux | 3.4-1ubuntu0.1 | amd64 |
| tnftp | 20230507-2build3 | amd64 |
| trace-cmd | 3.2-1ubuntu2 | amd64 |
| tzdata | 2026c-0ubuntu0.24.04.1 | all |
| tzdata-legacy | 2026c-0ubuntu0.24.04.1 | all |
| ubuntu-kernel-accessories | 1.539.2 | amd64 |
| ubuntu-keyring | 2023.11.28.1 | all |
| ubuntu-minimal | 1.539.2 | amd64 |
| ubuntu-pro-client | 37.2ubuntu~24.04.1 | amd64 |
| ubuntu-pro-client-l10n | 37.2ubuntu~24.04.1 | amd64 |
| ubuntu-release-upgrader-core | 1:24.04.28 | all |
| ubuntu-server | 1.539.2 | amd64 |
| ubuntu-standard | 1.539.2 | amd64 |
| ucf | 3.0043+nmu1 | all |
| udev | 255.4-1ubuntu8.17 | amd64 |
| ufw | 0.36.2-6 | all |
| unattended-upgrades | 2.9.1+nmu4ubuntu1 | all |
| update-manager-core | 1:24.04.12 | all |
| update-notifier-common | 3.192.68.2 | all |
| usb.ids | 2024.03.18-1 | all |
| usbutils | 1:017-3build1 | amd64 |
| util-linux | 2.39.3-9ubuntu6.6 | amd64 |
| uuid-runtime | 2.39.3-9ubuntu6.6 | amd64 |
| v4l-utils | 1.26.1-4build3 | amd64 |
| v4l2loopback-dkms | 0.12.7-2ubuntu5.1 | all |
| v4l2loopback-utils | 0.12.7-2ubuntu5.1 | all |
| vim | 2:9.1.0016-1ubuntu7.20 | amd64 |
| vim-common | 2:9.1.0016-1ubuntu7.20 | all |
| vim-runtime | 2:9.1.0016-1ubuntu7.20 | all |
| vim-tiny | 2:9.1.0016-1ubuntu7.20 | amd64 |
| wget | 1.21.4-1ubuntu4.5 | amd64 |
| whiptail | 0.52.24-2ubuntu2 | amd64 |
| wireless-regdb | 2026.02.04-0ubuntu1~24.04.1 | all |
| xauth | 1:1.1.2-1build1 | amd64 |
| xdg-user-dirs | 0.18-1build1 | amd64 |
| xfsprogs | 6.6.0-1ubuntu2.1 | amd64 |
| xkb-data | 2.41-2ubuntu1.1 | all |
| xml-core | 0.19 | all |
| xxd | 2:9.1.0016-1ubuntu7.20 | amd64 |
| xz-utils | 5.6.1+really5.4.5-1ubuntu0.3 | amd64 |
| zerofree | 1.1.1-1build5 | amd64 |
| zlib1g-dev:amd64 | 1:1.3.dfsg-3.1ubuntu2.2 | amd64 |
| zlib1g:amd64 | 1:1.3.dfsg-3.1ubuntu2.2 | amd64 |
| zstd | 1.5.5+dfsg2-2build1.1 | amd64 |
