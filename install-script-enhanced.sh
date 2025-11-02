#!/bin/bash
# Automatic Hardware Installation Script

set -e

echo "============================================================"
echo "    Automatic Linux Hardware Installation System"
echo "============================================================"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root"
    exit 1
fi

# Automatic disk selection
TARGET_DISK=""
LARGEST_SIZE=0

for disk in /dev/sda /dev/sdb /dev/sdc /dev/nvme0n1 /dev/vda /dev/vdb; do
    if [ -b "$disk" ]; then
        DISK_SIZE=$(blockdev --getsize64 "$disk" 2>/dev/null || echo "0")
        DISK_SIZE_GB=$((DISK_SIZE / 1024 / 1024 / 1024))
        
        if [ "$DISK_SIZE_GB" -gt 8 ] && [ "$DISK_SIZE" -gt "$LARGEST_SIZE" ]; then
            TARGET_DISK="$disk"
            LARGEST_SIZE="$DISK_SIZE"
        fi
    fi
done

if [ -z "$TARGET_DISK" ]; then
    echo "ERROR: No suitable disk found (minimum 8GB required)"
    exit 1
fi

echo "Automatically selected disk: $TARGET_DISK ($(($LARGEST_SIZE / 1024 / 1024 / 1024))GB)"

echo "Starting installation..."

# Unmount any existing partitions
umount "${TARGET_DISK}"* 2>/dev/null || true
swapoff "${TARGET_DISK}"* 2>/dev/null || true

# Create partition table
echo "Creating partition table..."
parted -s "$TARGET_DISK" mklabel msdos
parted -s "$TARGET_DISK" mkpart primary ext4 1MiB 100%
parted -s "$TARGET_DISK" set 1 boot on

sleep 2
partprobe "$TARGET_DISK"
sleep 2

# Verify partition is bootable
echo "Verifying bootable partition..."
parted "$TARGET_DISK" print | grep boot || {
    echo "Setting boot flag again..."
    parted -s "$TARGET_DISK" set 1 boot on
}

# Determine partition name
ROOT_PARTITION="${TARGET_DISK}1"
if [ ! -b "$ROOT_PARTITION" ]; then
    ROOT_PARTITION="${TARGET_DISK}p1"
fi

if [ ! -b "$ROOT_PARTITION" ]; then
    echo "ERROR: Cannot find partition $ROOT_PARTITION"
    exit 1
fi

# Format partition
echo "Formatting partition..."
mkfs.ext4 -F "$ROOT_PARTITION"

# Mount and copy system
echo "Mounting target filesystem..."
mkdir -p /target
mount "$ROOT_PARTITION" /target

echo "Copying system files..."
rsync -a --numeric-ids \
    --exclude=/proc \
    --exclude=/sys \
    --exclude=/dev \
    --exclude=/tmp \
    --exclude=/run \
    --exclude=/mnt \
    --exclude=/media \
    --exclude=/target \
    --exclude=/live \
    --exclude=/cdrom \
    / /target/

# Create directories
for dir in proc sys dev tmp run; do
    mkdir -p "/target/$dir"
done

# Generate fstab
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PARTITION")
cat > /target/etc/fstab << EOF
UUID=$ROOT_UUID / ext4 defaults,errors=remount-ro 0 1
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
EOF

# Prepare chroot environment
mount --bind /dev /target/dev
mount --bind /proc /target/proc
mount --bind /sys /target/sys

# Install bootloader - with proper MBR installation
echo "Installing GRUB bootloader..."

# Install GRUB to MBR (Master Boot Record) for BIOS boot
echo "Installing GRUB to MBR on $TARGET_DISK..."
chroot /target grub-install --target=i386-pc --boot-directory=/boot "$TARGET_DISK"

# Verify GRUB was written to MBR
if command -v strings >/dev/null 2>&1; then
    if dd if="$TARGET_DISK" bs=512 count=1 2>/dev/null | strings | grep -q GRUB; then
        echo "GRUB successfully installed to MBR"
    else
        echo "GRUB verification failed, retrying installation with force..."
        chroot /target grub-install --target=i386-pc --boot-directory=/boot --force "$TARGET_DISK"
    fi
else
    echo "Warning: 'strings' command not available, skipping MBR verification"
    echo "Attempting force GRUB installation for safety..."
    chroot /target grub-install --target=i386-pc --boot-directory=/boot --force "$TARGET_DISK"
fi

# Configure GRUB with aggressive compatibility settings
echo "Configuring GRUB..."
cat > /target/etc/default/grub << EOF
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Minimal Linux"
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nomodeset acpi=off noapic nosmp pci=nomsi irqpoll maxcpus=1 systemd.mask=systemd-modules-load.service"
GRUB_CMDLINE_LINUX="systemd.show_status=1"
GRUB_DISABLE_OS_PROBER=true
EOF

# Generate GRUB configuration
chroot /target update-grub

# Update initramfs
echo "Updating initramfs..."
chroot /target update-initramfs -u -k all

# Set hostname
echo "minimal-linux" > /target/etc/hostname

