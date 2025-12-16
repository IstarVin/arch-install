#!/bin/bash

# ==========================================
# GLAMOROUS LUKS SHRINKER (BTRFS EDITION)
# Safe resizing for LUKS-encrypted Btrfs partitions
# ==========================================

set -e  # Exit on any error
trap cleanup EXIT  # Always cleanup on exit

# ==========================================
# GLOBALS
# ==========================================
TEMP_MNT="/mnt/btrfs_resize_tmp"
MAPPER_PATH=""
MAPPER_NAME=""
ORIGINAL_LUKS_SIZE=""

# ==========================================
# CLEANUP FUNCTION
# ==========================================
cleanup() {
    if mountpoint -q "$TEMP_MNT" 2>/dev/null; then
        umount "$TEMP_MNT" 2>/dev/null || true
    fi
    rmdir "$TEMP_MNT" 2>/dev/null || true
}

# ==========================================
# 1. ROOT & DEPENDENCY CHECK
# ==========================================
if [[ $EUID -ne 0 ]]; then
   gum style --foreground 196 "Error: This script must be run as root."
   exit 1
fi

for cmd in gum btrfs awk cryptsetup dmsetup parted lsblk; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: '$cmd' is not installed. Please install it."
        exit 1
    fi
done

# ==========================================
# 2. SELECT MAPPER
# ==========================================
gum style --border double --margin "1" --padding "1 2" --border-foreground 212 \
    "🔐 Safe Btrfs/LUKS Resizer" \
    "" \
    "⚠️  IMPORTANT: Before proceeding:" \
    "   • Backup your data first!" \
    "   • Close all applications using this partition" \
    "   • This will temporarily unmount the filesystem"

echo ""
echo "Select the active LUKS partition to shrink:"

AVAILABLE_CRYPT=$(dmsetup ls --target crypt | awk '{print $1}')

if [[ -z "$AVAILABLE_CRYPT" ]]; then
    gum style --foreground 196 "No active LUKS devices found!"
    echo "Did you run 'cryptsetup open' yet?"
    exit 1
fi

MAPPER_NAME=$(echo "$AVAILABLE_CRYPT" | gum choose --limit 1 --header "Select Mapper Device")

if [[ -z "$MAPPER_NAME" ]]; then
    echo "No device selected. Exiting."
    exit 1
fi

MAPPER_PATH="/dev/mapper/$MAPPER_NAME"

# ==========================================
# 3. VERIFY IT'S BTRFS
# ==========================================
FS_TYPE=$(blkid -o value -s TYPE "$MAPPER_PATH" 2>/dev/null)

if [[ "$FS_TYPE" != "btrfs" ]]; then
    gum style --foreground 196 "Error: $MAPPER_PATH is not a Btrfs filesystem!"
    echo "Detected type: ${FS_TYPE:-unknown}"
    exit 1
fi

# ==========================================
# 4. CHECK IF MOUNTED & GET CURRENT SIZE
# ==========================================
CURRENTLY_MOUNTED=$(findmnt -n -o TARGET "$MAPPER_PATH" 2>/dev/null || echo "")

if [[ -n "$CURRENTLY_MOUNTED" ]]; then
    gum style --foreground 208 "Warning: $MAPPER_PATH is currently mounted at: $CURRENTLY_MOUNTED"
    if ! gum confirm "Unmount and continue?"; then
        echo "Aborted."
        exit 1
    fi
    umount "$CURRENTLY_MOUNTED"
fi

# Get current LUKS size
ORIGINAL_LUKS_SIZE=$(cryptsetup status "$MAPPER_NAME" | grep "size:" | awk '{print $2}')
CURRENT_GIB=$(awk "BEGIN {printf \"%.1f\", $ORIGINAL_LUKS_SIZE / 2 / 1024 / 1024}")

# ==========================================
# 5. MOUNT & ANALYZE SPACE
# ==========================================
mkdir -p "$TEMP_MNT"
mount "$MAPPER_PATH" "$TEMP_MNT"

gum spin --spinner dot --title "Analyzing filesystem usage..." -- sleep 1

# Get actual used space
USED_BYTES=$(btrfs filesystem usage -b "$TEMP_MNT" 2>/dev/null | grep "^[[:space:]]*Used:" | head -1 | awk '{print $2}' || echo "0")

if [[ "$USED_BYTES" == "0" ]]; then
    # Fallback method
    USED_BYTES=$(btrfs filesystem df -b "$TEMP_MNT" | grep "Data" | awk '{print $3}' | tr -d ',')
fi

USED_GIB=$(awk "BEGIN {printf \"%.2f\", $USED_BYTES / 1024 / 1024 / 1024}")

# Calculate safe minimum (used space + 20% for metadata/overhead)
SAFE_MINIMUM=$(awk "BEGIN {printf \"%.0f\", ($USED_BYTES * 1.2) / 1024 / 1024 / 1024}")

# ==========================================
# 6. DISPLAY CURRENT STATE
# ==========================================
gum style \
    --foreground 117 --border-foreground 117 --border normal \
    --align left --width 60 --margin "1" --padding "1 2" \
    "📊 Current Filesystem Info" \
    "" \
    "Device: $MAPPER_PATH" \
    "Current Size: ${CURRENT_GIB} GiB" \
    "Used Space: ${USED_GIB} GiB" \
    "Minimum Safe Size: ${SAFE_MINIMUM} GiB (includes 20% overhead)"

# ==========================================
# 7. INPUT TARGET SIZE
# ==========================================
echo ""
echo "Enter the NEW size for the filesystem (in GiB):"
echo "Must be at least ${SAFE_MINIMUM} GiB"

