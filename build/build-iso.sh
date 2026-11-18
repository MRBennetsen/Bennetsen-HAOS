#!/usr/bin/env bash
# ==============================================================================
#  _____                 _   _    _    ___  ____  
# | ____|__ _ ___ _   _ | | | |  / \  / _ \/ ___| 
# |  _| / _` / __| | | || |_| | / _ \| | | \___ \ 
# | |__| (_| \__ \ |_| ||  _  |/ ___ \ |_| |___) |
# |_____\__,_|___/\__, ||_| |_/_/   \_\___/|____/ 
#                 |___/                           
#
# Easy-HAOS ISO Builder (Alpine Linux x86_64 Pure UEFI)
#
# Christian Bennetsen | https://bennetsen.dk | christian@bennetsen.dk
# YouTube: https://www.youtube.com/@BennetsenTech
# LinkedIn: https://www.linkedin.com/in/mrbennetsen/
# ==============================================================================
# ISO Builder - "If this fails, it's definitely Alpine's fault, not mine."
# ==============================================================================

set -euo pipefail

# --- Configuration ---
ALPINE_VERSION="${ALPINE_VERSION:-v3.20}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ARCH="x86_64"
ISO_NAME="${ISO_NAME:-easy-haos-installer-x86_64.iso}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_DIR="${WORK_DIR:-/tmp/easy-haos-build}"
ROOTFS_DIR="${WORK_DIR}/rootfs"
ISO_DIR="${WORK_DIR}/iso"
TOOLS_DIR="${WORK_DIR}/tools"
OUTPUT_ISO="${REPO_ROOT}/${ISO_NAME}"

# Colors
C_RESET="\033[0m"
C_CYAN="\033[1;36m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_RED="\033[1;31m"

log()  { echo -e "${C_CYAN}[build-iso]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}[✓]${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}[!]${C_RESET} $*"; }
err()  { echo -e "${C_RED}[✗]${C_RESET} $*" >&2; exit 1; }

# --- Pre-Flight Root & Host Dependency Check ---
if [ "$(id -u)" -ne 0 ]; then
    err "Please run build-iso.sh as root (e.g. sudo ./build/build-iso.sh) so apk.static and chroot permissions work cleanly."
fi

install_host_deps() {
    local missing=()
    for cmd in xorriso mformat mcopy mkfs.vfat grub-mkstandalone cpio gzip xz curl tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ] || [ ! -d /usr/lib/grub/x86_64-efi ]; then
        if command -v apt-get >/dev/null 2>&1; then
            log "Installing missing host build tools via apt-get..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq \
                xorriso mtools dosfstools grub2-common grub-efi-amd64-bin \
                cpio gzip xz-utils curl jq tar ca-certificates
        else
            err "Missing required host commands/files: ${missing[*]}. Please install xorriso, mtools, dosfstools, grub2-common, grub-efi-amd64-bin, cpio, gzip, xz, curl."
        fi
    fi
    ok "Host build dependencies verified."
}

cleanup() {
    # Unmount any lingering pseudo-filesystems just in case
    for m in dev/pts dev proc sys; do
        if mountpoint -q "${ROOTFS_DIR}/${m}" 2>/dev/null; then
            umount -lf "${ROOTFS_DIR}/${m}" 2>/dev/null || true
        fi
    done
}
trap cleanup EXIT

# --- Step 1: Fetch apk.static Dynamically ---
# "Downloading apk.static - bootstrapping an entire OS in 2MB, black magic."
fetch_apk_static() {
    log "Resolving latest apk-tools-static from ${ALPINE_MIRROR}/${ALPINE_VERSION}/main/${ARCH}..."
    mkdir -p "$TOOLS_DIR"
    local index_file="${TOOLS_DIR}/APKINDEX.tar.gz"
    curl -fsSL "${ALPINE_MIRROR}/${ALPINE_VERSION}/main/${ARCH}/APKINDEX.tar.gz" -o "$index_file"
    tar -xzf "$index_file" -C "$TOOLS_DIR" APKINDEX

    local apk_ver
    apk_ver=$(awk '/^P:apk-tools-static$/{p=1} p && /^V:/{sub(/^V:/,""); print; exit}' "${TOOLS_DIR}/APKINDEX")
    [ -n "$apk_ver" ] || err "Could not determine apk-tools-static version from Alpine APKINDEX."

    local apk_pkg="apk-tools-static-${apk_ver}.apk"
    log "Downloading ${apk_pkg}..."
    curl -fsSL "${ALPINE_MIRROR}/${ALPINE_VERSION}/main/${ARCH}/${apk_pkg}" -o "${TOOLS_DIR}/${apk_pkg}"
    tar -xzf "${TOOLS_DIR}/${apk_pkg}" -C "$TOOLS_DIR" sbin/apk.static 2>/dev/null || true
    [ -x "${TOOLS_DIR}/sbin/apk.static" ] || err "Failed to extract sbin/apk.static from ${apk_pkg}."
    chmod +x "${TOOLS_DIR}/sbin/apk.static"
    ok "apk.static (${apk_ver}) ready."
}