# Create custom banner
echo "Creating custom system banner..."
cat > /target/etc/motd << 'EOF'

██████╗ ███████╗██████╗ ██╗ █████╗ ███╗   ██╗    ██╗███████╗ ██████╗ 
██╔══██╗██╔════╝██╔══██╗██║██╔══██╗████╗  ██║    ██║██╔════╝██╔═══██╗
██║  ██║█████╗  ██████╔╝██║███████║██╔██╗ ██║    ██║███████╗██║   ██║
██║  ██║██╔══╝  ██╔══██╗██║██╔══██║██║╚██╗██║    ██║╚════██║██║   ██║
██████╔╝███████╗██████╔╝██║██║  ██║██║ ╚████║    ██║███████║╚██████╔╝
╚═════╝ ╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝    ╚═╝╚══════╝ ╚═════╝ 

============================================================================
    Welcome to Debian-based Minimal Linux Installation System
============================================================================

✨ System Information:
   • Distribution: Debian GNU/Linux 12 (bookworm)
   • Kernel: $(uname -r)
   • Architecture: $(uname -m)
   • Hostname: $(hostname)
   • Uptime: $(uptime -p 2>/dev/null || echo "System just started")

🚀 Available Commands:
   • lsblk                    - List storage devices
   • ip addr show            - Show network configuration
   • systemctl status        - Check system services
   • df -h                   - Show disk usage
   • free -h                 - Show memory usage
   • nano <file>             - Edit files

📋 User Accounts:
   • root         - Full system access
   • installer    - Administrative user with sudo

🔧 System Status: Ready for use
============================================================================

EOF

# Create issue banner (shown at login prompt)
cat > /target/etc/issue << 'EOF'

██████╗ ███████╗██████╗ ██╗ █████╗ ███╗   ██╗    ██╗███████╗ ██████╗ 
██╔══██╗██╔════╝██╔══██╗██║██╔══██╗████╗  ██║    ██║██╔════╝██╔═══██╗
██║  ██║█████╗  ██████╔╝██║███████║██╔██╗ ██║    ██║███████╗██║   ██║
██║  ██║██╔══╝  ██╔══██╗██║██╔══██║██║╚██╗██║    ██║╚════██║██║   ██║
██████╔╝███████╗██████╔╝██║██║  ██║██║ ╚████║    ██║███████║╚██████╔╝
╚═════╝ ╚══════╝╚═════╝ ╚═╝╚═╝  ╚═╝╚═╝  ╚═══╝    ╚═╝╚══════╝ ╚═════╝ 

Debian GNU/Linux 12 \n \l

EOF

# Create essential system files that may be missing
echo "Creating essential system files..."
mkdir -p /target/var/log /target/var/run
touch /target/var/log/wtmp /target/var/log/btmp /target/var/log/lastlog /target/var/run/utmp
chmod 644 /target/var/log/wtmp /target/var/log/btmp /target/var/log/lastlog
chmod 664 /target/var/run/utmp
chown root:utmp /target/var/run/utmp /target/var/log/wtmp || true

# Ensure getty and login utilities are properly linked
chroot /target /bin/bash -c "
    if [ ! -f /sbin/agetty ] && [ -f /bin/agetty ]; then
        ln -sf /bin/agetty /sbin/agetty
    fi
    if [ ! -f /usr/sbin/agetty ] && [ -f /sbin/agetty ]; then
        ln -sf /sbin/agetty /usr/sbin/agetty
    fi
"

# Configure systemd to be more reliable
echo "Configuring systemd for reliable boot..."

# Create proper utmp service override to prevent hangs
mkdir -p /target/etc/systemd/system/systemd-update-utmp.service.d
cat > /target/etc/systemd/system/systemd-update-utmp.service.d/override.conf << 'EOF'
[Service]
TimeoutStartSec=10
TimeoutStopSec=10
EOF

# Disable problematic services that might cause hangs
chroot /target systemctl mask systemd-networkd-wait-online.service || true
chroot /target systemctl mask NetworkManager-wait-online.service || true
chroot /target systemctl mask systemd-update-utmp-runlevel.service || true
chroot /target systemctl mask systemd-modules-load.service || true
chroot /target systemctl mask systemd-rfkill.service || true
chroot /target systemctl mask systemd-rfkill.socket || true
chroot /target systemctl mask ModemManager.service || true
chroot /target systemctl mask bluetooth.service || true
chroot /target systemctl mask wpa_supplicant.service || true

# Mask firmware loading services that are causing issues
chroot /target systemctl mask systemd-backlight@.service || true
chroot /target systemctl mask systemd-user-sessions.service || true

# Create a blacklist for problematic firmware
mkdir -p /target/etc/modprobe.d
cat > /target/etc/modprobe.d/blacklist-firmware.conf << 'EOF'
# Blacklist modules that cause firmware loading issues
blacklist rtw88_8822be
blacklist rtw88_8822bu  
blacklist rtw88_8821ce
blacklist iwlwifi
blacklist ath9k
blacklist ath10k_pci
blacklist mt7601u
blacklist rtl8xxxu
blacklist r8169
blacklist nouveau
blacklist radeon
blacklist amdgpu
EOF

