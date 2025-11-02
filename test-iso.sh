#!/bin/bash
# ISO Validation Test Script

ISO_FILE="minimal-installer.iso"

echo "ISO VALIDATION TEST"
echo "==================="

# Check if ISO exists
if [ ! -f "$ISO_FILE" ]; then
    echo "ERROR: $ISO_FILE not found!"
    exit 1
fi

echo "ISO File: $ISO_FILE"
echo "Size: $(du -sh $ISO_FILE | cut -f1)"

# Test ISO file integrity
if file "$ISO_FILE" | grep -q "ISO 9660"; then
    echo "ISO file format: Valid"
else
    echo "ISO file format: Invalid"
    exit 1
fi

# Test bootloader files
MOUNT_DIR="/tmp/iso_test_$$"
mkdir -p "$MOUNT_DIR"

if mount -o loop,ro "$ISO_FILE" "$MOUNT_DIR" 2>/dev/null; then
    echo "ISO mount: OK"
    
    if [ -f "$MOUNT_DIR/isolinux/isolinux.bin" ]; then
        echo "ISOLINUX bootloader: OK"
    else
        echo "ISOLINUX bootloader: Missing"
    fi
    
    if [ -f "$MOUNT_DIR/live/vmlinuz" ]; then
        echo "Linux kernel: OK"
    else
        echo "Linux kernel: Missing"
    fi
    
    if [ -f "$MOUNT_DIR/live/initrd.img" ]; then
        echo "Initial ramdisk: OK"
    else
        echo "Initial ramdisk: Missing"
    fi
    
    if [ -f "$MOUNT_DIR/live/filesystem.squashfs" ]; then
        echo "SquashFS filesystem: OK"
        SQUASH_SIZE=$(du -sh "$MOUNT_DIR/live/filesystem.squashfs" | cut -f1)
        echo "Size: $SQUASH_SIZE"
    else
        echo "SquashFS filesystem: Missing"
    fi
    
    if [ -f "$MOUNT_DIR/isolinux/isolinux.cfg" ]; then
        echo "ISOLINUX config: OK"
        if grep -q "boot=live" "$MOUNT_DIR/isolinux/isolinux.cfg"; then
            echo "Live boot parameters: OK"
        else
            echo "Live boot parameters: Missing"
        fi
    else
        echo "ISOLINUX config: Missing"
    fi
    
    umount "$MOUNT_DIR" 2>/dev/null
    rmdir "$MOUNT_DIR" 2>/dev/null
    
    echo ""
    echo "ISO VALIDATION COMPLETE"
    echo ""
    echo "Usage: sudo dd if=$ISO_FILE of=/dev/sdX bs=4M"
    
else
    echo "ERROR: Cannot mount ISO file"
    rmdir "$MOUNT_DIR" 2>/dev/null
    exit 1
fi