#!/bin/bash

set -eu

fatal() { echo >&2 "[*] ERROR: $*"; exit 1; }
log() { echo "[*] $*"; }

chroot_run() {
    if [[ $# -ne 2 ]]; then
        fatal "chroot_run() expects exactly two arguments - chroot dir and command"
    fi

    arch-chroot "$1" bash -c "$2"
}

dev_cleanup() {
    # Unmount and remove the rootfs mountpoint if it exists
    if [[ -v ROOTFS_DIR && -d "$ROOTFS_DIR" ]]; then
        umount "$ROOTFS_DIR"
        rm -fr "$ROOTFS_DIR"
    fi

    # Detach the loop device if it exists
    [[ -v LODEV && -b "${LODEV}p1" ]] && losetup -d "$LODEV"
}

at_exit() {
    local EC=$?

    set +e

    log "At-exit cleanup"

    dev_cleanup
    # Remove the temporary raw image if it exists
    [[ -v IMAGE_RAW_NAME && -e "$IMAGE_RAW_NAME" ]] && rm -f "$IMAGE_RAW_NAME"

    log "At-exit cleanup finished"
    log "Exit code: $EC"
}

# Check for required utilities
for cmd in arch-chroot curl mkfs.ext4 nproc pacstrap "qemu-system-$(uname -m)" genfstab qemu-img sfdisk; do
    if ! command -v "$cmd" >/dev/null; then
        fatal "Missing required command '$cmd', can't continue"
    fi
done

trap at_exit EXIT SIGINT

IMAGE_RAW_NAME="$(mktemp "$PWD/archXXX.raw")"
IMAGE_QCOW_NAME="${IMAGE_QCOW_NAME:-arch.qcow2}"
QEMU_BIN="qemu-system-$(uname -m)"
QEMU_MEM="2048M"
QEMU_SMP="$(nproc)"
ROOTFS_DIR="$(mktemp -d)"

log "Creating the base image"
# Create a sparse raw image file for our rootfs and attach it as a loop device
qemu-img create -f raw "$IMAGE_RAW_NAME" 30G
LODEV="$(losetup -P --show -f "$IMAGE_RAW_NAME")"
if [[ -z "$LODEV" || ! -b "$LODEV" ]]; then
    fatal "Failed to create a loop device from image '$IMAGE_RAW_NAME'"
fi

sfdisk "$LODEV" <<EOF
label: dos
                                   type=83, bootable
EOF
mkfs.ext4 "${LODEV}p1"
mount "${LODEV}p1" "$ROOTFS_DIR"

log "Configuring pacman mirrors"
# Download the latest Arch Linux mirror list and enable certain mirrors
curl -fsS "https://www.archlinux.org/mirrorlist/?country=all" > /etc/pacman.d/mirrorlist
# Enable kernel.org mirrors, since they should be always available
sed -i '/kernel.org/s/^#//' /etc/pacman.d/mirrorlist
# Enable first two mirrors from certain countries
sed -i '/## Czechia/,+2s/^#//' /etc/pacman.d/mirrorlist
sed -i '/## Germany/,+2s/^#//' /etc/pacman.d/mirrorlist
sed -i '/## United Kingdom/,+2s/^#//' /etc/pacman.d/mirrorlist

# Bootstrap the actual OS
log "Bootstrapping the OS"
pacman-key --init
pacman-key --populate archlinux
pacstrap "$ROOTFS_DIR" base bash dhcpcd grub linux mkinitcpio openssh sudo systemd
genfstab -U -p "$ROOTFS_DIR" >> "$ROOTFS_DIR/etc/fstab"

## OS configuration (inspired by lavabit/robox Arch boxes)
# Configure bootloader && initramfs
# - disable predictable netdev names, as we plan to use only one NIC
# - make the `autodetect` mkinitcpio hook the default
# - rebuild the initramfs, install grub bootloader and regenerate the grub config
log "Generating initramfs & installing grub bootloader"
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/GRUB_CMDLINE_LINUX_DEFAULT="\1 net.ifnames=0 biosdevname=0 elevator=noop vga=792"/g' "$ROOTFS_DIR/etc/default/grub"
sed -i 's/^#default_options=/default_options="-S autodetect"/g' "$ROOTFS_DIR/etc/mkinitcpio.d/linux.preset"
chroot_run "$ROOTFS_DIR" "mkinitcpio -p linux && grub-install '$LODEV' && grub-mkconfig -o /boot/grub/grub.cfg"

# Configure locales & the timezone
log "Generating locales & configuring the timezone"
sed -i 's/^#\(en_US.UTF-8\)/\1/' "$ROOTFS_DIR/etc/locale.gen"
chroot_run "$ROOTFS_DIR" "locale-gen"
echo 'LANG=en_US.UTF-8' > "$ROOTFS_DIR/etc/locale.conf"
chroot_run "$ROOTFS_DIR" "ln -sf /usr/share/zoneinfo/UTC /etc/localtime"

# Set hostname
log "Setting hostname"
echo 'arch.localdomain' > "$ROOTFS_DIR/etc/hostname"

# Configure users & ssh
log "Configuring users & ssh"
chroot_run "$ROOTFS_DIR" "printf 'systemd\nsystemd' | passwd root"
sed -i -e "s/.*PermitRootLogin.*/PermitRootLogin yes/g" "$ROOTFS_DIR/etc/ssh/sshd_config"

# Configure default DNS servers
log "Configuring default DNS servers"
cat > "$ROOTFS_DIR/etc/resolv.conf" << EOF
nameserver 1.1.1.1
nameserver 8.8.8.9
nameserver 1.0.0.1
EOF

# Enable wanted system services
log "Enabling system services"
systemctl --root "$ROOTFS_DIR" enable sshd dhcpcd

# TODO:
#   - vagrant bootstrap script (systemd service after boot?)
#   - ssh keys
#   - networking
timeout 15m $QEMU_BIN \
        -hda "$IMAGE_RAW_NAME" \
        -m "$QEMU_MEM" \
        -smp "$QEMU_SMP"

## At this point the image should be fully functional (e.g. bootable)

dev_cleanup

log "Generating the final qcow2 image"
qemu-img convert -f raw -O qcow2 "$IMAGE_RAW_NAME" "$IMAGE_QCOW_NAME"
