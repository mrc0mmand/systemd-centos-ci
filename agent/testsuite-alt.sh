#!/usr/bin/bash
# shellcheck disable=SC2155

BUILD_DIR="build"
LIB_ROOT="$(dirname "$0")/../common"
# shellcheck source=common/task-control.sh
. "$LIB_ROOT/task-control.sh" "testsuite-logs-upstream-$(uname -m)" || exit 1
# shellcheck source=common/utils.sh
. "$LIB_ROOT/utils.sh" || exit 1

# EXIT signal handler
at_exit() {
    set +e
    exectask "journalctl-testsuite" "journalctl -b --no-pager"
}

trap at_exit EXIT

### SETUP PHASE ###
# Exit on error in the setup phase
set -eu

# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

if [[ ! -f /usr/bin/ninja ]]; then
    ln -s /usr/bin/ninja-build /usr/bin/ninja
fi

set +e

### TEST PHASE ###
pushd systemd || { echo >&2 "Can't pushd to systemd"; exit 1; }

## Sanitizer-specific options
# FIXME: handle_ioctl=1 fails on ppc64le with:
#   WARNING: failed decoding unknown ioctl 0x5437
export ASAN_OPTIONS=strict_string_checks=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1:detect_invalid_pointer_pairs=2:print_cmdline=1
export UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1

# Run the internal unit tests (make check)
#   - bump the timeout multiplier, since the alt-arch machines are emulated
#     and we're running the sanitized build
#exectask "ninja-test_sanitizers_$(uname -m)" "meson test -C $BUILD_DIR --print-errorlogs --timeout-multiplier=5"
#exectask "check-meson-logs-for-sanitizer-errors" "cat $BUILD_DIR/meson-logs/testlog*.txt | check_for_sanitizer_errors"
## Copy over meson test artifacts
#[[ -d "build/meson-logs" ]] && rsync -aq "build/meson-logs" "$LOGDIR"

## Run TEST-01-BASIC under sanitizers
# The host initrd contains multipath modules & services which are unused
# in the integration tests and sometimes cause unexpected failures. Let's build
# a custom initrd used solely by the integration tests
#
# Set a path to the custom initrd into the INITRD variable which is read by
# the integration test suite "framework"
export INITRD="/var/tmp/ci-initramfs-$(uname -r).img"
# Copy over the original initrd, as we want to keep the custom installed
# files we installed during the bootstrap phase (i.e. we want to keep the
# command line arguments the original initrd was built with)
cp -fv "/boot/initramfs-$(uname -r).img" "$INITRD"
# Rebuild the original initrd without the multipath module. Also, install
# the ibmvscsi driver which is required for ppc64le VMs to boot.
dracut --add-drivers ibmvscsi -o multipath --rebuild "$INITRD"

# Set timeouts for QEMU and nspawn tests to kill them in case they get stuck
export QEMU_TIMEOUT=1200
export NSPAWN_TIMEOUT=1200
# Set QEMU_SMP to speed things up
export QEMU_SMP=$(nproc)
# Arch Linux requires booting with initrd, as all commonly used filesystems
# are compiled in as modules
export SKIP_INITRD=no
# Enforce nested KVM
export TEST_NESTED_KVM=yes

# Enable systemd-coredump
if ! coredumpctl_init; then
    echo >&2 "Failed to configure systemd-coredump/coredumpctl"
    exit 1
fi

# As running integration tests with broken systemd can be quite time consuming
# (usually we need to wait for the test to timeout, see $QEMU_TIMEOUT and
# $NSPAWN_TIMEOUT above), let's try to sanity check systemd first by running
# the basic integration test under systemd-nspawn
#
# If the sanity check passes we can be at least somewhat sure the systemd
# 'core' is stable and we can run the rest of the selected integration tests.
# 1) Run it under systemd-nspawn
export TESTDIR="/var/tmp/TEST-01-BASIC_sanitizers-nspawn"
rm -fr "$TESTDIR"
exectask "TEST-01-BASIC_sanitizers-nspawn" "make -C test/TEST-01-BASIC clean setup run clean-again TEST_NO_QEMU=1 && touch $TESTDIR/pass"
NSPAWN_EC=$?
# Each integration test dumps the system journal when something breaks
[[ ! -f "$TESTDIR/pass" ]] && rsync -aq "$TESTDIR/system.journal" "$LOGDIR/${TESTDIR##*/}/"

