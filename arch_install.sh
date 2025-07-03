#!/bin/bash

# --- 1. INITIAL SETUP ---
# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color
YELLOW='\033[1;33m'
BLUE='\033[0;34m'

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Confirmation prompt
confirm() {
    local msg="$1"
    while true; do
        read -rp "$msg (y/N): " response
        case "$response" in
            [yY][eE][sS]|[yY]) return 0 ;;
            [nN][oO]|[nN]|"") return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# --- 2. DISK SELECTION ---
select_disk() {
    echo -e "\n${GREEN}Available disks:${NC}"
    lsblk -dno NAME,SIZE,TYPE,MODEL,TRAN | grep -E 'disk|nvme'
    
    while true; do
        echo -e "\nEnter disk name for installation (e.g., sda, nvme0n1):"
        read -r DISK
        
        [[ "$DISK" != /dev/* ]] && DISK="/dev/$DISK"
        
        if [ ! -b "$DISK" ]; then
            log_error "Disk $DISK doesn't exist or is not a block device!"
            continue
        fi
        
        if check_disk_usage "$DISK"; then
            break
        fi
    done
}

check_disk_usage() {
    local disk="$1"
    local base_disk
    
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]]; then
        base_disk="$disk"
    else
        base_disk="${disk%%[0-9]*}"
    fi

    CURRENT_ROOT=$(findmnt -n -o SOURCE /)
    if [[ "$CURRENT_ROOT" == "$base_disk"* ]]; then
        log_error "Cannot modify $disk - it's currently used as root filesystem!"
        log_info "Please select another disk or boot from different media"
        return 1
    fi

    MOUNTED_PARTS=$(lsblk -lno NAME,MOUNTPOINT "$disk" | grep -v '^NAME' | awk '$2!=""')
    if [ -n "$MOUNTED_PARTS" ]; then
        log_error "Disk $disk has mounted partitions:"
        echo "$MOUNTED_PARTS"
        if confirm "Attempt to unmount all partitions on $disk?"; then
            log_info "Unmounting partitions..."
            umount -l "${disk}"* 2>/dev/null
            swapoff -a
            return 0
        else
            return 1
        fi
    fi
    
    return 0
}

# --- 3. DISK PREPARATION ---
prepare_disk() {
    local disk="$1"
    
    log_info "\nPreparing disk $disk..."
    
    if confirm "WIPE ALL DATA on $disk and create new partition table?"; then
        log_info "Clearing disk..."
        wipefs -a "$disk" 2>/dev/null || {
            log_warn "Using fallback wipe method..."
            dd if=/dev/zero of="$disk" bs=1M count=100 status=progress
            sync
        }
        
        parted -s "$disk" mklabel gpt || {
            log_error "Failed to create partition table"
            exit 1
        }
        partprobe "$disk"
        sleep 2
    else
        log_error "Installation aborted by user"
        exit 1
    fi
}

# --- 4. PARTITIONING ---
partition_disk() {
    local disk="$1"
    
    log_info "\nCreating partitions on $disk..."
    
    local boot_size_mb=2048
    
    log_info "Creating EFI boot partition (${boot_size_mb}MB)..."
    parted -s "$disk" mkpart primary fat32 1MiB "${boot_size_mb}MiB" || {
        log_error "Boot partition failed"; exit 1
    }
    parted -s "$disk" set 1 esp on
    
    log_info "Creating root partition (remaining space)..."
    parted -s "$disk" mkpart primary btrfs "${boot_size_mb}MiB" "100%" || {
        log_error "Root partition failed"; exit 1
    }
    
    partprobe "$disk"
    sleep 2
    
    log_info "\nPartition table created:"
    lsblk -f "$disk"
}

# --- 5. FILESYSTEM CREATION ---
create_filesystems() {
    local disk="$1"
    
    log_info "\nCreating filesystems..."
    
    log_info "Formatting EFI partition (${disk}1) as FAT32..."
    mkfs.fat -F32 "${disk}1" || { log_error "Failed to format EFI partition"; exit 1; }
    
    log_info "Formatting root partition (${disk}2) as Btrfs..."
    mkfs.btrfs -f "${disk}2" || { log_error "Failed to format root partition"; exit 1; }
    
    log_info "Creating Btrfs subvolumes..."
    mount "${disk}2" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@snapshots
    umount /mnt
    
    log_info "\n${GREEN}Disk preparation complete!${NC}"
    log_info "You can now proceed with manual system installation."
    log_info "Mount points structure:"
    log_info "- ${disk}1 mounted at /boot (FAT32)"
    log_info "- ${disk}2 with subvolumes:"
    log_info "  - @ mounted at /"
    log_info "  - @home mounted at /home"
    log_info "  - @snapshots mounted at /.snapshots"
}

# --- MAIN EXECUTION ---
clear
echo -e "${GREEN}Arch Linux Disk Preparation Script${NC}"
echo -e "${YELLOW}WARNING: This will erase all data on the selected disk!${NC}\n"

select_disk
prepare_disk "$DISK"
partition_disk "$DISK"

if confirm "Continue with filesystem creation?"; then
    create_filesystems "$DISK"
else
    log_error "Operation aborted by user"
    exit 1
fi

exit 0