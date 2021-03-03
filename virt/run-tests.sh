#!/bin/bash

set -eu
set -o pipefail

SCRIPT_ROOT="$(dirname "$(readlink -f "$0")")"
SSH_KEY="$SCRIPT_ROOT/keys/id_rsa"
MKOSI_ARGS=(--ssh-key "$SSH_KEY")

SANITIZED=0

if [[ ! -f "$SSH_KEY" || ! -f "$SSH_KEY.pub" ]]; then
    echo >&2 "Couldn't find the SSH key pair (or one of the parts) for key '$SSH_KEY'"
    exit 1
fi

if ! command -v mkosi >/dev/null && ! "$SCRIPT_ROOT/setup-mkosi.sh"; then
    echo >&2 "Failed to configure mkosi, can't continue"
    exit 1
fi

while getopts "b:d:i:t:sr:" opt; do
    case "$opt" in
        b)
            BOOTSTRAP_SCRIPT="$SCRIPT_ROOT/bootstrap_scripts/$OPTARG"
            if [[ ! -f "$BOOTSTRAP_SCRIPT" ]]; then
                echo >&2 "Couldn't find bootstrap script '$BOOTSTRAP_SCRIPT'"
                exit 1
            fi
            ;;
        d)
            DISTRO="$OPTARG"
            IMAGE_DIR="$SCRIPT_ROOT/images/$DISTRO"
            if [[ ! -d "$IMAGE_DIR" ]]; then
                echo >&2 "Image directory '$SCRIPT_ROOT/images/$DISTRO' doesn't exist"
                exit 1
            fi
            ;;
        i)
            IMAGE_NAME="$OPTARG"
            # TODO: check/fetch image
            ;;
        t)
            TEST_SCRIPT="$SCRIPT_ROOT/test_scripts/$OPTARG"
            if [[ ! -f "$TEST_SCRIPT" ]]; then
                echo >&2 "Couldn't find test script '$TEST_SCRIPT'"
                exit 1
            fi
            ;;
        s)
            SANITIZED=1
            ;;
        r)
            REPO_PATH="$OPTARG"
            if [[ ! -d "$REPO_PATH" ]]; then
                echo >&2 "Couldn't find the specified repository at '$REPO_PATH'"
                exit 1
            fi
            ;;
        ?)
            exit 1
            ;;
        *)
            echo >&2 "Usage: TODO"
            exit 1
    esac
done

echo "Bootstrap script: ${BOOTSTRAP_SCRIPT:?Missing argument: bootstrap script}"
echo "Image dir: ${IMAGE_DIR:?Missing argument: distribution name}"
echo "Image name: ${IMAGE_NAME:?Missing argument: image name}"
echo "Test script: ${TEST_SCRIPT:?Missing argument: test script}"
echo "Sanitized run: ${SANITIZED}"
echo

setup_loopdev() {
    local IMAGE_PATH="${1:-Missing argument: image path}"
    local LOOP_DEV

    if ! LOOP_DEV="$(losetup --find --partscan --show "$IMAGE_PATH")"; then
        echo >&2 "[setup_loopdev] Failed to set up a loop device via losetup"
        return 1
    fi

    if [[ ! -b "$LOOP_DEV" || ! -b "${LOOP_DEV}p2" ]]; then
        echo >&2 "[setup_loopdev] Failed to set up a loop device for image '$IMAGE_PATH'"
        return 1
    fi

    echo "$LOOP_DEV"
}

# FIXME: configure --qemu-smp and --qemu-mem (with the dusty override)
# FIXME: get the image
IMAGE_PATH="$IMAGE_NAME"

MKOSI_ARGS+=(--output "$IMAGE_PATH")

at_exit() {
    set +e
    # Cleanup the root mount if it's defined
    if [[ -v ROOT_MOUNT ]]; then
        mountpoint "$ROOT_MOUNT" && umount "$ROOT_MOUNT"
        rm -fr "$ROOT_MOUNT"
    fi

    # Cleanup the loop device if it's defined
    [[ -v LOOP_DEV && -b "$LOOP_DEV" ]] && losetup -d "$LOOP_DEV"

    # Cleanup the mkosi qemu instance if it's defined
    if [[ -v MKOSI_UNIT ]]; then
        if systemctl is-active "$MKOSI_UNIT" >/dev/null; then
            systemctl stop "$MKOSI_UNIT"
        fi

        # GC the image unit in case it failed
        if systemctl is-failed "$MKOSI_UNIT" >/dev/null; then
            systemctl reset-failed "$MKOSI_UNIT"
        fi
    fi
}

trap at_exit EXIT

# Fix SSH key's permissions
chmod -v 0600 "$SSH_KEY"

# Mount the image's rootfs
LOOP_DEV="$(setup_loopdev "$IMAGE_PATH")"
ROOT_MOUNT="$(mktemp -d)"
mount "${LOOP_DEV}p2" "$ROOT_MOUNT"
# Copy the repo into the image
[[ -d "$ROOT_MOUNT/build" ]] && rm -fr "$ROOT_MOUNT/build"
rsync -aq "$REPO_PATH/" "$ROOT_MOUNT/build"
# Copy the CI scripts into the image
mkdir -p "$ROOT_MOUNT/ci"
cp -Lfv "$BOOTSTRAP_SCRIPT" "$ROOT_MOUNT/ci/bootstrap.sh"
cp -Lfv "$TEST_SCRIPT" "$ROOT_MOUNT/ci/test.sh"
chmod -v +x "$ROOT_MOUNT/ci/bootstrap.sh" "$ROOT_MOUNT/ci/test.sh"
# Copy the libraries the CI scripts use
cp -fv "$SCRIPT_ROOT/../common/task-control.sh" "$ROOT_MOUNT/ci/"
cp -fv "$SCRIPT_ROOT/../common/utils.sh" "$ROOT_MOUNT/ci/"
# Cleanup
umount "$ROOT_MOUNT"
losetup -d "$LOOP_DEV"
rm -fr "$ROOT_MOUNT"
unset LOOP_DEV ROOT_MOUNT
echo

pushd "$IMAGE_DIR"
# Boot the image
# FIXME: where to store the console log?
CONSOLE_LOG="$PWD/console.log"
MKOSI_UNIT="mkosi-build-image-$RANDOM.service"
systemd-run --unit "$MKOSI_UNIT" -p WorkingDirectory="$PWD" -- mkosi "${MKOSI_ARGS[@]}" --qemu-smp=2 --qemu-mem=2G qemu -serial "file:/$CONSOLE_LOG"
systemctl --no-pager -l status "$MKOSI_UNIT"

if ! mkosi "${MKOSI_ARGS[@]}" --ssh-timeout 60 ssh -o BatchMode=yes -o ConnectionAttempts=60 "systemctl is-system-running"; then
    echo >&2 "Failed to bring up the SUT"
    exit 1
fi

if ! mkosi "${MKOSI_ARGS[@]}" ssh -o BatchMode=yes "/ci/bootstrap.sh"; then
    echo >&2 "Failed to bootstrap the SUT"
    exit 1
fi

# Reboot the machine if we're not using a sanitized build
if [[ $SANITIZED -ne 0 ]]; then
    echo "Attempting to reboot the SUT"
    mkosi "${MKOSI_ARGS[@]}" ssh -o BatchMode=yes "systemctl reboot"
    mkosi "${MKOSI_ARGS[@]}" --ssh-timeout 60 ssh -o BatchMode=yes -o ConnectionAttempts=60 "systemctl is-system-running"
fi

# TODO: test script
# TODO: artifact collection
