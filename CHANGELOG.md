# Changelog

All notable changes to **Easy-HAOS** (`easy-haos-installer`) will be documented in this file.

## [Unreleased]

### Added
- **SSD S.M.A.R.T. Health Check (`smartmontools` / `smartctl`):** Inspects internal SSD/NVMe drives during target selection and displays health status (`PASSED` / `WARN` / `FAILED`), temperature, power-on hours, NVMe wear level, and bad/reallocated sector alerts inside the Confirmation Card.
- **Scannable Completion QR Code (`libqrencode-tools` / `qrencode`):** Renders a scannable UTF-8 QR code on the completion screen pointing straight to `http://<LAN_IP>:8123` (or `http://homeassistant.local:8123`) for instant mobile onboarding.
- **Animated 5-Step Appliance TUI & Red `[ ✗ ]` Diagnostic Error Screen:** Upgraded `src/installer.sh` with animated progress spinners, live `[ ✓ ]`/`[ ! ]`/`[ ✗ ]` diagnostic cards, captured stderr logs, interactive recovery options, UTF-8 `eurlatgr` console font (`kbd-misc`), NTP clock sync (`ntpd`), and Pure-UEFI ISO output.
- **Smart HAOS Release Filtering:** Queries `releases?per_page=10` to skip board-specific hotfixes (e.g. RPi/Yellow-only releases like `18.5`) and verifies the `haos_generic-x86-64-*.img.xz` download URL before touching target disks.

## [1.0.0] - Initial Release

### Added
- **Alpine Linux x86_64 Hybrid ISO (`build/build-iso.sh`):** Loop-mount-free RAM-root live ISO builder producing a compact (<250 MB) hybrid UEFI + Legacy BIOS image compatible with BalenaEtcher, Rufus (ISO & DD modes), and Ventoy.
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