if [[ $NSPAWN_EC -eq 0 ]]; then
    # 2) The sanity check passed, let's run the other half of the TEST-01-BASIC
    #    (under QEMU) and possibly other selected tests
    export TESTDIR="/var/tmp/systemd-test-TEST-01-BASIC_sanitizers-qemu"
    rm -fr "$TESTDIR"
    exectask "TEST-01-BASIC_sanitizers-qemu" "make -C test/TEST-01-BASIC clean setup run TEST_NO_NSPAWN=1 && touch $TESTDIR/pass"

    # Run certain other integration tests under sanitizers to cover bigger
    # systemd subcomponents (but only if TEST-01-BASIC passed, so we can
    # be somewhat sure the 'base' systemd components work).
    EXECUTED_LIST=()
    INTEGRATION_TESTS=(
        test/TEST-04-JOURNAL        # systemd-journald
#        test/TEST-13-NSPAWN-SMOKE   # systemd-nspawn
        test/TEST-15-DROPIN         # dropin logic
        test/TEST-17-UDEV           # systemd-udevd
        test/TEST-22-TMPFILES       # systemd-tmpfiles
        test/TEST-29-PORTABLE       # systemd-portabled
        test/TEST-46-HOMED          # systemd-homed
        test/TEST-50-DISSECT        # systemd-dissect
        test/TEST-55-OOMD           # systemd-oomd
        test/TEST-58-REPART         # systemd-repart
    )

    for t in "${INTEGRATION_TESTS[@]}"; do
        # Set the test dir to something predictable so we can refer to it later
        export TESTDIR="/var/tmp/systemd-test-${t##*/}"

        # Disable nested KVM for TEST-13-NSPAWN-SMOKE, which keeps randomly
        # failing due to time outs caused by CPU soft locks. Also, bump the
        # QEMU timeout, since the test is much slower without KVM.
        export TEST_NESTED_KVM=yes
        if [[ "$t" == "test/TEST-13-NSPAWN-SMOKE" ]]; then
            unset TEST_NESTED_KVM
            export QEMU_TIMEOUT=1200
        fi

        # Suffix the $TESTDIR of each retry with an index to tell them apart
        export MANGLE_TESTDIR=1
        exectask_retry "${t##*/}" "make -C $t setup run && touch \$TESTDIR/pass"

        # Retried tasks are suffixed with an index, so update the $EXECUTED_LIST
        # array accordingly to correctly find the respective journals
        for ((i = 1; i <= EXECTASK_RETRY_DEFAULT; i++)); do
            [[ -d "/var/tmp/systemd-test-${t##*/}_${i}" ]] && EXECUTED_LIST+=("${t}_${i}")
        done
    done

    # Save journals created by integration tests
    for t in "TEST-01-BASIC_sanitizers-qemu" "${EXECUTED_LIST[@]}"; do
        testdir="/var/tmp/systemd-test-${t##*/}"
        if [[ -f "$testdir/system.journal" ]]; then
            # Filter out test-specific coredumps which are usually intentional
            # Note: $COREDUMPCTL_EXCLUDE_MAP resides in common/utils.sh
            # Note2: since all tests in this run are using the `exectask_retry`
            #        runner, they're always suffixed with '_X'
            if [[ -v "COREDUMPCTL_EXCLUDE_MAP[${t%_[0-9]}]" ]]; then
                export COREDUMPCTL_EXCLUDE_RX="${COREDUMPCTL_EXCLUDE_MAP[${t%_[0-9]}]}"
            fi
            # Attempt to collect coredumps from test-specific journals as well
            exectask "${t##*/}_coredumpctl_collect" "COREDUMPCTL_BIN='$BUILD_DIR/coredumpctl' coredumpctl_collect '$testdir/'"
            # Make sure to not propagate the custom coredumpctl filter override
            [[ -v COREDUMPCTL_EXCLUDE_RX ]] && unset -v COREDUMPCTL_EXCLUDE_RX

            # Check for sanitizer errors in test journals
            exectask "${t##*/}_sanitizer_errors" "$BUILD_DIR/journalctl --file $testdir/system.journal | check_for_sanitizer_errors"
            # Keep the journal files only if the associated test case failed
            if [[ ! -f "$testdir/pass" ]]; then
                rsync -aq "$testdir/system.journal" "$LOGDIR/${t##*/}/"
            fi
        fi
    done
fi

# Check the test logs for sanitizer errors as well, since some tests may
# output the "interesting" information only to the console.
_check_test_logs_for_sanitizer_errors() {
    local EC=0

    while read -r file; do
        echo "*** Processing file $file ***"
        check_for_sanitizer_errors < "$file" || EC=1
    done < <(find "$LOGDIR" -maxdepth 1 -name "TEST-*.log" ! -name "*_sanitizer_*" ! -name "*_coredumpctl_*")

    return $EC
}
exectask "test_logs_sanitizer_errors" "_check_test_logs_for_sanitizer_errors"

exectask "check-journal-for-sanitizer-errors" "journalctl -b | check_for_sanitizer_errors"
# Collect coredumps using the coredumpctl utility, if any
exectask "coredumpctl_collect" "coredumpctl_collect"

# Summary
echo
echo "TEST SUMMARY:"
echo "-------------"
echo "PASSED: $PASSED"
echo "FAILED: $FAILED"
echo "TOTAL:  $((PASSED + FAILED))"

if [[ ${#FAILED_LIST[@]} -ne 0 ]]; then
    echo
    echo "FAILED TASKS:"
    echo "-------------"
    for task in "${FAILED_LIST[@]}"; do
        echo "$task"
    done
fi

exit $FAILED
