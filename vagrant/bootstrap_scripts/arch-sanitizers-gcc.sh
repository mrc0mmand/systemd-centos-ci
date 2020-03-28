#!/bin/bash

set -eu

whoami
uname -a

# The custom CentOS CI box should be updated and provide necessary
# build & test dependencies

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
pacman -Q > vagrant-arch-sanitizers-gcc-installed-pkgs.txt
# Dump additional OS info
cat <(echo "# CPUINFO") /proc/cpuinfo >> vagrant-arch-sanitizers-gcc-osinfo.txt
cat <(echo "# MEMINFO") /proc/meminfo >> vagrant-arch-sanitizers-gcc-osinfo.txt
cat <(echo "# VERSION") /proc/version >> vagrant-arch-sanitizers-gcc-osinfo.txt

rm -fr "$BUILD_DIR"
# Build phase
# Compile systemd with the Address Sanitizer (ASan) and Undefined Behavior
# Sanitizer (UBSan)
meson "$BUILD_DIR" \
      --werror \
      -Dc_args='-fno-omit-frame-pointer -ftrapv' \
      --buildtype=debug \
      --optimization=g \
      -Dtests=unsafe \
      -Dinstall-tests=true \
      -Ddbuspolicydir=/usr/share/dbus-1/system.d \
      -Dman=false \
      -Db_sanitize=address,undefined
ninja -C "$BUILD_DIR"

# Manually install upstream D-Bus config file for org.freedesktop.network1
# so systemd-networkd testsuite can use potentially new/updated methods
cp -fv src/network/org.freedesktop.network1.conf /usr/share/dbus-1/system.d/

# Manually install upstream systemd-networkd* service unit files in case a PR
# introduces a change in them
# See: https://github.com/systemd/systemd/pull/14415#issuecomment-579307925
cp -fv "$BUILD_DIR/units/systemd-networkd.service" /usr/lib/systemd/system/systemd-networkd.service
cp -fv "$BUILD_DIR/units/systemd-networkd-wait-online.service" /usr/lib/systemd/system/systemd-networkd-wait-online.service

popd