TARGET_GIB=$(gum input --placeholder "e.g., $SAFE_MINIMUM" --width 15)

# Validate input
if ! [[ "$TARGET_GIB" =~ ^[0-9]+$ ]]; then
    gum style --foreground 196 "Invalid number. Exiting."
    exit 1
fi

if [[ $TARGET_GIB -lt $SAFE_MINIMUM ]]; then
    gum style --foreground 196 "Error: Target size ($TARGET_GIB GiB) is too small!"
    echo "Minimum required: ${SAFE_MINIMUM} GiB"
    echo "Used space: ${USED_GIB} GiB + 20% overhead"
    exit 1
fi

if [[ $TARGET_GIB -ge ${CURRENT_GIB%.*} ]]; then
    gum style --foreground 196 "Error: Target size must be SMALLER than current size (${CURRENT_GIB} GiB)"
    exit 1
fi

# ==========================================
# 8. FIND PHYSICAL PARTITION
# ==========================================
LUKS_DEVICE=$(cryptsetup status "$MAPPER_NAME" | grep "device:" | awk '{print $2}')
DISK_NAME=$(lsblk -no PKNAME "$LUKS_DEVICE" 2>/dev/null | head -1)
PART_NUM=$(echo "$LUKS_DEVICE" | grep -oE '[0-9]+$')

# Calculate physical partition size (add 512MB for LUKS header overhead)
PHYSICAL_SIZE_GIB=$(awk "BEGIN {printf \"%.1f\", $TARGET_GIB + 0.5}")

# ==========================================
# 9. FINAL CONFIRMATION
# ==========================================
echo ""
gum style \
    --foreground 212 --border-foreground 212 --border double \
    --align center --width 65 --margin "1 2" --padding "2 4" \
    "⚠️  FINAL CONFIRMATION" \
    "" \
    "Target Device: $MAPPER_PATH" \
    "Physical Partition: $LUKS_DEVICE" \
    "" \
    "Current Size: ${CURRENT_GIB} GiB" \
    "New Size: $TARGET_GIB GiB" \
    "Physical Partition: ${PHYSICAL_SIZE_GIB} GiB" \
    "" \
    "OPERATIONS TO BE PERFORMED:" \
    "1. Shrink Btrfs filesystem to ${TARGET_GIB}G" \
    "2. Shrink LUKS container to match" \
    "3. YOU must then run:" \
    "   parted /dev/${DISK_NAME} resizepart ${PART_NUM} ${PHYSICAL_SIZE_GIB}GiB" \
    "" \
    "⚠️  THIS CANNOT BE EASILY UNDONE!"

if ! gum confirm "Proceed with resize?"; then
    gum style --foreground 241 "Aborted by user."
    exit 1
fi

# ==========================================
# 10. EXECUTION
# ==========================================

TARGET_BYTES=$(($TARGET_GIB * 1024 * 1024 * 1024))
TARGET_SECTORS=$(($TARGET_BYTES / 512))

echo ""
gum style --foreground 226 "Starting resize operations..."

# Step A: Resize Btrfs (while mounted)
echo ""
gum spin --spinner minidot --title "Shrinking Btrfs filesystem to ${TARGET_GIB}G..." -- \
    btrfs filesystem resize "${TARGET_GIB}G" "$TEMP_MNT"

if [[ $? -ne 0 ]]; then
    gum style --foreground 196 "❌ Btrfs resize failed!"
    echo "Your data is safe, but the resize did not complete."
    exit 1
fi

# Step B: Unmount
gum spin --spinner dot --title "Unmounting filesystem..." -- \
    umount "$TEMP_MNT"

if mountpoint -q "$TEMP_MNT" 2>/dev/null; then
    gum style --foreground 196 "❌ Failed to unmount! Cannot proceed."
    exit 1
fi

# Step C: Resize LUKS
echo ""
gum spin --spinner points --title "Shrinking LUKS container..." -- \
    cryptsetup resize --size "$TARGET_SECTORS" "$MAPPER_NAME"

if [[ $? -ne 0 ]]; then
    gum style --foreground 196 "❌ CRITICAL: LUKS resize failed!"
    echo "Btrfs was resized but LUKS was not."
    echo "DO NOT resize the physical partition yet!"
    echo "Seek help before proceeding further."
    exit 1
fi

# ==========================================
# 11. SUCCESS
# ==========================================
echo ""
gum style \
    --foreground 82 --border-foreground 82 --border double \
    --align left --width 70 --margin "1 2" --padding "2 3" \
    "✅ SUCCESS! Btrfs & LUKS resized to ${TARGET_GIB} GiB" \
    "" \
    "📋 NEXT STEP (REQUIRED):" \
    "You must now resize the physical partition to reclaim space:" \
    "" \
    "parted /dev/${DISK_NAME} resizepart ${PART_NUM} ${PHYSICAL_SIZE_GIB}GiB" \
    "" \
    "⚠️  Important notes:" \
    "• The partition size (${PHYSICAL_SIZE_GIB}GiB) is slightly larger than" \
    "  the filesystem (${TARGET_GIB}GiB) to accommodate LUKS headers" \
    "• After resizing, you can remount: mount $MAPPER_PATH /your/mount/point" \
    "• Verify with: btrfs filesystem usage /your/mount/point"

echo ""
gum style --foreground 117 "Physical partition command copied to your clipboard (if xclip available)"
echo "parted /dev/${DISK_NAME} resizepart ${PART_NUM} ${PHYSICAL_SIZE_GIB}GiB" | xclip -selection clipboard 2>/dev/null || true
