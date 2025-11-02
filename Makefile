# Minimal Linux ISO Builder with Separated Stages
# Creates bootable ISO for both hardware and virtual machine installation
# Supports separated base system and kernel management

# =============================================================================
# CONFIGURATION
# =============================================================================

WORK_DIR := $(shell pwd)/build
ROOTFS_DIR := $(WORK_DIR)/rootfs
ISO_DIR := $(WORK_DIR)/iso

# Debian configuration
DEBIAN_RELEASE := bookworm
DEBIAN_ARCH := amd64
DEBIAN_MIRROR := http://deb.debian.org/debian

# Output ISO file
OUTPUT_ISO := minimal-installer.iso

# Package management
PACKAGES_FILE := packages.list
BASE_PACKAGES := $(shell cat $(PACKAGES_FILE) 2>/dev/null | grep -v '^\#' | grep -v '^$$' | tr '\n' ',' | sed 's/,$$//')

# =============================================================================
# PHONY TARGETS
# =============================================================================

.PHONY: all clean install-deps check-deps help test
.PHONY: base-system kernel-install integrate-system bootloader squashfs iso
.PHONY: show-packages edit-packages

# =============================================================================
# MAIN TARGETS
# =============================================================================

# Default target - build complete ISO
all: iso

# Build complete ISO
iso: check-deps integrate-system bootloader squashfs create-iso
	@echo ""
	@echo "✅ MINIMAL LINUX ISO BUILD COMPLETE!"
	@echo "=================================="
	@echo "Output: $(OUTPUT_ISO)"
	@echo "Size: $(shell du -sh $(OUTPUT_ISO) 2>/dev/null | cut -f1 || echo 'N/A')"
	@echo ""
	@echo "🚀 Usage:"
	@echo "  - Write to USB: sudo dd if=$(OUTPUT_ISO) of=/dev/sdX bs=4M status=progress"
	@echo "  - Boot from USB: System will auto-install to largest available disk"
	@echo ""
	@echo "🔑 Login credentials:"
	@echo "  - installer/installer (sudo access)"
	@echo "  - root/root"

# =============================================================================
# SEPARATED BUILD STAGES
# =============================================================================

