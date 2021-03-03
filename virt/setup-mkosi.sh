#!/bin/bash

set -eu
set -o pipefail

BASE_DEPS=(
    dosfstools
    e2fsprogs
    git
    kernel-devel
    procps-ng # for pkill
    python38
    qemu-kvm
    rsync
    systemd-container
)

# Install necessary dependencies
dnf -q -y install "${BASE_DEPS[@]}"
alternatives --set python3 /usr/bin/python3.8
python3.8 -m ensurepip

# Fetch & install latest mkosi
if ! command -v mkosi; then
    python3.8 -m pip install --prefix=/usr git+https://github.com/systemd/mkosi.git
    mkosi --version
fi

# FIXME: CentOS/RHEL 8 systemd ships without faccessat() support, which breaks
#        systemd-nspawn images which use glibc > 2.33 (that implements faccessat()
#        via faccessat2()). Until this is fixed (planned for 8.5), let's use
#        a patched build from a COPR repository.
#
# See: https://copr.fedorainfracloud.org/coprs/mrc0mmand/systemd-el8-seccomp/
dnf -y install 'dnf-command(copr)'
dnf -y copr enable mrc0mmand/systemd-el8-seccomp
dnf -y upgrade systemd systemd-container
systemd-nspawn --version

# CentOS/RHEL 8 doesn't provide necessary Arch Linux bootstrap scripts (pacman,
# keyrings, etc.) as well as lacks zstd support in libarchive, which is mandatory,
# since all Arch packages use zstd. Let's install the necessary dependencies
# from a yet another custom COPR repository.
#
# See: https://copr.fedorainfracloud.org/coprs/mrc0mmand/archlinux-el8/
dnf -y copr enable mrc0mmand/archlinux-el8
dnf -y install arch-install-scripts libarchive
pacman --version

# CentOS/RHEL 8 ships only /usr/bin/qemu-kvm
! command -v qemu-kvm && ln -sv /usr/libexec/qemu-kvm /usr/bin/qemu-kvm
qemu-kvm --version

# We need systemd-networkd for mkosi to work properly
#
# 80-vm-vt.network was introduced in systemd v246, so let's add it manually
! rpm --quiet -q epel-release && dnf -y install epel-release
dnf -y install systemd-networkd
NETWORKD_DROPIN="/etc/systemd/network/80-vm-vt.network"
[[ ! -f "$NETWORKD_DROPIN" ]] && cat > "$NETWORKD_DROPIN" << EOF
[Match]
Name=vt-*
Driver=tun

[Network]
# Default to using a /28 prefix, giving up to 13 addresses per VM.
Address=0.0.0.0/28
LinkLocalAddressing=yes
DHCPServer=yes
IPMasquerade=yes
LLDP=yes
EmitLLDP=customer-bridge
IPv6PrefixDelegation=yes
EOF
systemctl start systemd-networkd
