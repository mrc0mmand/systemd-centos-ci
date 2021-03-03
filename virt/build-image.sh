#!/bin/bash

# FIXME: configure --qemu-smp and --qemu-mem

set -eu
set -o pipefail

SCRIPT_ROOT="$(dirname "$(readlink -f "$0")")"
IMAGE_NAME="${1:?Missing argument: image name}"
IMAGE_OUT="${2:-$IMAGE_NAME.img}"
IMAGE_DIR="$SCRIPT_ROOT/images/$IMAGE_NAME"
SSH_KEY="$SCRIPT_ROOT/keys/id_rsa"
MKOSI_ARGS=(--output "$IMAGE_OUT" --ssh-key "$SSH_KEY")

if [[ ! -d "$IMAGE_DIR" ]]; then
    echo >&2 "Couldn't find image directory '$IMAGE_DIR' for image '$IMAGE_NAME'"
    exit 1
fi

if [[ ! -f "$SSH_KEY" || ! -f "$SSH_KEY.pub" ]]; then
    echo >&2 "Couldn't find the SSH key pair (or one of the parts) for key '$SSH_KEY'"
    exit 1
fi

if ! command -v mkosi && ! "$SCRIPT_ROOT/setup-mkosi.sh"; then
    echo >&2 "Failed to configure mkosi, can't continue"
    exit 1
fi

at_exit() {
    # shellcheck disable=SC2181
    if [[ $? -ne 0 ]]; then
        [[ -f qemu.log ]] && cat qemu.log
        # TODO: dump/save journal
    fi

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

pushd "$IMAGE_DIR"

trap at_exit EXIT

if [[ ! -f "mkosi.default" ]]; then
    echo >&2 "The image directory $IMAGE_DIR is missing a mkosi config (mkosi.default)"
    exit 1
fi

# Fix SSH key's permissions
chmod -v 0600 "$SSH_KEY"
# Dump information about the current image configuration
mkosi "${MKOSI_ARGS[@]}" summary
# Clean any left-over artifacts
mkosi "${MKOSI_ARGS[@]}" -ff clean
# Create a cache directory if if doesn't already exist
[[ -d mkosi.cache ]] && mkdir mkosi.cache

# Build the image
SYSTEMD_SECCOMP=0 mkosi "${MKOSI_ARGS[@]}" build

# Sanity check the image
MKOSI_UNIT="mkosi-build-image-$RANDOM.service"
systemd-run --unit "$MKOSI_UNIT" -p WorkingDirectory="$PWD" -- mkosi "${MKOSI_ARGS[@]}" --qemu-smp=2 --qemu-mem=2G qemu
systemctl --no-pager -l status "$MKOSI_UNIT"

echo "Trying to boot the created image ($IMAGE_OUT)"
    # Set BatchMode=yes so ssh doesn't fallback to password
if ! mkosi "${MKOSI_ARGS[@]}" --ssh-timeout 60 ssh -o BatchMode=yes "systemctl is-system-running"; then
    echo >&2 "Failed to bring up the SUT"
    exit 1
fi

mkosi "${MKOSI_ARGS[@]}" ssh -o BatchMode=yes "uname -a; systemctl poweroff"
# Give the VM some time to cleanly shut down
echo "Trying to shutdown the SUT"
for _ in {0..6}; do
    ! systemctl is-active "$MKOSI_UNIT" && break
    sleep 5
done

# Cleanup is handled by the at_exit() function above
