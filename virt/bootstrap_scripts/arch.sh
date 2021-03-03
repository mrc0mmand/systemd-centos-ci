#!/bin/bash
# shellcheck disable=SC2155

set -eu
set -o pipefail

whoami
uname -a

# Use systemd repo path specified by SYSTEMD_ROOT
pushd /build

# Dump list of installed packages
pacman -Q > arch-installed-pkgs.txt
# Dump additional system info
{
    echo "### CPUINFO ###"
    cat /proc/cpuinfo
    echo "### MEMINFO ###"
    cat /proc/meminfo
    echo "### VERSION ###"
    cat /proc/version
} > arch-system-info.txt

rm -fr build
# Build phase
meson build \
      --werror \
      -Dc_args='-fno-omit-frame-pointer -ftrapv' \
      -Ddebug=true \
      --optimization=g \
      -Dfexecve=true \
      -Dslow-tests=true \
      -Dfuzz-tests=true \
      -Dtests=unsafe \
      -Dinstall-tests=true \
      -Ddbuspolicydir=/usr/share/dbus-1/system.d \
      -Dman=true \
      -Dhtml=true
ninja -C build
ninja -C build install

# Make sure the revision we just compiled is actually bootable
(
    # Enable as much debug logging as we can to make debugging easier
    # (especially for boot issues)
    export KERNEL_APPEND="debug systemd.log_level=debug systemd.log_target=console"
    export QEMU_TIMEOUT=600
    # Skip the nspawn version of the test
    export TEST_NO_NSPAWN=1
    # Enforce nested KVM
    export TEST_NESTED_KVM=1

    make -C test/TEST-01-BASIC clean setup run clean-again

    #rm -f "$INITRD"
) 2>&1 | tee arch-sanity-boot-check.log

popd