# Stage 1: Create base system (without kernel)
base-system: check-deps
	@echo "🏗️  STAGE 1: Creating base system..."
	@echo "==================================="
	mkdir -p $(ROOTFS_DIR)
	
	@echo "📦 Installing base packages from $(PACKAGES_FILE)..."
	@if [ ! -f "$(PACKAGES_FILE)" ]; then \
		echo "❌ ERROR: Package list file '$(PACKAGES_FILE)' not found!"; \
		echo "Create it with: make edit-packages"; \
		exit 1; \
	fi
	
	debootstrap --arch=$(DEBIAN_ARCH) --variant=minbase \
		--include=$(BASE_PACKAGES) \
		$(DEBIAN_RELEASE) $(ROOTFS_DIR) $(DEBIAN_MIRROR)
	
	@echo "👤 Configuring users and system..."
	# Configure root user
	echo "root:root" | chroot $(ROOTFS_DIR) chpasswd
	
	# Create installer user
	chroot $(ROOTFS_DIR) useradd -m -s /bin/bash -G sudo installer 2>/dev/null || true
	echo "installer:installer" | chroot $(ROOTFS_DIR) chpasswd
	
	# Add installer to sudoers
	cat config-files/sudoers-installer >> $(ROOTFS_DIR)/etc/sudoers
	
	# Set hostname
	cp config-files/hostname $(ROOTFS_DIR)/etc/hostname
	
	@echo "📝 Creating system information..."
	# Create system identification
	cp config-files/live-system $(ROOTFS_DIR)/etc/live-system
	
	# Copy system files from system-files directory
	cp system-files/motd $(ROOTFS_DIR)/etc/motd
	cp system-files/issue $(ROOTFS_DIR)/etc/issue
	cp system-files/issue.net $(ROOTFS_DIR)/etc/issue.net
	echo "" >> $(ROOTFS_DIR)/etc/issue
	echo "Debian GNU/Linux 12 \\n \\l - Live Installation System" >> $(ROOTFS_DIR)/etc/issue
	echo "" >> $(ROOTFS_DIR)/etc/issue
	
	@echo "🌐 Configuring networking..."
	# Configure systemd-networkd
	mkdir -p $(ROOTFS_DIR)/etc/systemd/network
	cp config-files/20-wired.network $(ROOTFS_DIR)/etc/systemd/network/20-wired.network
	
	# Enable networking services
	chroot $(ROOTFS_DIR) systemctl enable systemd-networkd || true
	
	# Configure dhclient as alternative DHCP client
	mkdir -p $(ROOTFS_DIR)/etc/dhcp
	cp config-files/dhclient.conf $(ROOTFS_DIR)/etc/dhcp/dhclient.conf
	
	@echo "🧹 Cleaning up base system..."
	chroot $(ROOTFS_DIR) apt-get clean
	rm -rf $(ROOTFS_DIR)/var/lib/apt/lists/*
	
	@echo "✅ Base system complete: $(shell du -sh $(ROOTFS_DIR) 2>/dev/null | cut -f1)"

# Stage 2: Install and configure kernel
kernel-install: base-system
	@echo "🔧 STAGE 2: Installing and configuring kernel..."
	@echo "==============================================="
	
	@echo "🐧 Updating initramfs..."
	chroot $(ROOTFS_DIR) update-initramfs -u
	
	@echo "🔍 Verifying kernel installation..."
	@if [ ! -f $(ROOTFS_DIR)/boot/vmlinuz-* ]; then \
		echo "❌ ERROR: Kernel not found in $(ROOTFS_DIR)/boot/"; \
		ls -la $(ROOTFS_DIR)/boot/ || true; \
		exit 1; \
	fi
	
	@echo "✅ Kernel installation complete"

# Stage 3: Integrate base system with kernel
integrate-system: kernel-install
	@echo "🔗 STAGE 3: Integrating system components..."
	@echo "==========================================="
	
	@echo "📋 Installing installer script..."
	# Copy installation script
	mkdir -p $(ROOTFS_DIR)/usr/local/bin
	cp install-script-enhanced.sh $(ROOTFS_DIR)/usr/local/bin/install-system
	chmod +x $(ROOTFS_DIR)/usr/local/bin/install-system
	
	@echo "🤖 Installing auto-installer service..."
	# Copy auto-installer script
	cp auto-installer.sh $(ROOTFS_DIR)/usr/local/bin/auto-installer
	chmod +x $(ROOTFS_DIR)/usr/local/bin/auto-installer
	
	# Create systemd service for auto-installer
	mkdir -p $(ROOTFS_DIR)/etc/systemd/system
	cp config-files/auto-installer.service $(ROOTFS_DIR)/etc/systemd/system/auto-installer.service
	
	# Enable the auto-installer service
	chroot $(ROOTFS_DIR) systemctl enable auto-installer.service || true
	
	@echo "⚙️  Final system configuration..."
	# Ensure proper permissions
	chmod 755 $(ROOTFS_DIR)/usr/local/bin/install-system
	
	@echo "✅ System integration complete"

# =============================================================================
# BOOTLOADER CONFIGURATION
# =============================================================================

bootloader: integrate-system
	@echo "🥾 STAGE 4: Setting up bootloader..."
	@echo "==================================="
	
	mkdir -p $(ISO_DIR)/boot/grub $(ISO_DIR)/live
	
	@echo "📁 Copying kernel and initramfs..."
	cp $(shell find $(ROOTFS_DIR)/boot -name "vmlinuz-*" | head -1) $(ISO_DIR)/live/vmlinuz
	cp $(shell find $(ROOTFS_DIR)/boot -name "initrd.img-*" | head -1) $(ISO_DIR)/live/initrd.img
	
	@echo "⚙️  Creating GRUB configuration..."
	cp boot-configs/grub.cfg $(ISO_DIR)/boot/grub/grub.cfg
	
	@echo "⚙️  Creating ISOLINUX configuration..."
	mkdir -p $(ISO_DIR)/isolinux
	cp /usr/lib/ISOLINUX/isolinux.bin $(ISO_DIR)/isolinux/ 2>/dev/null || \
		cp /usr/lib/syslinux/isolinux.bin $(ISO_DIR)/isolinux/
	cp /usr/lib/syslinux/modules/bios/*.c32 $(ISO_DIR)/isolinux/ 2>/dev/null || true
	
	cp boot-configs/isolinux.cfg $(ISO_DIR)/isolinux/isolinux.cfg
	
	@echo "✅ Bootloader configuration complete"

# =============================================================================
# FILESYSTEM AND ISO CREATION
# =============================================================================

# Create SquashFS compressed filesystem
squashfs: integrate-system
	@echo "🗜️  STAGE 5: Creating compressed filesystem..."
	@echo "============================================"
	
	mkdir -p $(ISO_DIR)/live
	mksquashfs $(ROOTFS_DIR) $(ISO_DIR)/live/filesystem.squashfs \
		-comp xz -b 1M -Xdict-size 100%
	
	@echo "✅ SquashFS created: $(shell du -sh $(ISO_DIR)/live/filesystem.squashfs 2>/dev/null | cut -f1)"

# Create final ISO image
create-iso: bootloader squashfs
	@echo "💿 STAGE 6: Creating bootable ISO..."
	@echo "==================================="
	
	xorriso -as mkisofs \
		-iso-level 3 \
		-full-iso9660-filenames \
		-volid "MINIMAL_LINUX" \
		-eltorito-boot isolinux/isolinux.bin \
		-eltorito-catalog isolinux/boot.cat \
		-no-emul-boot \
		-boot-load-size 4 \
		-boot-info-table \
		-o $(OUTPUT_ISO) $(ISO_DIR)
	
	@echo "✅ ISO created successfully"

# =============================================================================
# UTILITY TARGETS
# =============================================================================

# Install build dependencies
install-deps:
	@echo "📦 Installing build dependencies..."
	apt-get update
	apt-get install -y debootstrap squashfs-tools xorriso isolinux syslinux-utils qemu-system-x86_64
	@echo "✅ Dependencies installed"

# Check if dependencies are available
check-deps:
	@echo "🔍 Checking build dependencies..."
	@which debootstrap >/dev/null || (echo "❌ ERROR: Install debootstrap (apt install debootstrap)" && exit 1)
	@which mksquashfs >/dev/null || (echo "❌ ERROR: Install squashfs-tools (apt install squashfs-tools)" && exit 1)
	@which xorriso >/dev/null || (echo "❌ ERROR: Install xorriso (apt install xorriso)" && exit 1)
	@test -f /usr/lib/ISOLINUX/isolinux.bin -o -f /usr/lib/syslinux/isolinux.bin || (echo "❌ ERROR: Install isolinux (apt install isolinux)" && exit 1)
	@echo "✅ All dependencies available"

# Clean build directory
clean:
	@echo "🧹 Cleaning build directory..."
	rm -rf $(WORK_DIR)
	rm -f $(OUTPUT_ISO)
	@echo "✅ Clean complete"

# Test and validate ISO
test: $(OUTPUT_ISO)
	@echo "🧪 Running ISO validation test..."
	@if [ ! -f "$(OUTPUT_ISO)" ]; then \
		echo "❌ ERROR: $(OUTPUT_ISO) not found! Run 'make' first."; \
		exit 1; \
	fi
	@if [ -f "./test-iso.sh" ]; then \
		./test-iso.sh; \
	else \
		echo "⚠️  test-iso.sh not found, performing basic validation..."; \
		echo "✅ ISO File: $(OUTPUT_ISO)"; \
		echo "📦 Size: $(shell du -sh $(OUTPUT_ISO) 2>/dev/null | cut -f1)"; \
		if command -v file >/dev/null 2>&1; then \
			file "$(OUTPUT_ISO)" | grep -q "ISO 9660" && \
			echo "✅ ISO format validation passed" || \
			echo "❌ ISO format validation failed"; \
		fi; \
		echo ""; \
		echo "🔧 For complete testing:"; \
		echo "  VirtualBox: Create VM and mount $(OUTPUT_ISO) as CD"; \
		echo "  USB Drive: sudo dd if=$(OUTPUT_ISO) of=/dev/sdX bs=4M status=progress"; \
	fi

# =============================================================================
# PACKAGE MANAGEMENT
# =============================================================================

# Show current package list
show-packages:
	@echo "📋 Current package list ($(PACKAGES_FILE)):"
	@echo "==========================================="
	@if [ -f "$(PACKAGES_FILE)" ]; then \
		cat -n $(PACKAGES_FILE) | grep -v "^[[:space:]]*$$"; \
	else \
		echo "❌ Package file not found: $(PACKAGES_FILE)"; \
		echo "Create it with: make edit-packages"; \
	fi

# Edit package list
edit-packages:
	@if [ ! -f "$(PACKAGES_FILE)" ]; then \
		echo "📦 Creating default package list..."; \
		cp /dev/null $(PACKAGES_FILE); \
	fi
	@echo "📝 Opening package list editor..."
	@echo "Add one package name per line, use # for comments"
	${EDITOR:-nano} $(PACKAGES_FILE)

# =============================================================================
# HELP AND INFORMATION
# =============================================================================

help:
	@echo "Minimal Linux ISO Builder"
	@echo "========================"
	@echo ""
	@echo "🎯 Main Targets:"
	@echo "  make              Build complete bootable ISO"
	@echo "  make iso          Same as 'make' - build ISO"
	@echo "  make all          Same as 'make' - build ISO"
	@echo ""
	@echo "🔧 Build Stages (can be run separately):"
	@echo "  make base-system     Create base Debian system (Stage 1)"
	@echo "  make kernel-install  Install and configure kernel (Stage 2)" 
	@echo "  make integrate-system Integrate components (Stage 3)"
	@echo "  make bootloader      Setup boot configuration (Stage 4)"
	@echo "  make squashfs        Create compressed filesystem (Stage 5)"
	@echo "  make create-iso      Generate final ISO (Stage 6)"
	@echo ""
	@echo "📦 Package Management:"
	@echo "  make show-packages   Display current package list"
	@echo "  make edit-packages   Edit package list file"
	@echo ""
	@echo "🛠️  Utilities:"
	@echo "  make install-deps    Install required build tools"
	@echo "  make check-deps      Verify dependencies are installed"
	@echo "  make test           Test built ISO with QEMU"
	@echo "  make clean          Clean all build files"
	@echo "  make help           Show this help message"
	@echo ""
	@echo "📁 Files:"
	@echo "  $(PACKAGES_FILE)          Package list (edit to customize)"
	@echo "  $(OUTPUT_ISO)    Output ISO file"
	@echo "  install-script-enhanced.sh  Hardware installer script"
	@echo ""
	@echo "🚀 Quick Start:"
	@echo "  1. make install-deps     (install build tools)"
	@echo "  2. make edit-packages    (customize package list)"
	@echo "  3. make                  (build ISO)"
	@echo "  4. make test            (test with QEMU)"
	@echo ""
	@echo "💿 Usage:"
	@echo "  - Write to USB: sudo dd if=$(OUTPUT_ISO) of=/dev/sdX bs=4M"
	@echo "  - Boot device: Automatic installation starts immediately"
	@echo "  - No user interaction required - system installs and reboots"