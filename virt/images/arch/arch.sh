#!/bin/bash

set -eu
set -o pipefail

# Configure mirrors
#
# The default mirrorlist provides by pacman-mirrorlist has all mirrors commented
# out. Let's try to determine the top 5 best mirrors and use them.
#
# https://wiki.archlinux.org/index.php/mirrors#Fetching_and_ranking_a_live_mirror_list
rm -fv /etc/pacman.d/mirrorlist
for i in {0..4}; do
    curl -s "https://archlinux.org/mirrorlist/?country=FR&country=GB&protocol=https&use_mirror_status=on" | sed -e 's/^#Server/Server/' -e '/^#/d' | rankmirrors -n 5 - > /etc/pacman.d/mirrorlist && break
    sleep 10
done

cat /etc/pacman.d/mirrorlist

# Initialize pacman's keyring
pacman-key --init
pacman-key --populate archlinux
pacman --noconfirm -S archlinux-keyring
# Upgrade the system
pacman --noconfirm -Syu
# Install build dependencies
# Package groups: base, base-devel
pacman --needed --noconfirm -S base base-devel acl audit bash-completion clang compiler-rt docbook-xsl ethtool \
    git gnu-efi-libs gperf intltool iptables kexec-tools kmod libcap libelf libfido2 libgcrypt libidn2 \
    libmicrohttpd libpwquality libseccomp libutil-linux libxkbcommon libxslt linux-api-headers llvm llvm-libs lz4 meson ninja \
    p11-kit pam pcre2 python-lxml qrencode quota-tools tpm2-pkcs11 xz
# Install test dependencies
# Note: openbsd-netcat in favor of gnu-netcat is used intentionally, as
#       the GNU one doesn't support -U option required by test/TEST-12-ISSUE-3171
pacman --needed --noconfirm -S coreutils busybox dhclient dhcpcd diffutils dnsmasq e2fsprogs \
    gdb inetutils net-tools openbsd-netcat qemu rsync socat squashfs-tools strace vi

# Configure NTP (chronyd)
pacman --needed --noconfirm -S chrony
systemctl enable chronyd

# Disable brltty dracut module, since we don't need it and it causes weird issues
# in the generated images
mkdir -p /etc/dracut.conf.d
echo 'omit_dracutmodules+=" brltty "' >/etc/dracut.conf.d/99-disable-brltty.conf

# Compile & install libbpf-next
pacman --needed --noconfirm -S elfutils libelf
git clone https://github.com/libbpf/libbpf --depth=1
pushd libbpf/src
LD_FLAGS="-Wl,--no-as-needed" NO_PKG_CONFIG=1 make
make install
popd
rm -fr libbpf
