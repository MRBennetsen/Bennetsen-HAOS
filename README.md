# Easy-HAOS (`easy-haos-installer`)

> *"Plan for this project... We need to make a Home Assistant bootable USB - It cant be that hard. I'm gonna regret this aren't i?"* — Christian Bennetsen

[![Build & Release Easy-HAOS ISO](https://github.com/MRBennetsen/Bennetsen-HAOS/actions/workflows/release-iso.yml/badge.svg)](https://github.com/MRBennetsen/Bennetsen-HAOS/actions/workflows/release-iso.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Easy-HAOS** is a lightweight (<200 MB), foolproof, bootable USB Auto-Installer ISO for installing **Home Assistant OS (HAOS) Generic x86-64** directly onto bare-metal Mini PCs — such as Intel N100 boxes, Intel NUCs, Lenovo ThinkCentre Tiny (M73/M93p/M720q), Dell OptiPlex Micro, HP EliteDesk Mini, and custom x86-64 servers.

---

## Why Easy-HAOS Exists

Installing Home Assistant OS on a generic x86-64 Mini PC traditionally meant:
1. Downloading a massive 4–6 GB Ubuntu Desktop Live ISO.
2. Booting into a full desktop environment just to open a terminal.
3. Downloading the HAOS `.img.xz` image inside the live desktop.
4. Running `lsblk` and praying you don't type the wrong `/dev/nvme0n1` vs `/dev/sda` into `dd`.

**Easy-HAOS eliminates all of that.** Boot from a tiny Alpine Linux USB stick, and the installer launches automatically on the `simpledrm` graphical framebuffer (`tty1`) with a polished, animated 5-step appliance wizard (`gum` + `eurlatgr` UTF-8 console UI) that runs pre-flight diagnostics, syncs your system clock, connects to Ethernet or Wi-Fi, resolves and verifies the newest official HAOS `generic-x86-64` release, locks out your installer USB, streams HAOS straight to your internal SSD/NVMe, and verifies your UEFI boot entry.

---

## Key Features

- **Lean Pure-UEFI ISO (<200 MB):** Built on Alpine Linux `x86_64` with a self-contained standalone GRUB2 UEFI bootloader (`/EFI/BOOT/BOOTX64.EFI`). No Legacy BIOS/ISOLINUX bloat, and **zero Rufus Syslinux/GRUB download popups** — works seamlessly with **BalenaEtcher**, **Rufus** (ISO or DD mode), and **Ventoy**.
- **Animated Appliance TUI & `[ ✓ ]` / `[ ✗ ]` Diagnostics:**
  - Persistent 5-step wizard bar (`1.Pre-Flight → 2.Release → 3.Disk → 4.Flash → 5.Done`) with animated spinners and a live **System Pre-Flight & Diagnostics** status card.
  - Structured red **`[ ✗ ]`** diagnostic error cards that show exact failure details, captured logs, and one-click recovery options (`Retry Installation Wizard`, `Configure Network / Wi-Fi`, `Open Diagnostic Shell`, or `Reboot Machine`).
- **Pre-Flight Firmware & Clock Checks:**
  - Verifies **UEFI mode** and checks **Secure Boot** status (`mokutil` + EFI variables), guiding you cleanly if Secure Boot needs to be disabled.
  - Automatically syncs the system clock via **NTP** (`ntpd`) before contacting GitHub so older Mini PCs with dead CMOS batteries won't hit HTTPS certificate errors.
- **Zero-Friction Networking:** Includes Intel and Realtek wired/wireless firmware (`iwlwifi`, `rtl_nic`, `rtw88`, `rtw89`, `e100`, `brcm`, `mediatek`) plus an interactive Wi-Fi connection menu (`nmcli` / `iwctl` / `wpa_supplicant`) if no Ethernet cable is plugged in.
- **Smart HAOS Release Resolution + Offline Bonus:**
  - Queries the [Home Assistant OS GitHub Releases API](https://api.github.com/repos/home-assistant/operating-system/releases?per_page=10), automatically skipping board-specific hotfix releases (such as Raspberry Pi/Yellow-only point releases like `18.5`) to locate the newest release containing `haos_generic-x86-64-*.img.xz`, and verifies the asset URL (`curl -fsIL`) **before** touching any disk.
  - **Offline Bonus:** Drop any `haos_generic-x86-64-*.img.xz` file onto your Ventoy data partition or USB stick (`exFAT`/`NTFS`/`FAT32`/`ext4`) and Easy-HAOS detects it automatically for offline installs.
- **Foolproof Target Protection:** Dynamically detects the running boot USB stick (via mount source, `EASY_HAOS` / `Ventoy` labels, and the `.easy-haos-usb` marker file) and removes it from the target drive list. Requires typing `YES` in uppercase before touching a single sector.
- **Live Flashing Dashboard & UEFI Verification:** Streams `curl | pv | xz -d | dd` straight onto your NVMe/SSD inside a 4-stage flashing card, followed by `partprobe` and `efibootmgr` NVRAM boot-order verification.

---

## How to Flash & Install

### 1. Download the ISO
Download the latest `easy-haos-installer-x86_64.iso` and `SHA256SUMS` from the [GitHub Releases](https://github.com/MRBennetsen/Bennetsen-HAOS/releases) page.

### 2. Create Your Bootable USB
Choose your favorite flashing tool:

- **BalenaEtcher:**
  1. Select `easy-haos-installer-x86_64.iso`.
  2. Choose your USB flash drive.
  3. Click **Flash!**.
- **Rufus (Windows):**
  1. Select `easy-haos-installer-x86_64.iso`.
  2. Use **GPT / UEFI** (default **ISO Image mode** writes FAT32 with `/EFI/BOOT/BOOTX64.EFI`, and **DD Image mode** also works out of the box).
  3. Click **START**.
- **Ventoy:**
  1. Copy `easy-haos-installer-x86_64.iso` directly onto your Ventoy USB partition.
  2. *(Optional Offline Mode)* Also drop a downloaded `haos_generic-x86-64-X.Y.img.xz` file onto the Ventoy partition to install without internet access.

### 3. Boot Your Mini PC
1. Plug the USB drive (and optionally an Ethernet cable) into your target Mini PC.
2. Enter your BIOS/UEFI Boot Menu (`F12`, `F11`, `F10`, `F8`, or `Del`).
3. Ensure **UEFI Boot** is enabled, **Secure Boot** is **Disabled**, and SATA/Storage mode is set to **AHCI / NVMe** (not Intel RST/RAID).
4. Select the **UEFI** entry for your USB stick.
5. Follow the **Easy-HAOS** wizard on screen!
6. Once finished, unplug the USB stick, select **Reboot Now into Home Assistant OS**, wait ~2–5 minutes for first-boot setup, and open **`http://homeassistant.local:8123`** in your browser.

---

## Transparent CI/CD & Building Locally

Every official release ISO is built transparently from source by [`.github/workflows/release-iso.yml`](.github/workflows/release-iso.yml) on `ubuntu-latest`, with `SHA256SUMS` and automated *"What's New"* release notes published on every `v*` tag push or manual `workflow_dispatch`.

### Repository Layout
```text
.
├── .github/workflows/release-iso.yml  # Automated GitHub Actions ISO builder & release publisher
├── build/
│   ├── build-iso.sh                   # Alpine x86_64 RAM-root + pure UEFI ISO builder
│   └── grub.cfg                       # Standalone GRUB2 UEFI boot menu configuration
├── src/
│   ├── easy-haos-autostart.sh         # tty1 UTF-8 console & auto-launcher wrapper
│   └── installer.sh                   # Animated 5-step TUI installer & diagnostic wizard
├── CHANGELOG.md
├── LICENSE
└── README.md
```

### Building Locally (Ubuntu / Debian)
You can inspect and build the exact same ISO locally on an Ubuntu/Debian machine:

```bash
git clone https://github.com/MRBennetsen/Bennetsen-HAOS.git
cd Bennetsen-HAOS
sudo ./build/build-iso.sh
```

The builder uses `apk.static` + `cpio` (`gzip`) + `grub-mkstandalone` + `mkfs.vfat`/`mtools` + `xorriso` with **zero loop mounts**, meaning it runs smoothly inside CI runners and containers and outputs `easy-haos-installer-x86_64.iso` in the repository root.

---

## Disclaimer & AI Disclosure

**Transparency Note:** AI was used as a pair-programming assistant to help architect and scaffold the Bash scripts, Alpine ISO builder, and CI/CD workflows in this repository (because life is too short to memorize `xorriso` flags from scratch).

**Use at Your Own Risk:** While Easy-HAOS includes safeguards to hide your boot USB and requires typing `YES` in all caps before touching a drive, its entire job is to **permanently erase a disk and install Home Assistant OS**. Always back up any data you care about, double-check the drive model you select, and don't blame me (or the AI) if you nuke your Windows partition. This software is provided "AS IS" under the [MIT License](LICENSE).

---

## Author & Community

Created and maintained by **Christian Bennetsen**.

- **Website:** [bennetsen.dk](https://bennetsen.dk)
- **Email:** [christian@bennetsen.dk](mailto:christian@bennetsen.dk)
- **YouTube:** [@BennetsenTech](https://www.youtube.com/@BennetsenTech)
- **LinkedIn:** [linkedin.com/in/mrbennetsen](https://www.linkedin.com/in/mrbennetsen/)

If Easy-HAOS saved you from flashing another Ubuntu desktop USB, consider starring the repository and subscribing on YouTube!