# --- Step 2: Bootstrap Alpine Rootfs ---
# "Grabbing packages - injecting Linux networking and disk magic into RAM"
build_rootfs() {
    log "Cleaning previous workspace in ${WORK_DIR}..."
    cleanup
    rm -rf "$ROOTFS_DIR" "$ISO_DIR"
    mkdir -p "$ROOTFS_DIR" "$ISO_DIR"
    mkdir -p "${ROOTFS_DIR}/etc/mkinitfs" "${ROOTFS_DIR}/proc" "${ROOTFS_DIR}/sys" "${ROOTFS_DIR}/dev"

    # Disable Alpine's mkinitfs trigger so it doesn't build a redundant initramfs during install;
    # configure DNS upfront for chroot tasks and target live network fallback.
    echo 'disable_trigger="yes"' > "${ROOTFS_DIR}/etc/mkinitfs/mkinitfs.conf"
    cat > "${ROOTFS_DIR}/etc/resolv.conf" << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    mount --bind /proc "${ROOTFS_DIR}/proc"
    mount --bind /sys "${ROOTFS_DIR}/sys"
    mount --bind /dev "${ROOTFS_DIR}/dev"

    log "Bootstrapping Alpine ${ALPINE_VERSION} (${ARCH}) root filesystem..."
    "${TOOLS_DIR}/sbin/apk.static" \
        --arch "$ARCH" \
        -X "${ALPINE_MIRROR}/${ALPINE_VERSION}/main" \
        -X "${ALPINE_MIRROR}/${ALPINE_VERSION}/community" \
        -U --allow-untrusted \
        --root "$ROOTFS_DIR" \
        --initdb add \
        alpine-base \
        linux-lts \
        linux-firmware-intel \
        linux-firmware-rtl_nic \
        linux-firmware-rtlwifi \
        linux-firmware-rtw88 \
        linux-firmware-rtw89 \
        linux-firmware-e100 \
        linux-firmware-bnx2 \
        linux-firmware-brcm \
        linux-firmware-mediatek \
        linux-firmware-other \
        bash \
        curl \
        jq \
        xz \
        pv \
        dialog \
        gum \
        mokutil \
        util-linux \
        lsblk \
        wipefs \
        findmnt \
        blkid \
        parted \
        efibootmgr \
        dosfstools \
        e2fsprogs \
        eudev \
        kmod \
        iproute2 \
        dhcpcd \
        wpa_supplicant \
        iw \
        wireless-tools \
        ca-certificates \
        kbd \
        kbd-misc \
        smartmontools \
        libqrencode-tools

    ok "Alpine rootfs packages installed."

    # Prune huge non-network firmware blobs (GPU, DSP, 100GbE ice DDP, Bluetooth)
    # so initrd stays light and fast while keeping Intel Wi-Fi (iwlwifi*) & NIC firmware intact.
    log "Trimming non-network firmware blobs from /lib/firmware..."
    if [ -d "${ROOTFS_DIR}/lib/firmware" ]; then
        local fw_keep="${WORK_DIR}/fw_keep"
        mkdir -p "$fw_keep"
        for pattern in iwlwifi* intel rtl_nic rtlwifi rtw88 rtw89 e100 bnx2 bnx2x brcm mediatek ath* mt7* LICENCE* LICENSE*; do
            for match in "${ROOTFS_DIR}/lib/firmware"/${pattern}; do
                if [ -e "$match" ]; then
                    cp -a "$match" "$fw_keep/"
                fi
            done
        done
        rm -rf "${ROOTFS_DIR}/lib/firmware"/*
        cp -a "$fw_keep"/* "${ROOTFS_DIR}/lib/firmware/" 2>/dev/null || true
        rm -rf "$fw_keep"
        # Drop huge Intel 100GbE switch DDP (~60MB) & Bluetooth firmware (~15MB)
        rm -rf "${ROOTFS_DIR}/lib/firmware/intel/ice" \
               "${ROOTFS_DIR}/lib/firmware/intel/ibt"*
    fi

    # Keep only UTF-8 eurlatgr & default8x16 console fonts (~25KB) to preserve crisp TUI glyphs
    if [ -d "${ROOTFS_DIR}/usr/share/consolefonts" ]; then
        find "${ROOTFS_DIR}/usr/share/consolefonts" -type f \
            ! -name 'eurlatgr*' ! -name 'default8x16*' -delete 2>/dev/null || true
    fi

    # Strip docs, caches, System.map, config, and unused initramfs backup
    rm -rf "${ROOTFS_DIR}/var/cache/apk"/* \
           "${ROOTFS_DIR}/usr/share/man"/* \
           "${ROOTFS_DIR}/usr/share/doc"/* \
           "${ROOTFS_DIR}/boot/initramfs-lts" \
           "${ROOTFS_DIR}/boot/System.map-"* \
           "${ROOTFS_DIR}/boot/config-"*

    # Extract kernel version & prune bulky unused driver trees (GPU/DRM, sound, watchdog, media)
    # This avoids i915/watchdog crashes on Haswell/M93p UEFI systems and shrinks initrd drastically.
    local kver
    kver=$(ls "${ROOTFS_DIR}/lib/modules" | sed -n '1p')
    [ -n "$kver" ] || err "Kernel modules directory not found in rootfs!"
    log "Detected Alpine LTS kernel version: ${kver}"

    local kmod_dir="${ROOTFS_DIR}/lib/modules/${kver}/kernel"
    if [ -d "$kmod_dir" ]; then
        log "Pruning bulky vendor GPU/media/watchdog/sound/SAN kernel modules (keeping simpledrm)..."
        rm -rf \
            "${kmod_dir}/drivers/gpu/drm/amd" \
            "${kmod_dir}/drivers/gpu/drm/nouveau" \
            "${kmod_dir}/drivers/gpu/drm/i915" \
            "${kmod_dir}/drivers/gpu/drm/radeon" \
            "${kmod_dir}/drivers/gpu/drm/xe" \
            "${kmod_dir}/drivers/gpu/drm/msm" \
            "${kmod_dir}/drivers/gpu/drm/tegra" \
            "${kmod_dir}/drivers/media" \
            "${kmod_dir}/drivers/watchdog" \
            "${kmod_dir}/drivers/infiniband" \
            "${kmod_dir}/drivers/isdn" \
            "${kmod_dir}/drivers/staging" \
            "${kmod_dir}/sound" \
            "${kmod_dir}/drivers/bluetooth" \
            "${kmod_dir}/net/bluetooth" \
            "${kmod_dir}/fs/ceph" \
            "${kmod_dir}/fs/smb" \
            "${kmod_dir}/fs/nfsd" \
            "${kmod_dir}/fs/ocfs2" \
            "${kmod_dir}/fs/gfs2"
    fi

    chroot "$ROOTFS_DIR" /bin/busybox --install -s 2>/dev/null || true
    chroot "$ROOTFS_DIR" /sbin/depmod -a "$kver"
    chroot "$ROOTFS_DIR" /usr/sbin/update-ca-certificates 2>/dev/null || true

    # Unmount pseudo-filesystems right after chroot work so cpio never traverses host mounts
    cleanup

    # Fallback: ensure gum is executable; if apk gum wasn't installed, fetch static binary from Charmbracelet
    if [ ! -x "${ROOTFS_DIR}/usr/bin/gum" ] && [ ! -x "${ROOTFS_DIR}/usr/local/bin/gum" ]; then
        warn "gum binary missing from apk; downloading static release from GitHub..."
        local gum_url
        gum_url=$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest \
            | jq -r '[.assets[] | select(.name | test("Linux_x86_64\\.tar\\.gz$")) | .browser_download_url][0] // empty')
        if [ -n "$gum_url" ]; then
            curl -fsSL "$gum_url" -o "${TOOLS_DIR}/gum.tar.gz"
            mkdir -p "${TOOLS_DIR}/gum_ext"
            tar -xzf "${TOOLS_DIR}/gum.tar.gz" -C "${TOOLS_DIR}/gum_ext"
            local gum_bin
            gum_bin=$(find "${TOOLS_DIR}/gum_ext" -type f -name gum | sed -n '1p')
            [ -n "$gum_bin" ] && install -m 0755 "$gum_bin" "${ROOTFS_DIR}/usr/local/bin/gum"
        fi
    fi

    ok "Rootfs kernel modules & firmware prepared."
}

# --- Step 3: Inject Easy-HAOS Installer & Bulletproof PID 1 /init ---
configure_live_system() {
    log "Injecting Easy-HAOS installer scripts & PID 1 /init..."

    mkdir -p "${ROOTFS_DIR}/usr/local/bin" "${ROOTFS_DIR}/mnt" "${ROOTFS_DIR}/media"

    install -m 0755 "${REPO_ROOT}/src/installer.sh" "${ROOTFS_DIR}/usr/local/bin/installer.sh"
    install -m 0755 "${REPO_ROOT}/src/easy-haos-autostart.sh" "${ROOTFS_DIR}/usr/local/bin/easy-haos-autostart.sh"
    ln -sf /usr/local/bin/installer.sh "${ROOTFS_DIR}/usr/local/bin/installer"

    # Set hostname & branding banner
    echo "easy-haos" > "${ROOTFS_DIR}/etc/hostname"
    cat > "${ROOTFS_DIR}/etc/hosts" << 'EOF'
127.0.0.1   localhost easy-haos
::1         localhost easy-haos
EOF

    cat > "${ROOTFS_DIR}/etc/motd" << 'EOF'
====================================================================
 Easy-HAOS Live Environment (Alpine Linux x86_64)
 Author  : Christian Bennetsen (https://bennetsen.dk)
 Email   : christian@bennetsen.dk
 YouTube : https://www.youtube.com/@BennetsenTech
 LinkedIn: https://www.linkedin.com/in/mrbennetsen/

 Type 'installer' to launch the Home Assistant OS Installer.
====================================================================
EOF

    # Ensure root has bash shell and passwordless login
    sed -i 's|^root:.*|root::0:0:root:/root:/bin/bash|' "${ROOTFS_DIR}/etc/passwd"
    sed -i 's|^root:[^:]*:|root::|' "${ROOTFS_DIR}/etc/shadow" 2>/dev/null || true

    # Bulletproof PID 1 /init script:
    # Directly manages pseudo-filesystems, udevd, hardware drivers, DHCP, and tty1 loop
    # so PID 1 can never exit or cause an unexpected kernel panic/reboot.
    cat > "${ROOTFS_DIR}/init" << 'EOF'
#!/bin/sh
# Easy-HAOS Live RAM-Root PID 1 Init
# "Start GUI installation - I have no idea how I got this to work"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=linux

# Handle BusyBox reboot/poweroff signals cleanly as PID 1
trap 'sync; /sbin/reboot -f' USR2 TERM INT
trap 'sync; /sbin/poweroff -f' USR1

# 1. Mount core kernel filesystems
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

mkdir -p /dev/pts /dev/shm /run /tmp /var/log /var/run
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true
mount -t tmpfs tmpfs /run 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true

if [ -d /sys/firmware/efi/efivars ]; then
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
fi

# Ensure basic device nodes exist even before udev finishes
[ -c /dev/console ] || mknod -m 600 /dev/console c 5 1
[ -c /dev/null ]    || mknod -m 666 /dev/null c 1 3
[ -c /dev/tty1 ]    || mknod -m 620 /dev/tty1 c 4 1

# Explicitly load simpledrm so simple-framebuffer takes over tty1 immediately
modprobe -q simpledrm 2>/dev/null || true

hostname -F /etc/hostname 2>/dev/null || hostname easy-haos

echo "[Easy-HAOS] Loading hardware & storage drivers..." >/dev/tty1 2>/dev/null || true

# 2. Start udevd and coldplug storage / USB / keyboard / network drivers
/sbin/udevd --daemon 2>/dev/null || true
udevadm trigger --type=subsystems --action=add 2>/dev/null || true
udevadm trigger --type=devices --action=add 2>/dev/null || true
udevadm settle --timeout=10 2>/dev/null || true

for mod in simpledrm nvme ahci sd_mod usb_storage uas usbhid hid_generic efivarfs vfat exfat ntfs3 isofs ext4 nls_cp437 nls_utf8; do
    modprobe -q "$mod" 2>/dev/null || true
done
find /sys/devices -name modalias -print0 2>/dev/null | xargs -0 sort -u 2>/dev/null | xargs -r modprobe -abq 2>/dev/null || true
udevadm settle --timeout=5 2>/dev/null || true

# 3. Bring up loopback and wired interfaces in background
ip link set lo up 2>/dev/null || true
for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(eth|en|eno|enp)'); do
    ip link set "$iface" up 2>/dev/null || true
done
dhcpcd -b -q >/dev/null 2>&1 || true

# 4. Suppress noisy console kernel logs and run Easy-HAOS TUI on tty1 in a non-exiting PID 1 loop
echo 1 > /proc/sys/kernel/printk 2>/dev/null || true
while true; do
    setsid -c /usr/local/bin/easy-haos-autostart.sh </dev/tty1 >/dev/tty1 2>&1 || /usr/local/bin/easy-haos-autostart.sh </dev/tty1 >/dev/tty1 2>&1 || true
    sleep 1
done
EOF
    chmod +x "${ROOTFS_DIR}/init"

    ok "Live rootfs init & tty1 launcher configured."
}

# --- Step 4: Pack Kernel, Initramfs & Pure UEFI ISO ---
package_iso() {
    log "Packing kernel and gzip RAM-root initramfs..."
    mkdir -p "${ISO_DIR}/boot" "${ISO_DIR}/EFI/BOOT"

    # Copy Alpine LTS kernel
    [ -f "${ROOTFS_DIR}/boot/vmlinuz-lts" ] || err "vmlinuz-lts missing from rootfs!"
    cp "${ROOTFS_DIR}/boot/vmlinuz-lts" "${ISO_DIR}/boot/vmlinuz"
    rm -f "${ROOTFS_DIR}/boot/vmlinuz-lts"

    # Pack initramfs with gzip -9 for fast, low-memory early boot decompression
    (
        cd "$ROOTFS_DIR"
        find . -print0 | cpio --null -o --format=newc --quiet | gzip -9 > "${ISO_DIR}/boot/initrd.img"
    )
    ok "Initramfs packed: $(du -h "${ISO_DIR}/boot/initrd.img" | cut -f1)"

    # Marker file so GRUB standalone and installer.sh always locate the boot USB
    touch "${ISO_DIR}/.easy-haos-usb"

    # 1) Build self-contained UEFI bootloader (grub.cfg embedded inside memdisk; no loose /boot/grub/*.mod!)
    #    This prevents Rufus from offering to overwrite GRUB modules and avoids grub_memcpy errors.
    log "Generating standalone UEFI bootloader (/EFI/BOOT/BOOTX64.EFI)..."
    grub-mkstandalone \
        -O x86_64-efi \
        -o "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" \
        "boot/grub/grub.cfg=${SCRIPT_DIR}/grub.cfg"

    # 2) Build FAT El Torito EFI boot image without loop mounts
    log "Creating El Torito EFI system image (boot/efiboot.img)..."
    local efi_kb img_mb
    efi_kb=$(du -sk "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" | awk '{print $1}')
    img_mb=$(( (efi_kb / 1024) + 8 ))
    [ "$img_mb" -lt 16 ] && img_mb=16

    local efiboot_img="${ISO_DIR}/boot/efiboot.img"
    dd if=/dev/zero of="$efiboot_img" bs=1M count="$img_mb" status=none
    mkfs.vfat -n EASY_EFI "$efiboot_img" >/dev/null
    mmd -i "$efiboot_img" ::/EFI ::/EFI/BOOT
    mcopy -i "$efiboot_img" "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI

    # 3) Build pure UEFI bootable ISO using xorriso directly (no Legacy BIOS / Syslinux popups)
    log "Generating UEFI bootable ISO: ${OUTPUT_ISO}..."
    rm -f "$OUTPUT_ISO"
    xorriso -as mkisofs \
        -o "$OUTPUT_ISO" \
        -volid "EASY_HAOS" \
        -e boot/efiboot.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$ISO_DIR"

    [ -f "$OUTPUT_ISO" ] || err "ISO generation failed: ${OUTPUT_ISO} not found!"
    local iso_size
    iso_size=$(du -h "$OUTPUT_ISO" | cut -f1)
    ok "Successfully built ${OUTPUT_ISO} (${iso_size})!"
}

# --- Main ---
main() {
    log "Starting Easy-HAOS ISO build (Christian Bennetsen | bennetsen.dk)..."
    install_host_deps
    fetch_apk_static
    build_rootfs
    configure_live_system
    package_iso
    log "Done! Flash ${ISO_NAME} using BalenaEtcher, Rufus, or Ventoy."
}

main "$@"