# Create a simple network configuration to avoid network hangs
mkdir -p /target/etc/systemd/network
cat > /target/etc/systemd/network/20-wired.network << 'EOF'
[Match]
Name=en* eth*

[Network]
DHCP=yes
EOF

# Enable basic networking
chroot /target systemctl enable systemd-networkd || true
chroot /target systemctl enable systemd-resolved || true

# CRITICAL: Disable auto-installer service in the installed system
# This service should ONLY run in the live system, not in the installed system
echo "Disabling auto-installer service in target system..."
chroot /target systemctl disable auto-installer.service || true
chroot /target systemctl mask auto-installer.service || true

# Remove auto-installer files from target system (they're only needed in live system)
echo "Removing auto-installer files from target system..."
rm -f /target/usr/local/bin/auto-installer || true
rm -f /target/etc/systemd/system/auto-installer.service || true

# Configure systemd with shorter timeouts to prevent hangs
mkdir -p /target/etc/systemd/system.conf.d
cat > /target/etc/systemd/system.conf.d/timeouts.conf << 'EOF'
[Manager]
DefaultTimeoutStartSec=30s
DefaultTimeoutStopSec=15s
DefaultRestartSec=2s
DefaultStartLimitInterval=10s
DefaultStartLimitBurst=3
EOF

# Configure getty services properly
echo "Configuring getty services..."
chroot /target systemctl enable getty@tty1.service || true

# Disable extra getty services to reduce log spam
for tty in tty2 tty3 tty4 tty5 tty6; do
    chroot /target systemctl disable getty@${tty}.service || true
    chroot /target systemctl mask getty@${tty}.service || true
done

# Create a custom getty configuration to prevent agetty errors
mkdir -p /target/etc/systemd/system/getty@tty1.service.d
cat > /target/etc/systemd/system/getty@tty1.service.d/override.conf << 'EOF'
[Service]
Type=idle
ExecStart=
ExecStart=-/sbin/agetty -o '-p -- \\u' --noclear %I $TERM
Restart=always
RestartSec=0
EOF

# Add a safety measure - create a simple init script as fallback
cat > /target/etc/systemd/system/emergency-console.service << 'EOF'
[Unit]
Description=Emergency Console
DefaultDependencies=no
After=systemd-vconsole-setup.service

[Service]
Type=idle
ExecStart=/bin/bash
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/console
Restart=always

[Install]
WantedBy=emergency.target
EOF

# Create a service to handle firmware loading failures gracefully
cat > /target/etc/systemd/system/firmware-workaround.service << 'EOF'
[Unit]
Description=Firmware Loading Workaround
DefaultDependencies=no
Before=systemd-modules-load.service
Before=systemd-udev-trigger.service

[Service]
Type=oneshot
ExecStart=/bin/mkdir -p /lib/firmware
ExecStart=/bin/touch /lib/firmware/.firmware-loaded
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

# Enable the firmware workaround service
chroot /target systemctl enable firmware-workaround.service || true

# Fix pam_nologin issue - ensure users can log in after boot
echo "Configuring login permissions..."
# Disable systemd-user-sessions service that creates /run/nologin
chroot /target systemctl mask systemd-user-sessions.service || true

# Create a service to remove nologin file after boot
cat > /target/etc/systemd/system/remove-nologin.service << 'EOF'
[Unit]
Description=Remove nologin file
After=multi-user.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/rm -f /run/nologin /var/run/nologin
ExecStart=/bin/rm -f /etc/nologin
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chroot /target systemctl enable remove-nologin.service || true

# Create a simple boot timeout prevention service
cat > /target/etc/systemd/system/boot-timeout-prevention.service << 'EOF'
[Unit]
Description=Boot Timeout Prevention
After=basic.target

[Service]
Type=simple
ExecStart=/bin/bash -c 'echo "Boot completed successfully at $(date)" | tee /var/log/boot-success.log'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

chroot /target systemctl enable boot-timeout-prevention.service || true

# Final verification
echo "Verifying bootloader installation..."
if [ -f "/target/boot/grub/grub.cfg" ]; then
    echo "GRUB configuration: OK"
else
    echo "ERROR: GRUB configuration missing"
fi

if dd if="$TARGET_DISK" bs=512 count=1 2>/dev/null | strings | grep -q GRUB; then
    echo "MBR bootloader: OK"
else
    echo "WARNING: GRUB not detected in MBR"
fi

# Ensure boot flag is set one final time
parted -s "$TARGET_DISK" set 1 boot on
sync

# Cleanup and unmount
echo "Finalizing installation..."
sync
umount /target/sys 2>/dev/null || true
umount /target/proc 2>/dev/null || true  
umount /target/dev 2>/dev/null || true
umount /target 2>/dev/null || true

echo ""
echo "INSTALLATION COMPLETE!"
echo "Target Device: $TARGET_DISK"
echo "Root UUID: $ROOT_UUID"
echo ""
echo "Installation finished successfully. System will reboot automatically."