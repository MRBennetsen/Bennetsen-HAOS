# Changelog

All notable changes to **Easy-HAOS** (`easy-haos-installer`) will be documented in this file.

## [1.0.0] - Initial Release

### Added
- **Alpine Linux x86_64 Hybrid ISO (`build/build-iso.sh`):** Loop-mount-free RAM-root live ISO builder producing a compact (<200 MB) hybrid UEFI + Legacy BIOS image compatible with BalenaEtcher, Rufus (ISO & DD modes), and Ventoy.
- **Standalone UEFI Bootloader (`BOOTX64.EFI`):** Embedded GRUB2 standalone EFI binary and `.easy-haos-usb` marker file for reliable Rufus FAT32 ISO-mode booting.
- **Interactive TUI Auto-Installer (`src/installer.sh` & `src/easy-haos-autostart.sh`):**
  - Auto-launches on `tty1` via `agetty` autologin using `gum` with graceful fallback to `dialog`, `whiptail`, and ANSI menus.
  - Pre-flight UEFI mode verification (`[ -d /sys/firmware/efi ]`) and Legacy/CSM remediation screen.
  - Secure Boot status detection via `mokutil` and `/sys/firmware/efi/efivars/SecureBoot-*`.
  - Wired Ethernet DHCP renewal and interactive Wi-Fi connection setup (`nmcli`, `iwctl`, or `iw`/`wpa_supplicant`) backed by Intel & Realtek firmware.
  - Dynamic Home Assistant OS Generic x86-64 release discovery via GitHub API with redirect fallback and local USB/Ventoy `.img.xz` offline detection.
  - Dynamic boot USB exclusion and explicit uppercase `YES` confirmation before wiping target storage.
  - Live streaming flash (`curl`/`pv` → `xz -d` → `dd conv=fsync`) with `partprobe` and `efibootmgr` UEFI BootOrder registration.
  - Completion screen displaying local IPv4 addresses, reboot prompt, and Bennetsen branding.
- **Automated CI/CD Release Pipeline (`.github/workflows/release-iso.yml`):** Builds `easy-haos-installer-x86_64.iso`, computes `SHA256SUMS`, generates structured release notes with commit history and build metadata, and publishes GitHub Releases on `v*` tags or `workflow_dispatch`.
