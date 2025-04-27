CONFIG=./config/build.conf
.include "${CONFIG}"

BASE_URL=${MIRROR}/base.txz
KERNEL_URL=${MIRROR}/kernel.txz

DOWNLOAD_DIR=downloads
WORK_DIR=workspace
ISO_DIR=iso
IMG_OUT=${ISO_DIR}/freebsd.img
ISO_OUT=${ISO_DIR}/freebsd.iso
MD_UNIT=0
DISK_SIZE=2G

INSTALLER_CONFIG=config/installerconfig

.PHONY: all prepare download build_image extract configure make_iso clean distclean

all: prepare download build_image extract configure make_iso

prepare:
	@echo "[*] Creating required directories..."
	mkdir -p ${DOWNLOAD_DIR} ${WORK_DIR} ${ISO_DIR}

download:
	@echo "[*] Downloading FreeBSD base and kernel..."
	@test -f ${DOWNLOAD_DIR}/base.txz || fetch -o ${DOWNLOAD_DIR}/base.txz ${BASE_URL}
	@test -f ${DOWNLOAD_DIR}/kernel.txz || fetch -o ${DOWNLOAD_DIR}/kernel.txz ${KERNEL_URL}

build_image:
	@echo "[*] Creating raw disk image..."
	truncate -s ${DISK_SIZE} ${IMG_OUT}
	mdconfig -a -t vnode -f ${IMG_OUT} -u ${MD_UNIT}

	@echo "Cleaning old partition (if any)..."
	-gpart destroy -F md${MD_UNIT} || true

	@echo "[*] Partitioning disk image..."
	gpart create -s GPT md${MD_UNIT}
	gpart add -t freebsd-boot -s 512K -i 1 md${MD_UNIT}
	gpart add -t freebsd-zfs -a 1M -i 2 md${MD_UNIT}
	gpart bootcode -b /boot/pmbr -p /boot/gptzfsboot -i 1 md${MD_UNIT}

	@echo "[*] Creating ZFS pool..."
	zpool create -o altroot=${WORK_DIR} -o bootfs=zroot/ROOT/default zroot /dev/md${MD_UNIT}p2

	@echo "[*] Creating ZFS datasets..."
	zfs create -o mountpoint=none zroot/ROOT
	zfs create -o mountpoint=none zroot/ROOT/default
	zfs create -o mountpoint=/ zroot/ROOT/default/root
	zfs create -o mountpoint=/tmp zroot/tmp
	zfs create -o mountpoint=/usr zroot/usr
	zfs create -o mountpoint=/var zroot/var

	@echo "[*] Mounting ZFS datasets..."
	mount -t zfs zroot/ROOT/default/root ${WORK_DIR}

extract:
	@echo "[*] Extracting base and kernel..."
	tar -xf ${DOWNLOAD_DIR}/base.txz -C ${WORK_DIR}
	tar -xf ${DOWNLOAD_DIR}/kernel.txz -C ${WORK_DIR}

configure:
	@echo "[*] Configuring system files..."
	mkdir -p ${WORK_DIR}/boot ${WORK_DIR}/etc
	cp config/loader.conf ${WORK_DIR}/boot/loader.conf
	cp config/rc.conf ${WORK_DIR}/etc/rc.conf
	cp config/fstab ${WORK_DIR}/etc/fstab
	cp config/pf.conf ${WORK_DIR}/etc/pf.conf

	@echo "[*] Setting up installer autolaunch..."
	echo "/usr/sbin/bsdinstall scripted /installerconfig" > ${WORK_DIR}/etc/rc.local
	chmod +x ${WORK_DIR}/etc/rc.local

	@echo "[*] Unmounting and detaching image..."
	umount ${WORK_DIR}
	mdconfig -d -u ${MD_UNIT}

make_iso:
	@echo "[*] Creating ISO image with boot support..."
	mkdir -p ${ISO_DIR}/cdroot
	mdconfig -a -t vnode -f ${IMG_OUT} -u ${MD_UNIT}
	mount /dev/md${MD_UNIT}p2 ${WORK_DIR}
	cp -R ${WORK_DIR}/* ${ISO_DIR}/cdroot/
	umount ${WORK_DIR}
	mdconfig -d -u ${MD_UNIT}

	@echo "[*] Copying installerconfig..."
	cp ${INSTALLER_CONFIG} ${ISO_DIR}/cdroot/installerconfig

	@echo "[*] Copying distributions..."
	cp ${DOWNLOAD_DIR}/base.txz ${ISO_DIR}/cdroot/
	cp ${DOWNLOAD_DIR}/kernel.txz ${ISO_DIR}/cdroot/

	@echo "[*] Adding boot catalog for CD boot..."
	mkisofs -no-emul-boot -b boot/cdboot -r -J -V "CustomBSD" -o ${ISO_OUT} ${ISO_DIR}/cdroot

clean:
	@echo "[*] Cleaning workspace..."
	-chflags -R noschg ${WORK_DIR} || true
	-umount ${WORK_DIR} || true
	-mdconfig -d -u ${MD_UNIT} || true
	rm -rf ${WORK_DIR}

distclean: clean
	rm -rf ${DOWNLOAD_DIR} ${ISO_DIR}
