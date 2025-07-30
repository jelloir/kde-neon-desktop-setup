#!/bin/bash

# Btrfs Subvolumes Setup for KDE Neon with LUKS (Post-Calamares)
# Uses mv instead of rsync and simplified directory handling
# The following disk format will produce the required layout
# Disk format:
    # Partition 1: 512MiB /boot/efi
    # Partition 2: 2GiB /boot
    # Partition 3: Remaining Space, Encypted BTRFS
# /tmp on tmpfs and /swap/swapfile on a btrfs subvolume will be
# setup by Calamares automatically.
    

set -euo pipefail

# Constants
TARGET="/target"
BTRFS_ROOT="/mnt/btrfs_root"

# Error handling function
handle_error() {
    echo "ERROR: $1" >&2
    echo "Cleaning up..." >&2
    cleanup
    exit 1
}

# Cleanup function
cleanup() {
    # Unmount in reverse order
    if mountpoint -q "$BTRFS_ROOT"; then umount -R "$BTRFS_ROOT"; rmdir "$BTRFS_ROOT" || true; fi
    if mountpoint -q "$TARGET/run"; then umount "$TARGET/run" || true; fi
    if mountpoint -q "$TARGET/sys"; then umount "$TARGET/sys" || true; fi
    if mountpoint -q "$TARGET/proc"; then umount "$TARGET/proc" || true; fi
    if mountpoint -q "$TARGET/dev/pts"; then umount "$TARGET/dev/pts" || true; fi
    if mountpoint -q "$TARGET/dev"; then umount "$TARGET/dev" || true; fi
    if mountpoint -q "$TARGET/boot/efi"; then umount "$TARGET/boot/efi" || true; fi
    if mountpoint -q "$TARGET/boot"; then umount "$TARGET/boot" || true; fi
    if mountpoint -q "$TARGET"; then umount "$TARGET" || true; fi
}

# Verify LiveCD environment
verify_environment() {
    if ! grep -q "boot=casper\|boot=live" /proc/cmdline; then
        handle_error "This script must be run from the LiveCD environment"
    fi
    echo "✓ LiveCD environment verified"
}

# Detect LUKS device
detect_luks_device() {
    local mapper_name
    mapper_name=$(ls /dev/mapper/luks-* 2>/dev/null | head -1)
    if [ -z "$mapper_name" ]; then
        handle_error "Could not detect LUKS mapper device"
    fi
    echo "$mapper_name"
}

# Mount target system
mount_target() {
    local device=$1
    mkdir -p "$TARGET"
    if ! mount -o subvol=@ "$device" "$TARGET"; then
        handle_error "Failed to mount target system"
    fi
    echo "✓ Mounted target system at $TARGET"
}

# Mount partitions from fstab
mount_from_fstab() {
    local mount_point=$1
    local fstab="$TARGET/etc/fstab"
    
    echo "Processing $mount_point from fstab..."
    local fstab_line=$(grep -E "[[:space:]]$mount_point[[:space:]]" "$fstab" | head -1)
    [ -z "$fstab_line" ] && return 1

    local device=$(echo "$fstab_line" | awk '{print $1}')
    [[ "$device" == UUID=* ]] && device=$(blkid -t UUID="${device#UUID=}" -o device)
    [ -z "$device" ] && return 1

    echo "Mounting $device to $TARGET$mount_point"
    mkdir -p "$TARGET$mount_point"
    if ! mount "$device" "$TARGET$mount_point"; then
        handle_error "Failed to mount $device to $TARGET$mount_point"
    fi
    return 0
}

# Setup chroot environment
setup_chroot() {
    mount --bind /dev "$TARGET/dev" || handle_error "Failed to bind mount /dev"
    mount --bind /dev/pts "$TARGET/dev/pts" || handle_error "Failed to bind mount /dev/pts"
    mount --bind /proc "$TARGET/proc" || handle_error "Failed to bind mount /proc"
    mount --bind /sys "$TARGET/sys" || handle_error "Failed to bind mount /sys"
    mount --bind /run "$TARGET/run" || handle_error "Failed to bind mount /run"
    echo "✓ Chroot environment prepared"
}

