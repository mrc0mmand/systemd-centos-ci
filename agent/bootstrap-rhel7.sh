#!/usr/bin/bash
# shellcheck disable=SC2155

LIB_ROOT="$(dirname "$0")/../common"
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "bootstrap-logs-rhel7" || exit 1
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1

REMOTE_REF=""

# EXIT signal handler
at_exit() {
    # Let's collect some build-related logs
    set +e
    rsync -amq /var/tmp/systemd-test*/journal "$LOGDIR" &>/dev/null || :
    exectask "journalctl-bootstrap" "journalctl -b --no-pager"
    exectask "list-of-installed-packages" "rpm -qa"
}

set -eu
set -o pipefail

trap at_exit EXIT

# Parse optional script arguments
# Note: in RHEL7 version of the bootstrap script this is kind of pointless
#       (since it's parsing only a single option), but it allows us to have
#       a single interface in agent-control.py for all RHEL versions without
#       additional hassle
while getopts "r:" opt; do
    case "$opt" in
        r)
            REMOTE_REF="$OPTARG"
            ;;
        ?)
            exit 1
            ;;
        *)
            echo "Usage: $0 [-r REMOTE_REF]"
            exit 1
    esac
done

# Install necessary dependencies
# - systemd-* packages are necessary for correct users/groups to be created
cmd_retry yum -y install systemd-journal-gateway systemd-resolved rpm-build yum-utils net-tools strace nc busybox e2fsprogs quota dnsmasq qemu-kvm
cmd_retry yum-builddep -y systemd

# Fetch the downstream systemd repo
test -e systemd && rm -rf systemd
git clone https://github.com/redhat-plumbers/systemd-rhel7 systemd
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

git_checkout_pr "$REMOTE_REF"

# It's impossible to keep the local SELinux policy database up-to-date with
# arbitrary pull request branches we're testing against.
# Disable SELinux on the test hosts and avoid false positives.
if setenforce 0; then
    echo SELINUX=disabled >/etc/selinux/config
fi

# Compile systemd
(
    ./autogen.sh
    CONFIGURE_OPTS=(
        --with-sysvinit-path=/etc/rc.d/init.d
        --with-rc-local-script-path-start=/etc/rc.d/rc.local
        --disable-timesyncd
        --disable-kdbus
        --disable-terminal
        --enable-gtk-doc
        --enable-compat-libs
        --disable-sysusers
        --disable-ldconfig
        --enable-lz4
    )
    ./configure "${CONFIGURE_OPTS[@]}"
    make -j "$(nproc)"
    make install
) 2>&1 | tee "$LOGDIR/build.log"

# Let's check if the new systemd at least boots before rebooting the system
(
    # Ensure the initrd contains the same systemd version as the one we're
    # trying to test
    dracut -f --filesystems "xfs ext4"

    centos_ensure_qemu_symlink

    ## Configure test environment
    # Explicitly set paths to initramfs and kernel images (for QEMU tests)
    export INITRD="/boot/initramfs-$(uname -r).img"
    export KERNEL_BIN="/boot/vmlinuz-$(uname -r)"
    # Set timeout for QEMU tests to kill them in case they get stuck
    export QEMU_TIMEOUT=600
    # Disable nspawn version of the test
    export TEST_NO_NSPAWN=1

    if ! make -C test/TEST-01-BASIC clean setup run clean; then
        rsync -amq /var/tmp/systemd-test*/journal "$LOGDIR/" &>/dev/null || :
    fi
) 2>&1 | tee "$LOGDIR/sanity-boot-check.log"

echo "-----------------------------"
echo "- REBOOT THE MACHINE BEFORE -"
echo "-         CONTINUING        -"
echo "-----------------------------"
