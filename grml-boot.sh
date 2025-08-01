#!/bin/sh

### Configuration ###
ISO_PATH="/boot/grml.iso"
GRUB_CUSTOM="/etc/grub.d/40_custom"
GRML_DOWNLOAD_URL="https://grml.org/download/"

### Helper Functions ###

# Check for root privileges with sudo fallback
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "This script requires root privileges to write to system locations."
        echo "Please enter your sudo password if prompted."
        exec sudo "$0" "$@"
        exit $?
    fi
}

# Fetch latest version from SourceForge
fetch_version() {
    curl -s "$GRML_DOWNLOAD_URL" | \
        grep -oP 'grml-full-[0-9]{4}.[0-9]{2}-amd64.iso' | \
        sort -V | \
        tail -n1
}

# Download ISO with error checking
download_iso() {
    echo "Downloading grmlCD $1..."
    if ! curl -Lf "$2" -o "$3"; then
        echo "ERROR: Download failed!" >&2
        return 1
    fi
    echo "Download saved to: $3"
}

# Label the boot partition
label_boot_partition() {
    local boot_dev=$(findmnt -n -o SOURCE --target /boot)

    if [ -z "$boot_dev" ]; then
        echo "WARNING: /boot is not a separate mount point. Skipping labeling."
        return 0
    fi

    if ! tune2fs -l "$boot_dev" >/dev/null 2>&1; then
        echo "WARNING: $boot_dev is not an ext filesystem. Skipping labeling."
        return 0
    fi

    e2label "$boot_dev" boot || {
        echo "WARNING: Failed to label $boot_dev as 'boot'." >&2
        return 1
    }
}

# Configure GRUB
configure_grub() {
    if ! grep -q "grml (isoloop)" "$GRUB_CUSTOM" 2>/dev/null; then
        cat >> "$GRUB_CUSTOM" <<EOF
#!/bin/sh
exec tail -n +3 \$0
rmmod tpm
menuentry "grml (isoloop)" {
    load_video
    insmod gzio
    insmod part_gpt
    insmod part_msdos
    insmod ext2
    search --no-floppy --label boot --set=root
    loopback loop /grml.iso
    echo   'Loading kernel ...'
    linux  (loop)/sysresccd/boot/x86_64/vmlinuz img_label=boot img_loop=/grml.iso archisobasedir=sysresccd copytoram setkmap=us
    echo   'Loading initramfs ...'
    initrd (loop)/sysresccd/boot/x86_64/sysresccd.img
}
EOF
        chmod +x /etc/grub.d/40_custom
        update-grub
    else
        echo "grml entry already exists in $GRUB_CUSTOM"
    fi
}

### Main Execution ###

# Check privileges first
check_root "$@"

# Fetch and download latest ISO
VERSION=$(fetch_version) || {
    echo "ERROR: Could not fetch latest version." >&2
    exit 1
}

DOWNLOAD_URL="${SOURCEFORGE_URL}${VERSION}/grml-${VERSION}-amd64.iso/download"
download_iso "$VERSION" "$DOWNLOAD_URL" "$ISO_PATH" || exit 1

# Label boot partition (non-fatal if fails)
label_boot_partition

# Configure GRUB
configure_grub

echo "grmlCD setup completed successfully."
