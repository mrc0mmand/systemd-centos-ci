#!/bin/bash

set -e

# Initialize pacman's keyring
pacman-key --init
pacman-key --populate archlinux
pacman --noconfirm -S archlinux-keyring
# Upgrade the system
pacman --noconfirm -Syu
# Install build dependencies
# Package groups: base, base-devel
pacman --needed --noconfirm -S base base-devel acl audit bash-completion clang compiler-rt docbook-xsl ethtool \
    git gnu-efi-libs gperf intltool iptables kexec-tools kmod libcap libelf libgcrypt libidn2 \
    libmicrohttpd libpwquality libseccomp libutil-linux libxkbcommon libxslt linux-api-headers llvm llvm-libs lz4 meson ninja \
    p11-kit pam pcre2 python-lxml quota-tools xz
# Install test dependencies
# Note: openbsd-netcat in favor of gnu-netcat is used intentionally, as
#       the GNU one doesn't support -U option required by test/TEST-12-ISSUE-3171
pacman --needed --noconfirm -S coreutils busybox dhclient dhcpcd diffutils dnsmasq e2fsprogs \
    gdb inetutils net-tools openbsd-netcat qemu rsync socat squashfs-tools strace vi

# Configure NTP (chronyd)
pacman --needed --noconfirm -S chrony
systemctl enable --now chronyd
systemctl status chronyd

# Compile & install libbpf-next
pacman --needed --noconfirm -S elfutils libelf
git clone https://github.com/libbpf/libbpf libbpf
pushd libbpf/src
LD_FLAGS="-Wl,--no-as-needed" NO_PKG_CONFIG=1 make
make install
popd
rm -fr libbpf

# Disable 'quiet' mode on the kernel command line and forward everything
# to ttyS0 instead of just tty0, so we can collect it using QEMU's
# -serial file:xxx feature
sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/ { s/quiet//; s/"$/ console=ttyS0"/ }' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

# Tell systemd-networkd to ignore eth0 netdev, so we can keep it up
# during the systemd-networkd testsuite
cat << EOF > /etc/systemd/network/eth0.network
[Match]
Name=eth0

[Link]
Unmanaged=yes
EOF
