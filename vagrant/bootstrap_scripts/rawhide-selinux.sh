#!/bin/bash
# Vagrant provider for a standard systemd setup

set -eu
set -o pipefail

whoami
uname -a

# Do a system upgrade
dnf upgrade --refresh -y

journalctl -b --no-pager

# Let's make the $BUILD_DIR for meson reside outside of the NFS volume mounted
# under /build to avoid certain race conditions, like:
# /usr/bin/ld: error: /build/build/src/udev/libudev.so.1: file too short
# The same path must be exported in the respective tests scripts (vagrant-test.sh,
# etc.) so the unit & integration tests can find the compiled binaries
# Note: avoid using /tmp or /var/tmp, as certain tests use binaries from the
#       buildir in combination with PrivateTmp=true
export BUILD_DIR="${BUILD_DIR:-/systemd-meson-build}"

# Use systemd repo path specified by SYSTEMD_ROOT
pushd /build

# Dump list of installed packages
rpm -qa > vagrant-rawhide-installed-pkgs.txt
# Dump additional OS info
{
    echo "### CPUINFO ###"
    cat /proc/cpuinfo
    echo "### MEMINFO ###"
    cat /proc/meminfo
    echo "### VERSION ###"
    cat /proc/version
} > vagrant-rawhide-osinfo.txt

rm -fr "$BUILD_DIR"
# Build phase
meson "$BUILD_DIR" \
      --werror \
      -Dc_args='-fno-omit-frame-pointer -ftrapv' \
      -Ddebug=true \
      --optimization=g \
      -Dtests=true \
      -Dinstall-tests=true
ninja -C "$BUILD_DIR" install

popd

# Install the latest SELinux policy
fedpkg clone -a selinux-policy
pushd selinux-policy
dnf -y builddep selinux-policy.spec
./make-rhat-patches.sh
fedpkg local
dnf install -y noarch/selinux-policy-*
popd

# Switch SELinux to permissive mode after reboot, so we catch all possible
# AVCs, not just the first one
sed -ri 's/^SELINUX=\w+$/SELINUX=permissive/' /etc/selinux/config
cat /etc/selinux/config

! command -v grubby && dnf -y install grubby
grubby --args='systemd.log_level=debug systemd.log_target=console' --update-kernel=ALL
