#!/bin/bash

# Script to dynamically grow an XFS filesystem on a multipath SAN LUN (LVM or non-LVM)
# Updates /etc/fstab to reflect current device or UUID
# Requires root privileges
# Usage: ./grow_xfs_filesystem.sh <multipath_device> <device_or_lv> <mount_point>
# Example (LVM): ./grow_xfs_filesystem.sh /dev/mapper/mpatha /dev/vg_data/lv_data /mnt/data
# Example (non-LVM): ./grow_xfs_filesystem.sh /dev/mapper/mpatha /dev/mapper/mpatha /mnt/data

# Exit on error
set -e

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Error handling function
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    error_exit "This script must be run as root"
fi

# Check for required arguments
if [ $# -ne 3 ]; then
    error_exit "Usage: $0 <multipath_device> <device_or_lv> <mount_point>"
fi

MULTIPATH_DEVICE="$1"
DEVICE_OR_LV="$2"
MOUNT_POINT="$3"

# Validate inputs
if [ ! -b "$MULTIPATH_DEVICE" ]; then
    error_exit "Multipath device $MULTIPATH_DEVICE does not exist"
fi
if [ ! -b "$DEVICE_OR_LV" ]; then
    error_exit "Device or logical volume $DEVICE_OR_LV does not exist"
fi
if [ ! -d "$MOUNT_POINT" ]; then
    error_exit "Mount point $MOUNT_POINT does not exist"
fi

# Check if the filesystem is XFS
if ! mount | grep "$MOUNT_POINT" | grep -q xfs; then
    error_exit "$MOUNT_POINT is not an XFS filesystem"
fi

# Check if using LVM
IS_LVM=false
if lvdisplay "$DEVICE_OR_LV" &>/dev/null; then
    IS_LVM=true
    log "Detected LVM configuration for $DEVICE_OR_LV"
else
    log "No LVM detected, assuming direct XFS on $DEVICE_OR_LV"
fi

# Step 1: Identify underlying SCSI devices for the multipath device
log "Identifying SCSI devices for $MULTIPATH_DEVICE"
SCSI_DEVICES=$(lsblk -o NAME,TYPE -n -p "$MULTIPATH_DEVICE" | grep part | awk '{print $1}' | xargs -I {} lsblk -o NAME,TYPE -n -p {} | grep disk | awk '{print $1}')

if [ -z "$SCSI_DEVICES" ]; then
    error_exit "No SCSI devices found for $MULTIPATH_DEVICE"
fi

# Step 2: Rescan SCSI bus to detect new LUN size
log "Rescanning SCSI bus for devices"
for dev in $SCSI_DEVICES; do
    SCSI_HOST=$(ls -l /sys/block/$(basename "$dev")/device | awk -F'/' '{print $6}')
    echo "- - -" > "/sys/class/scsi_host/$SCSI_HOST/scan" || error_exit "Failed to rescan SCSI bus for $dev"
    log "Rescanned $dev on $SCSI_HOST"
done

# Step 3: Update multipath device
log "Updating multipath device $MULTIPATH_DEVICE"
multipathd resize map "$(basename "$MULTIPATH_DEVICE")" || error_exit "Failed to resize multipath device"
multipath -ll | grep "$(basename "$MULTIPATH_DEVICE")" && log "Multipath device updated"

# Step 4: Resize physical volume (LVM only)
if [ "$IS_LVM" = true ]; then
    log "Resizing physical volume"
    if pvdisplay "$MULTIPATH_DEVICE" &>/dev/null; then
        pvresize "$MULTIPATH_DEVICE" || error_exit "Failed to resize physical volume $MULTIPATH_DEVICE"
        log "Physical volume $MULTIPATH_DEVICE resized"
    else
        error_exit "No LVM physical volume found on $MULTIPATH_DEVICE"
    fi

    # Step 5: Extend logical volume
    log "Extending logical volume $DEVICE_OR_LV"
    lvextend -l +100%FREE "$DEVICE_OR_LV" || error_exit "Failed to extend logical volume $DEVICE_OR_LV"
    log "Logical volume $DEVICE_OR_LV extended"
fi

# Step 6: Grow XFS filesystem
log "Growing XFS filesystem on $MOUNT_POINT"
xfs_growfs "$MOUNT_POINT" || error_exit "Failed to grow XFS filesystem on $MOUNT_POINT"
log "XFS filesystem on $MOUNT_POINT successfully grown"

# Step 7: Update /etc/fstab
log "Updating /etc/fstab for $MOUNT_POINT"
FSTAB_FILE="/etc/fstab"
BACKUP_FSTAB="/etc/fstab.backup.$(date '+%Y%m%d%H%M%S')"

# Backup fstab
log "Backing up $FSTAB_FILE to $BACKUP_FSTAB"
cp "$FSTAB_FILE" "$BACKUP_FSTAB" || error_exit "Failed to backup $FSTAB_FILE"

# Get UUID of the device or logical volume
DEVICE_UUID=$(blkid -s UUID -o value "$DEVICE_OR_LV" || error_exit "Failed to get UUID for $DEVICE_OR_LV")
log "Device UUID: $DEVICE_UUID"

# Check if mount point exists in fstab
if grep -q "$MOUNT_POINT" "$FSTAB_FILE"; then
    log "Updating existing $MOUNT_POINT entry in $FSTAB_FILE"
    # Create temporary fstab file
    TEMP_FSTAB=$(mktemp)
    awk -v mp="$MOUNT_POINT" -v uuid="$DEVICE_UUID" '
        $2 == mp {print "UUID=" uuid "\t" mp "\txfs\tdefaults\t0 0"}
        $2 != mp {print $0}
    ' "$FSTAB_FILE" > "$TEMP_FSTAB"
    mv "$TEMP_FSTAB" "$FSTAB_FILE" || error_exit "Failed to update $FSTAB_FILE"
else
    log "Adding new entry for $MOUNT_POINT to $FSTAB_FILE"
    echo "UUID=$DEVICE_UUID $MOUNT_POINT xfs defaults 0 0" >> "$FSTAB_FILE" || error_exit "Failed to append to $FSTAB_FILE"
fi

# Verify fstab syntax
log "Verifying $FSTAB_FILE syntax"
if ! findmnt --fstab --evaluate >/dev/null; then
    log "WARNING: $FSTAB_FILE syntax check failed, restoring backup"
    cp "$BACKUP_FSTAB" "$FSTAB_FILE" || error_exit "Failed to restore $FSTAB_FILE from backup"
    error_exit "Invalid $FSTAB_FILE syntax, restored backup"
fi

# Display new filesystem size
log "New filesystem size:"
df -h "$MOUNT_POINT"

log "Operation completed successfully"