# Create and mount Btrfs root
setup_btrfs_root() {
    local device=$1
    mkdir -p "$BTRFS_ROOT"
    if ! mount -t btrfs -o subvolid=5 "$device" "$BTRFS_ROOT"; then
        handle_error "Failed to mount Btrfs root"
    fi
    echo "✓ Btrfs root mounted at $BTRFS_ROOT"
}

# Create subvolume and move data
create_subvolume() {
    local mount_point=$1  # e.g. "/var/log"
    local subvol=$2       # e.g. "@var_log"
    
    echo "Creating $subvol for $mount_point..."
    if [ ! -e "$BTRFS_ROOT/$subvol" ]; then
        if ! btrfs subvolume create "$BTRFS_ROOT/$subvol"; then
            handle_error "Failed to create subvolume $subvol"
        fi
    fi

    # Mount the new subvolume temporarily
    TEMP_MOUNT=$(mktemp -d)
    if ! mount -t btrfs -o subvol="$subvol" "$LUKS_MAPPER_NAME" "$TEMP_MOUNT"; then
        rmdir "$TEMP_MOUNT"
        handle_error "Failed to mount $subvol for data migration"
    fi

    # Move data if directory exists and is not empty
    if [ -d "$TARGET$mount_point" ] && [ ! -z "$(ls -A "$TARGET$mount_point")"]; then
        echo "Moving data from $TARGET$mount_point to $subvol..."
        if ! mv "$TARGET$mount_point"/* "$TEMP_MOUNT/"; then
            umount "$TEMP_MOUNT"
            rmdir "$TEMP_MOUNT"
            handle_error "Failed to move data to $subvol"
        fi
        
        # Remove old directory and create mount point
        if ! rmdir "$TARGET$mount_point"; then
            umount "$TEMP_MOUNT"
            rmdir "$TEMP_MOUNT"
            handle_error "Failed to remove old $mount_point directory"
        fi
    fi

    # Create mount point (whether data existed or not)
    if ! mkdir -p "$TARGET$mount_point"; then
        umount "$TEMP_MOUNT"
        rmdir "$TEMP_MOUNT"
        handle_error "Failed to create new $mount_point directory"
    fi

    umount "$TEMP_MOUNT"
    rmdir "$TEMP_MOUNT"
    echo "✓ Created and populated $subvol"
}

# Create swapfile and update fstab with LUKS mapper paths
update_fstab() {
    local device=$1
    local fstab="$TARGET/etc/fstab"

    # Update fstab 
    echo "Updating fstab..."
    
    # Skip if our entries already exist
    if grep -q "subvol=@var_log" "$fstab"; then
        echo "✓ Btrfs subvolume entries already exist in fstab"
        return 0
    fi

    # Add new entries
    {
        echo "# Btrfs subvolumes"
        echo "$device /var/log btrfs defaults,subvol=@var_log 0 0"
        echo "$device /var/cache btrfs defaults,subvol=@var_cache 0 0"
    } >> "$fstab" || handle_error "Failed to update fstab"

    echo "✓ fstab updated"
}

### Main Execution ###
trap cleanup EXIT

echo "=== Starting Btrfs Subvolume Setup ==="

# Verify environment
verify_environment

# Detect LUKS device
LUKS_MAPPER_NAME=$(detect_luks_device)
echo "✓ Detected LUKS mapper: $LUKS_MAPPER_NAME"

# Mount target system
mount_target "$LUKS_MAPPER_NAME"

# Mount boot partitions
mount_from_fstab "/boot" || echo "⚠  /boot mount skipped (not found in fstab)"
mount_from_fstab "/boot/efi" || echo "⚠  /boot/efi mount skipped (not found in fstab)"

# Setup chroot environment
setup_chroot

# Setup Btrfs root
setup_btrfs_root "$LUKS_MAPPER_NAME"

# Create subvolumes
create_subvolume "/var/log" "@var_log"
create_subvolume "/var/cache" "@var_cache"

# Update fstab
update_fstab "$LUKS_MAPPER_NAME"

echo "=== Btrfs Subvolume Setup Complete ==="
echo "Successfully created and configured:"
echo " - @var_log (for /var/log)"
echo " - @var_cache (for /var/cache)"
