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
	gpart add -t freebsd-ufs -a 1M -i 2 md${MD_UNIT}
	gpart bootcode -b /boot/pmbr -p /boot/gptboot -i 1 md${MD_UNIT}

	@echo "[*] Creating filesystem..."
	newfs -U /dev/md${MD_UNIT}p2

	@echo "[*] Mounting filesystem..."
	mount /dev/md${MD_UNIT}p2 ${WORK_DIR}

extract:
	@echo "[*] Extracting base and kernel..."
	tar -xf ${DOWNLOAD_DIR}/base.txz -C ${WORK_DIR}
	tar -xf ${DOWNLOAD_DIR}/kernel.txz -C ${WORK_DIR}

configure:
	@echo "[*] Configuring system files..."
	mkdir -p ${WORK_DIR}/boot ${WORK_DIR}/etc
	cp config/master.passwd ${WORK_DIR}/etc/master.passwd
	cp config/loader ${WORK_DIR}/boot/loader
	cp config/loader.conf ${WORK_DIR}/boot/loader.conf
	cp config/rc.conf ${WORK_DIR}/etc/rc.conf
	cp config/pf.conf ${WORK_DIR}/etc/pf.conf
	cp config/fstab ${WORK_DIR}/etc/fstab

	@echo "[*] Generating passwd.db and spwd.db using chroot..."
	chroot ${WORK_DIR} pwd_mkdb -d /etc /etc/master.passwd

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

	@echo "[*] Building ISO with bootable CD support..."
	makefs -t cd9660 -o rockridge -o label=CustomBSD ${ISO_OUT} ${ISO_DIR}/cdroot
	cp /boot/cdboot ${ISO_DIR}/cdboot

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
