#!/usr/bin/env bash
# ==============================================================================
#  _____                 _    _             ____   _____ 
# | ____|__ _ ___ _   _ | |  | | __ _  ___ / ___| | ____|
# |  _| / _` / __| | | || |__| |/ _` |/ _ \___ \ |  _|  
# | |__| (_| \__ \ |_| ||  __  | (_| | (_) |___) || |___ 
# |_____\__,_|___/\__, ||_|  |_|\__,_|\___/|____/ |_____|
#                 |___/                                   
#
# Easy-HAOS ISO Builder (Alpine Linux x86_64 Hybrid UEFI+BIOS)
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
    for cmd in xorriso mformat grub-mkrescue grub-mkstandalone cpio xz curl tar; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [ ${#missing[@]} -gt 0 ] || [ ! -d /usr/lib/grub/i386-pc ] || [ ! -d /usr/lib/grub/x86_64-efi ]; then
        if command -v apt-get >/dev/null 2>&1; then
            log "Installing missing host build tools via apt-get..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq \
                xorriso mtools grub2-common grub-pc-bin grub-efi-amd64-bin \
                cpio xz-utils curl jq tar ca-certificates
        else
            err "Missing required host commands: ${missing[*]}. Please install xorriso, mtools, grub-pc-bin, grub-efi-amd64-bin, cpio, xz, curl."
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

    local apk_ver
    apk_ver=$(tar -xzO -f "$index_file" APKINDEX | awk '/^P:apk-tools-static$/{p=1} p && /^V:/{sub(/^V:/,""); print; exit}')
    [ -n "$apk_ver" ] || err "Could not determine apk-tools-static version from Alpine APKINDEX."

    local apk_pkg="apk-tools-static-${apk_ver}.apk"
    log "Downloading ${apk_pkg}..."
    curl -fsSL "${ALPINE_MIRROR}/${ALPINE_VERSION}/main/${ARCH}/${apk_pkg}" -o "${TOOLS_DIR}/${apk_pkg}"
    tar -xzf "${TOOLS_DIR}/${apk_pkg}" -C "$TOOLS_DIR" sbin/apk.static
    chmod +x "${TOOLS_DIR}/sbin/apk.static"
    ok "apk.static (${apk_ver}) ready."
}

# --- Step 2: Bootstrap Alpine Rootfs ---
# "Grabbing packages - injecting Linux networking and disk magic into RAM"
build_rootfs() {
    log "Cleaning previous workspace in ${WORK_DIR}..."
    rm -rf "$ROOTFS_DIR" "$ISO_DIR"
    mkdir -p "$ROOTFS_DIR" "$ISO_DIR"

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
        agetty \
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
        kbd

    ok "Alpine rootfs packages installed."

    # Prune huge non-network firmware blobs from linux-firmware-other so the ISO stays compact (<200MB)
    # while keeping Intel Wi-Fi (iwlwifi*, intel/ibt*) and all wired/wireless NIC firmware intact!
    log "Trimming non-network GPU/DSP/camera blobs from /lib/firmware to keep ISO lean..."
    if [ -d "${ROOTFS_DIR}/lib/firmware" ]; then
        local fw_keep="${WORK_DIR}/fw_keep"
        mkdir -p "$fw_keep"
        # Preserve Intel Wi-Fi & BT, Realtek Ethernet/Wi-Fi, Broadcom, MediaTek, Intel NICs, and license files
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
    fi

    # Strip unnecessary documentation, headers, apk cache, and initramfs backup inside rootfs
    rm -rf "${ROOTFS_DIR}/var/cache/apk"/* \
           "${ROOTFS_DIR}/usr/share/man"/* \
           "${ROOTFS_DIR}/usr/share/doc"/* \
           "${ROOTFS_DIR}/boot/initramfs-lts"

    # Extract kernel & generate module dependencies inside chroot
    local kver
    kver=$(ls "${ROOTFS_DIR}/lib/modules" | head -n 1)
    [ -n "$kver" ] || err "Kernel modules directory not found in rootfs!"
    log "Detected Alpine LTS kernel version: ${kver}"

    # Configure DNS for chroot tasks and target live network fallback
    cat > "${ROOTFS_DIR}/etc/resolv.conf" << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

    chroot "$ROOTFS_DIR" /sbin/depmod -a "$kver"
    chroot "$ROOTFS_DIR" /usr/sbin/update-ca-certificates 2>/dev/null || true

    # Fallback: ensure gum is executable; if apk gum wasn't installed, fetch static binary from Charmbracelet
    if [ ! -x "${ROOTFS_DIR}/usr/bin/gum" ] && [ ! -x "${ROOTFS_DIR}/usr/local/bin/gum" ]; then
        warn "gum binary missing from apk; downloading static release from GitHub..."
        local gum_url
        gum_url=$(curl -fsSL https://api.github.com/repos/charmbracelet/gum/releases/latest \
            | jq -r '.assets[] | select(.name | test("Linux_x86_64\\.tar\\.gz$")) | .browser_download_url' | head -n 1)
        if [ -n "$gum_url" ]; then
            curl -fsSL "$gum_url" -o "${TOOLS_DIR}/gum.tar.gz"
            mkdir -p "${TOOLS_DIR}/gum_ext"
            tar -xzf "${TOOLS_DIR}/gum.tar.gz" -C "${TOOLS_DIR}/gum_ext"
            local gum_bin
            gum_bin=$(find "${TOOLS_DIR}/gum_ext" -type f -name gum | head -n 1)
            [ -n "$gum_bin" ] && install -m 0755 "$gum_bin" "${ROOTFS_DIR}/usr/local/bin/gum"
        fi
    fi

    ok "Rootfs kernel modules & firmware prepared."
}

# --- Step 3: Inject Easy-HAOS Installer & Boot Configuration ---
configure_live_system() {
    log "Injecting Easy-HAOS installer scripts & tty1 auto-login configuration..."

    mkdir -p "${ROOTFS_DIR}/usr/local/bin" "${ROOTFS_DIR}/etc/init.d" "${ROOTFS_DIR}/mnt" "${ROOTFS_DIR}/media"

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

    # Ensure root has bash shell and passwordless login for local tty consoles
    sed -i 's|^root:.*|root::0:0:root:/root:/bin/bash|' "${ROOTFS_DIR}/etc/passwd"
    sed -i 's|^root:[^:]*:|root::|' "${ROOTFS_DIR}/etc/shadow" 2>/dev/null || true

    # BusyBox inittab: auto-login directly into easy-haos-autostart.sh on tty1!
    cat > "${ROOTFS_DIR}/etc/inittab" << 'EOF'
# Easy-HAOS BusyBox inittab
# "Start GUI installation - I have no idea how I got this to work"
::sysinit:/etc/init.d/rcS
tty1::respawn:/sbin/agetty --autologin root --noclear --login-program /usr/local/bin/easy-haos-autostart.sh 38400 tty1 linux
tty2::askfirst:/bin/bash
tty3::askfirst:/bin/bash
::ctrlaltdel:/sbin/reboot
::shutdown:/bin/umount -a -r
EOF

    # Boot initialization script (udevd, coldplug drivers, efivarfs, network DHCP)
    cat > "${ROOTFS_DIR}/etc/init.d/rcS" << 'EOF'
#!/bin/sh
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

hostname -F /etc/hostname 2>/dev/null || hostname easy-haos

# Start eudev for automatic NVMe, SATA, USB, and NIC detection
/sbin/udevd --daemon 2>/dev/null || true
udevadm trigger --type=subsystems --action=add 2>/dev/null || true
udevadm trigger --type=devices --action=add 2>/dev/null || true
udevadm settle --timeout=10 2>/dev/null || true

# Coldplug hardware modalias sweep + explicit storage/USB/HID drivers
for mod in nvme ahci sd_mod usb_storage uas usbhid hid_generic efivarfs vfat ext4 nls_cp437 nls_utf8; do
    modprobe -q "$mod" 2>/dev/null || true
done
find /sys/devices -name modalias -print0 2>/dev/null | xargs -0 sort -u 2>/dev/null | xargs -r modprobe -abq 2>/dev/null || true

# Bring up loopback and wired interfaces in background
ip link set lo up 2>/dev/null || true
for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(eth|en|eno|enp)'); do
    ip link set "$iface" up 2>/dev/null || true
done
dhcpcd -b -q >/dev/null 2>&1 || true
EOF
    chmod +x "${ROOTFS_DIR}/etc/init.d/rcS"

    # RAM-root PID 1 /init script
    cat > "${ROOTFS_DIR}/init" << 'EOF'
#!/bin/sh
# Easy-HAOS Live RAM-Root Init
# "Mounting pseudo-filesystems and hoping PID 1 doesn't panic"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

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

exec /sbin/init
EOF
    chmod +x "${ROOTFS_DIR}/init"

    ok "Live rootfs init & tty1 autologin configured."
}

# --- Step 4: Pack Kernel, Initramfs & Hybrid UEFI+BIOS ISO ---
package_iso() {
    log "Packing kernel and RAM-root initramfs..."
    mkdir -p "${ISO_DIR}/boot/grub" "${ISO_DIR}/EFI/BOOT"

    # Copy Alpine LTS kernel
    [ -f "${ROOTFS_DIR}/boot/vmlinuz-lts" ] || err "vmlinuz-lts missing from rootfs!"
    cp "${ROOTFS_DIR}/boot/vmlinuz-lts" "${ISO_DIR}/boot/vmlinuz"
    rm -f "${ROOTFS_DIR}/boot/vmlinuz-lts"

    # Pack initramfs (cpio + xz with crc32 for kernel compatibility)
    (
        cd "$ROOTFS_DIR"
        find . -print0 | cpio --null -o --format=newc --quiet | xz --check=crc32 -T0 -6 > "${ISO_DIR}/boot/initrd.img"
    )
    ok "Initramfs packed: $(du -h "${ISO_DIR}/boot/initrd.img" | cut -f1)"

    # Install GRUB config and USB marker file
    cp "${SCRIPT_DIR}/grub.cfg" "${ISO_DIR}/boot/grub/grub.cfg"
    touch "${ISO_DIR}/.easy-haos-usb"

    # Create standalone BOOTX64.EFI in /EFI/BOOT/ so Rufus FAT32 extraction mode ALSO boots cleanly!
    log "Generating standalone UEFI bootloader (/EFI/BOOT/BOOTX64.EFI)..."
    local efi_stub_cfg="${WORK_DIR}/efi-stub.cfg"
    cat > "$efi_stub_cfg" << 'EOF'
search --no-floppy --file --set=root /.easy-haos-usb
configfile /boot/grub/grub.cfg
EOF
    grub-mkstandalone \
        -O x86_64-efi \
        -o "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" \
        "boot/grub/grub.cfg=${efi_stub_cfg}"

    # Build hybrid BIOS + UEFI ISO image via grub-mkrescue (uses xorriso + mtools, no loop mount needed)
    log "Generating hybrid UEFI+BIOS bootable ISO: ${OUTPUT_ISO}..."
    rm -f "$OUTPUT_ISO"
    grub-mkrescue \
        -o "$OUTPUT_ISO" \
        "$ISO_DIR" \
        -- -volid "EASY_HAOS"

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
