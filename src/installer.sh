#!/usr/bin/env bash
# ==============================================================================
#  _____                 _    _             ____   _____ 
# | ____|__ _ ___ _   _ | |  | | __ _  ___ / ___| | ____|
# |  _| / _` / __| | | || |__| |/ _` |/ _ \___ \ |  _|  
# | |__| (_| \__ \ |_| ||  __  | (_| | (_) |___) || |___ 
# |_____\__,_|___/\__, ||_|  |_|\__,_|\___/|____/ |_____|
#                 |___/                                   
#
# Easy-HAOS: Foolproof Home Assistant OS (x86-64) Bare-Metal Installer
#
# Crafted with passion, caffeine, and questionable life choices by:
# Christian Bennetsen
# Email   : christian@bennetsen.dk
# Website : https://bennetsen.dk
# LinkedIn: https://www.linkedin.com/in/mrbennetsen/
# YouTube : https://www.youtube.com/@BennetsenTech
# ==============================================================================
# Start GUI installation - "I have no idea how I got this to work"
# ==============================================================================

set -uo pipefail

# --- ANSI Colors & Formatting ---
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_RED="\033[1;31m"
C_GREEN="\033[1;32m"
C_YELLOW="\033[1;33m"
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_WHITE="\033[1;37m"
C_BG_RED="\033[41m"

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# --- Global State ---
HAOS_LATEST_API="https://api.github.com/repos/home-assistant/operating-system/releases/latest"
HAOS_VERSION=""
HAOS_DOWNLOAD_URL=""
HAOS_ASSET_SIZE=""
HAOS_IMAGE_FILE=""
IS_OFFLINE_IMAGE=false
TARGET_DISK=""
TARGET_SIZE=""
TARGET_MODEL=""
PROTECTED_DISKS=()

# --- TUI Capability Detection ---
# "Using gum if available, falling back to dialog/whiptail like it's 2003"
TUI_BACKEND="ansi"
if command -v gum >/dev/null 2>&1; then
    TUI_BACKEND="gum"
elif command -v dialog >/dev/null 2>&1; then
    TUI_BACKEND="dialog"
elif command -v whiptail >/dev/null 2>&1; then
    TUI_BACKEND="whiptail"
fi

# --- Helper: Banner ---
print_banner() {
    clear
    cat << "EOF"
  _____                 _    _             ____   _____ 
 | ____|__ _ ___ _   _ | |  | | __ _  ___ / ___| | ____|
 |  _| / _` / __| | | || |__| |/ _` |/ _ \___ \ |  _|  
 | |__| (_| \__ \ |_| ||  __  | (_| | (_) |___) || |___ 
 |_____\__,_|___/\__, ||_|  |_|\__,_|\___/|____/ |_____|
                 |___/                                   
EOF
    echo -e "${C_CYAN} Home Assistant OS (Generic x86-64) Bare-Metal Auto-Installer${C_RESET}"
    echo -e "${C_DIM} Christian Bennetsen | https://bennetsen.dk | christian@bennetsen.dk${C_RESET}"
    echo -e "${C_DIM} YouTube: @BennetsenTech | LinkedIn: /in/mrbennetsen${C_RESET}"
    echo -e "${C_BLUE}======================================================================${C_RESET}"
}

# --- Helper: Fatal Error ---
fatal_error() {
    local msg="$1"
    echo -e "\n${C_BG_RED}${C_WHITE} FATAL ERROR ${C_RESET} ${C_RED}${msg}${C_RESET}\n"
    # "Dropping to emergency bash prompt - I'm gonna regret this aren't I?"
    echo -e "${C_YELLOW}Press [ENTER] to drop to an emergency shell, or type 'reboot' to restart.${C_RESET}"
    read -r reply
    if [[ "${reply,,}" == "reboot" ]]; then
        reboot
    fi
    exec /bin/bash
}

# --- Helper: Interactive Choice Menu ---
tui_choose() {
    local header="$1"
    shift
    local options=("$@")

    case "$TUI_BACKEND" in
        gum)
            printf '%s\n' "${options[@]}" | gum choose --header "$header"
            ;;
        dialog)
            local dialog_args=()
            local idx=1
            for opt in "${options[@]}"; do
                dialog_args+=("$idx" "$opt")
                idx=$((idx + 1))
            done
            local chosen_idx
            chosen_idx=$(dialog --clear --title "Easy-HAOS" --menu "$header" 18 74 10 "${dialog_args[@]}" 2>&1 >/dev/tty) || return 1
            clear
            echo "${options[$((chosen_idx - 1))]}"
            ;;
        whiptail)
            local wt_args=()
            local idx=1
            for opt in "${options[@]}"; do
                wt_args+=("$idx" "$opt")
                idx=$((idx + 1))
            done
            local chosen_idx
            chosen_idx=$(whiptail --title "Easy-HAOS" --menu "$header" 18 74 10 "${wt_args[@]}" 3>&1 1>&2 2>&3) || return 1
            clear
            echo "${options[$((chosen_idx - 1))]}"
            ;;
        *)
            echo -e "${C_WHITE}${C_BOLD}${header}${C_RESET}" >&2
            local idx=1
            for opt in "${options[@]}"; do
                echo -e "  ${C_CYAN}${idx})${C_RESET} ${opt}" >&2
                idx=$((idx + 1))
            done
            echo -ne "\nSelect option [1-${#options[@]}]: " >&2
            local choice_idx
            read -r choice_idx
            if [[ "$choice_idx" =~ ^[0-9]+$ ]] && [ "$choice_idx" -ge 1 ] && [ "$choice_idx" -le "${#options[@]}" ]; then
                echo "${options[$((choice_idx - 1))]}"
            else
                return 1
            fi
            ;;
    esac
}

# --- Helper: Confirmation Prompt ---
tui_confirm() {
    local prompt="$1"
    case "$TUI_BACKEND" in
        gum)
            gum confirm "$prompt"
            ;;
        dialog)
            dialog --clear --title "Confirmation" --yesno "$prompt" 10 70 >/dev/tty
            local rc=$?
            clear
            return $rc
            ;;
        whiptail)
            whiptail --title "Confirmation" --yesno "$prompt" 10 70
            local rc=$?
            clear
            return $rc
            ;;
        *)
            echo -ne "${C_WHITE}${prompt} (y/N): ${C_RESET}"
            read -r resp
            [[ "$resp" =~ ^[Yy]$ ]]
            ;;
    esac
}

# ==============================================================================
# STEP 1: Pre-Flight Hardware, BIOS & Network Checks
# ==============================================================================
# Checking UEFI mode - "Please don't be running BIOS from 1998, HAOS will cry"
check_uefi_mode() {
    echo -e "${C_CYAN}[*] Inspecting firmware boot mode...${C_RESET}"
    if [ ! -d /sys/firmware/efi ]; then
        clear
        echo -e "${C_BG_RED}${C_WHITE}${C_BOLD} CRITICAL BOOT ERROR: LEGACY / CSM BIOS MODE DETECTED ${C_RESET}\n"
        cat << "EOF"
  _   _ _____ _____ ___   ____  _____ ___  _   _ ___ ____  _____ ____  
 | | | | ____|  ___|_ _| |  _ \| ____/ _ \| | | |_ _|  _ \| ____|  _ \ 
 | | | |  _| | |_   | |  | |_) |  _|| | | | | | || || |_) |  _| | | | |
 | |_| | |___|  _|  | |  |  _ <| |__| |_| | |_| || ||  _ <| |___| |_| |
  \___/|_____|_|   |___| |_| \_\_____\__\_\\___/|___|_| \_\_____|____/ 
EOF
        echo -e "\n${C_RED}${C_BOLD}Home Assistant OS Generic x86-64 STRICTLY requires UEFI boot mode!${C_RESET}"
        echo -e "${C_YELLOW}Your machine booted in Legacy / CSM mode and cannot boot HAOS after install.${C_RESET}\n"
        echo -e "${C_WHITE}${C_BOLD}How to enable UEFI in your BIOS:${C_RESET}"
        echo -e "  1. Reboot your PC and press ${C_CYAN}Del${C_RESET}, ${C_CYAN}F2${C_RESET}, ${C_CYAN}F10${C_RESET}, or ${C_CYAN}F12${C_RESET} to enter BIOS Setup."
        echo -e "  2. Open the ${C_CYAN}Boot${C_RESET} or ${C_CYAN}Advanced${C_RESET} tab."
        echo -e "  3. ${C_GREEN}ENABLE UEFI Boot${C_RESET} and ${C_RED}DISABLE CSM / Legacy Boot${C_RESET}."
        echo -e "  4. Save & Exit (${C_CYAN}F10${C_RESET}) and boot from the ${C_CYAN}UEFI:${C_RESET} entry for this USB drive.\n"
        echo -e "${C_DIM}Need help? Visit https://bennetsen.dk or youtube.com/@BennetsenTech${C_RESET}\n"

        echo -ne "${C_YELLOW}Press [ENTER] to power off / reboot, or type 'shell' for bash: ${C_RESET}"
        read -r choice
        if [[ "${choice,,}" == "shell" ]]; then
            exec /bin/bash
        fi
        echo -e "${C_YELLOW}Halting safely so you can switch BIOS to UEFI...${C_RESET}"
        reboot || poweroff || halt
        exit 1
    fi
    echo -e "${C_GREEN}[✓] UEFI Mode verified (/sys/firmware/efi present).${C_RESET}"
}

# Secure Boot check - "Microsoft says no, but we say disable it"
check_secure_boot() {
    echo -e "${C_CYAN}[*] Checking Secure Boot status...${C_RESET}"
    local sb_active=false

    if command -v mokutil >/dev/null 2>&1; then
        if mokutil --sb-state 2>/dev/null | grep -iq "enabled"; then
            sb_active=true
        fi
    fi

    if [ "$sb_active" = false ]; then
        for efivar in /sys/firmware/efi/efivars/SecureBoot-*; do
            if [ -f "$efivar" ]; then
                # 5th byte (offset 4) holds the SecureBoot boolean: 1 = enabled, 0 = disabled
                local val
                val=$(od -An -t u1 -j 4 -N 1 "$efivar" 2>/dev/null | tr -d '[:space:]' || true)
                if [ "$val" = "1" ]; then
                    sb_active=true
                    break
                fi
            fi
        done
    fi

    if [ "$sb_active" = true ]; then
        echo -e "\n${C_YELLOW}╔══════════════════════════════════════════════════════════════════════╗${C_RESET}"
        echo -e "${C_YELLOW}║                   ${C_RED}${C_BOLD}WARNING: SECURE BOOT IS ENABLED${C_RESET}${C_YELLOW}                    ║${C_RESET}"
        echo -e "${C_YELLOW}╚══════════════════════════════════════════════════════════════════════╝${C_RESET}"
        echo -e "${C_WHITE}Home Assistant OS requires Secure Boot to be DISABLED in BIOS.${C_RESET}"
        echo -e "${C_YELLOW}Its bootloader is not signed with Microsoft Secure Boot keys, so your Mini PC${C_RESET}"
        echo -e "${C_YELLOW}will fail to boot HAOS until you turn Secure Boot OFF in firmware settings.${C_RESET}\n"

        local sb_choice
        sb_choice=$(tui_choose "Secure Boot is currently ENABLED. What would you like to do?" \
            "Reboot into BIOS / UEFI Firmware Setup to disable Secure Boot" \
            "Continue anyway (I will disable Secure Boot right after flashing)" \
            "Abort installation") || fatal_error "Secure Boot check aborted."

        case "$sb_choice" in
            "Reboot into BIOS / UEFI Firmware Setup to disable Secure Boot")
                echo -e "${C_CYAN}[*] Rebooting into UEFI Firmware Setup...${C_RESET}"
                # Try firmware reboot if supported, fallback to normal reboot
                efibootmgr -n 0000 >/dev/null 2>&1 || true
                if [ -w /sys/firmware/efi/efivars/OsIndications-8be4df61-93ca-11d2-aa0d-00e098032b8c ]; then
                    echo -e "${C_DIM}(Rebooting now — press Del/F2/F10 if firmware does not open automatically)${C_RESET}"
                fi
                reboot
                exit 0
                ;;
            "Continue anyway"*)
                echo -e "${C_YELLOW}[!] Proceeding with Secure Boot warning acknowledged.${C_RESET}"
                ;;
            *)
                fatal_error "Aborted by user to disable Secure Boot in BIOS."
                ;;
        esac
    else
        echo -e "${C_GREEN}[✓] Secure Boot is Disabled (Ready for Home Assistant OS).${C_RESET}"
    fi
}

# Helper to verify connectivity
has_internet() {
    (ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1) && \
        curl -Is --connect-timeout 4 https://api.github.com >/dev/null 2>&1
}

# Trigger DHCP across wired interfaces
renew_ethernet_dhcp() {
    echo -e "${C_CYAN}[*] Bringing up wired Ethernet interfaces & requesting DHCP...${C_RESET}"
    for iface in $(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(eth|en|eno|enp)'); do
        ip link set "$iface" up 2>/dev/null || true
        if command -v dhcpcd >/dev/null 2>&1; then
            dhcpcd -n "$iface" >/dev/null 2>&1 || dhcpcd -1 "$iface" >/dev/null 2>&1 || true
        elif command -v udhcpc >/dev/null 2>&1; then
            udhcpc -i "$iface" -n -q -t 4 >/dev/null 2>&1 || true
        fi
    done
}

# Interactive Wi-Fi connector (supports nmcli, iwctl, and iw/wpa_supplicant)
setup_wifi_connection() {
    echo -e "${C_CYAN}[*] Searching for Wi-Fi hardware...${C_RESET}"
    local wlan_dev
    wlan_dev=$(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(wl|wlan)' | head -n 1 || true)

    if [ -z "$wlan_dev" ]; then
        echo -e "${C_RED}[!] No wireless network adapter detected.${C_RESET}"
        echo -e "${C_DIM}Ensure your Ethernet cable is plugged in or use an offline USB image.${C_RESET}"
        sleep 2
        return 1
    fi

    ip link set "$wlan_dev" up 2>/dev/null || true

    if command -v nmcli >/dev/null 2>&1; then
        echo -e "${C_CYAN}[*] Scanning Wi-Fi networks with NetworkManager (nmcli)...${C_RESET}"
        nmcli dev wifi rescan 2>/dev/null || true
        sleep 2
        local ssids
        ssids=$(nmcli -t -f SSID dev wifi list 2>/dev/null | grep -v '^$' | sort -u || true)
        local ssid_arr=()
        while IFS= read -r line; do
            [ -n "$line" ] && ssid_arr+=("$line")
        done <<< "$ssids"

        local selected_ssid=""
        if [ ${#ssid_arr[@]} -gt 0 ]; then
            selected_ssid=$(tui_choose "Select Wi-Fi Network (SSID):" "${ssid_arr[@]}" "Enter SSID manually") || return 1
        else
            selected_ssid="Enter SSID manually"
        fi

        if [ "$selected_ssid" = "Enter SSID manually" ]; then
            echo -ne "${C_CYAN}Enter Wi-Fi SSID: ${C_RESET}"
            read -r selected_ssid
        fi
        [ -z "$selected_ssid" ] && return 1

        local wifi_pass=""
        if [ "$TUI_BACKEND" = "gum" ]; then
            wifi_pass=$(gum input --password --placeholder "Wi-Fi Password (leave empty for open network)")
        else
            echo -ne "${C_CYAN}Enter Wi-Fi Password (blank if open): ${C_RESET}"
            read -rs wifi_pass
            echo ""
        fi

        echo -e "${C_CYAN}[*] Connecting to '${selected_ssid}'...${C_RESET}"
        if [ -n "$wifi_pass" ]; then
            nmcli dev wifi connect "$selected_ssid" password "$wifi_pass"
        else
            nmcli dev wifi connect "$selected_ssid"
        fi
    elif command -v iwctl >/dev/null 2>&1; then
        echo -e "${C_CYAN}[*] Scanning Wi-Fi networks via iwd (iwctl)...${C_RESET}"
        iwctl station "$wlan_dev" scan 2>/dev/null || true
        sleep 2
        iwctl station "$wlan_dev" get-networks || true
        echo -ne "${C_CYAN}Enter Wi-Fi SSID: ${C_RESET}"
        read -r selected_ssid
        [ -z "$selected_ssid" ] && return 1
        echo -ne "${C_CYAN}Enter Wi-Fi Password (blank if open): ${C_RESET}"
        read -rs wifi_pass
        echo ""
        if [ -n "$wifi_pass" ]; then
            iwctl --passphrase "$wifi_pass" station "$wlan_dev" connect "$selected_ssid"
        else
            iwctl station "$wlan_dev" connect "$selected_ssid"
        fi
    else
        # Pure Alpine wpa_supplicant + iw/iwlist fallback
        echo -e "${C_CYAN}[*] Scanning Wi-Fi networks on ${wlan_dev}...${C_RESET}"
        local ssids=""
        if command -v iw >/dev/null 2>&1; then
            ssids=$(iw dev "$wlan_dev" scan 2>/dev/null | grep -E '^\s*SSID:' | sed 's/.*SSID: //' | grep -v '^$' | sort -u || true)
        elif command -v iwlist >/dev/null 2>&1; then
            ssids=$(iwlist "$wlan_dev" scan 2>/dev/null | grep -i 'ESSID:' | cut -d'"' -f2 | grep -v '^$' | sort -u || true)
        fi

        local ssid_arr=()
        while IFS= read -r line; do
            [ -n "$line" ] && ssid_arr+=("$line")
        done <<< "$ssids"

        local selected_ssid=""
        if [ ${#ssid_arr[@]} -gt 0 ]; then
            selected_ssid=$(tui_choose "Select Wi-Fi Network:" "${ssid_arr[@]}" "Enter SSID manually") || return 1
        else
            selected_ssid="Enter SSID manually"
        fi

        if [ "$selected_ssid" = "Enter SSID manually" ]; then
            echo -ne "${C_CYAN}Enter Wi-Fi SSID: ${C_RESET}"
            read -r selected_ssid
        fi
        [ -z "$selected_ssid" ] && return 1

        local wifi_pass=""
        if [ "$TUI_BACKEND" = "gum" ]; then
            wifi_pass=$(gum input --password --placeholder "Enter Wi-Fi Password (blank if open)")
        else
            echo -ne "${C_CYAN}Enter Wi-Fi Password (blank if open): ${C_RESET}"
            read -rs wifi_pass
            echo ""
        fi

        local wpa_conf="/tmp/wpa_${wlan_dev}.conf"
        if [ -n "$wifi_pass" ]; then
            wpa_passphrase "$selected_ssid" "$wifi_pass" > "$wpa_conf" 2>/dev/null
        else
            cat > "$wpa_conf" << EOF
network={
    ssid="$selected_ssid"
    key_mgmt=NONE
}
EOF
        fi

        killall wpa_supplicant 2>/dev/null || true
        wpa_supplicant -B -i "$wlan_dev" -c "$wpa_conf" >/dev/null 2>&1 || true
        sleep 3
        if command -v dhcpcd >/dev/null 2>&1; then
            dhcpcd -n "$wlan_dev" >/dev/null 2>&1 || dhcpcd -1 "$wlan_dev" >/dev/null 2>&1 || true
        elif command -v udhcpc >/dev/null 2>&1; then
            udhcpc -i "$wlan_dev" -n -q -t 5 >/dev/null 2>&1 || true
        fi
    fi
}

# Network verification - "Sending a carrier pigeon to 1.1.1.1 and hoping it returns"
check_network() {
    echo -e "${C_CYAN}[*] Checking internet connectivity...${C_RESET}"

    if has_internet; then
        echo -e "${C_GREEN}[✓] Active Internet Connection Detected!${C_RESET}"
        return 0
    fi

    echo -e "${C_YELLOW}[!] Not online yet. Attempting Ethernet DHCP...${C_RESET}"
    renew_ethernet_dhcp
    sleep 1

    if has_internet; then
        echo -e "${C_GREEN}[✓] Ethernet connected and online!${C_RESET}"
        return 0
    fi

    while true; do
        print_banner
        echo -e "${C_YELLOW}${C_BOLD}NO INTERNET CONNECTION DETECTED${C_RESET}\n"
        echo -e "Easy-HAOS needs internet access to download the latest Home Assistant OS image,"
        echo -e "unless you already placed a local ${C_CYAN}haos_generic-x86-64-*.img.xz${C_RESET} file on a USB drive.\n"

        local net_action
        net_action=$(tui_choose "Select a network option:" \
            "Retry Ethernet / DHCP" \
            "Scan & Connect to Wi-Fi" \
            "Open Shell to Configure Network Manually" \
            "Proceed in Offline Mode (Search USB/Ventoy for local HAOS image)" \
            "Reboot Machine") || continue

        case "$net_action" in
            "Retry Ethernet / DHCP")
                renew_ethernet_dhcp
                if has_internet; then
                    echo -e "${C_GREEN}[✓] Connected!${C_RESET}"
                    sleep 1
                    return 0
                fi
                echo -e "${C_RED}[!] Still offline. Check Ethernet cable and link LEDs.${C_RESET}"
                sleep 2
                ;;
            "Scan & Connect to Wi-Fi")
                setup_wifi_connection || true
                if has_internet; then
                    echo -e "${C_GREEN}[✓] Wi-Fi connected and online!${C_RESET}"
                    sleep 1
                    return 0
                fi
                echo -e "${C_RED}[!] Could not reach the internet over Wi-Fi.${C_RESET}"
                sleep 2
                ;;
            "Open Shell to Configure Network Manually")
                echo -e "${C_YELLOW}Dropping to bash. Run nmcli/iwctl/ip/udhcpc, then type 'exit' to return.${C_RESET}"
                /bin/bash
                if has_internet; then
                    return 0
                fi
                ;;
            "Proceed in Offline Mode"*)
                echo -e "${C_CYAN}[*] Continuing in Offline Mode — scanning local media for HAOS image...${C_RESET}"
                sleep 1
                return 0
                ;;
            "Reboot Machine")
                reboot
                ;;
        esac
    done
}

# ==============================================================================
# STEP 2: Fetch Official HAOS Release Dynamically (with Offline Fallback)
# ==============================================================================
# Asking GitHub politely for the latest release before rate-limiting strikes
fetch_haos_release() {
    print_banner
    echo -e "${C_CYAN}[*] Scanning USB/Ventoy partitions for offline HAOS images...${C_RESET}"

    local local_candidates=()
    local scan_dir="/mnt/easyhaos_scan"
    mkdir -p "$scan_dir"

    # Scan existing mounted locations first
    while IFS= read -r f; do
        [ -f "$f" ] && local_candidates+=("$f")
    done < <(find /mnt /media /run/media -maxdepth 3 -type f -name "haos_generic-x86-64*.img.xz" 2>/dev/null || true)

    # Mount unmounted partitions read-only temporarily to check for Ventoy/USB offline images
    for blk in $(lsblk -lno PATH,TYPE 2>/dev/null | awk '$2=="part" {print $1}'); do
        local existing_mnt
        existing_mnt=$(findmnt -n -o TARGET "$blk" 2>/dev/null | head -n 1 || true)
        if [ -z "$existing_mnt" ]; then
            if mount -o ro "$blk" "$scan_dir" 2>/dev/null; then
                while IFS= read -r f; do
                    if [ -f "$f" ]; then
                        # Copy path hint or keep partition mapped via persistent mountpoint
                        local safe_name
                        safe_name=$(basename "$blk")
                        local persist_mnt="/mnt/easyhaos_src_${safe_name}"
                        mkdir -p "$persist_mnt"
                        umount "$scan_dir" 2>/dev/null || true
                        if mount -o ro "$blk" "$persist_mnt" 2>/dev/null; then
                            local matched_file="${persist_mnt}/${f#"$scan_dir"/}"
                            [ -f "$matched_file" ] && local_candidates+=("$matched_file")
                        fi
                        break
                    fi
                done < <(find "$scan_dir" -maxdepth 3 -type f -name "haos_generic-x86-64*.img.xz" 2>/dev/null || true)
                umount "$scan_dir" 2>/dev/null || true
            fi
        fi
    done
    rmdir "$scan_dir" 2>/dev/null || true

    # Deduplicate candidate files
    local unique_candidates=()
    if [ ${#local_candidates[@]} -gt 0 ]; then
        while IFS= read -r u; do
            [ -n "$u" ] && unique_candidates+=("$u")
        done < <(printf '%s\n' "${local_candidates[@]}" | sort -u)
    fi

    if [ ${#unique_candidates[@]} -gt 0 ]; then
        echo -e "${C_GREEN}[✓] Found ${#unique_candidates[@]} local HAOS image(s) on USB/storage!${C_RESET}"
        local chosen_file
        chosen_file=$(tui_choose "Use a local offline HAOS image or download latest from GitHub?" \
            "${unique_candidates[@]}" \
            "Download Latest Official Release from GitHub API") || chosen_file="Download Latest Official Release from GitHub API"

        if [ "$chosen_file" != "Download Latest Official Release from GitHub API" ] && [ -f "$chosen_file" ]; then
            HAOS_IMAGE_FILE="$chosen_file"
            IS_OFFLINE_IMAGE=true
            HAOS_VERSION=$(basename "$chosen_file" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || echo "Offline")
            echo -e "${C_GREEN}[✓] Selected local image: ${HAOS_IMAGE_FILE} (v${HAOS_VERSION})${C_RESET}"
            sleep 1
            return 0
        fi
    fi

    # Query official GitHub Releases API
    echo -e "${C_CYAN}[*] Querying GitHub API for latest Home Assistant OS x86-64 release...${C_RESET}"
    local api_resp
    api_resp=$(curl -fsSL --connect-timeout 10 "$HAOS_LATEST_API" 2>/dev/null || true)

    if [ -n "$api_resp" ] && command -v jq >/dev/null 2>&1; then
        HAOS_VERSION=$(echo "$api_resp" | jq -r '.tag_name // empty')
        HAOS_DOWNLOAD_URL=$(echo "$api_resp" | jq -r '.assets[] | select(.name | test("^haos_generic-x86-64-.*\\.img\\.xz$")) | .browser_download_url' | head -n 1)
        HAOS_ASSET_SIZE=$(echo "$api_resp" | jq -r '.assets[] | select(.name | test("^haos_generic-x86-64-.*\\.img\\.xz$")) | .size // empty' | head -n 1)
    fi

    # Fallback redirect resolution if GitHub API rate limit was hit
    if [ -z "$HAOS_DOWNLOAD_URL" ]; then
        echo -e "${C_YELLOW}[!] GitHub API unavailable or rate-limited; falling back to redirect lookup...${C_RESET}"
        local redirect_url
        redirect_url=$(curl -Ls -o /dev/null -w '%{url_effective}' "https://github.com/home-assistant/operating-system/releases/latest" 2>/dev/null || true)
        HAOS_VERSION=$(basename "$redirect_url")
        if [ -n "$HAOS_VERSION" ] && [ "$HAOS_VERSION" != "latest" ]; then
            HAOS_DOWNLOAD_URL="https://github.com/home-assistant/operating-system/releases/download/${HAOS_VERSION}/haos_generic-x86-64-${HAOS_VERSION}.img.xz"
        fi
    fi

    if [ -z "$HAOS_DOWNLOAD_URL" ]; then
        fatal_error "Failed to fetch Home Assistant OS release URL. Ensure you are online or place a .img.xz on your USB."
    fi

    echo -e "${C_GREEN}[✓] Latest Home Assistant OS Version : ${C_WHITE}${C_BOLD}${HAOS_VERSION}${C_RESET}"
    echo -e "${C_DIM}    Download URL: ${HAOS_DOWNLOAD_URL}${C_RESET}"
    sleep 1
}

# ==============================================================================
# STEP 3: Safe Target Disk Selection
# ==============================================================================
# Preventing the user from committing seppuku by overwriting the installer USB
add_protected_disk() {
    local dev="$1"
    [ -z "$dev" ] && return
    local parent
    parent=$(lsblk -no PKNAME "$dev" 2>/dev/null || true)
    if [ -z "$parent" ]; then
        parent="${dev##*/}"
    else
        parent="${parent##*/}"
    fi
    [ -z "$parent" ] && return
    for existing in "${PROTECTED_DISKS[@]:-}"; do
        [ "$existing" = "$parent" ] && return
    done
    PROTECTED_DISKS+=("$parent")
}

detect_boot_device() {
    PROTECTED_DISKS=()

    # 1. Check root and common live mount points
    for mnt in / /live /run/archiso/bootmnt /mnt/boot /media/usb; do
        local src
        src=$(findmnt -n -o SOURCE "$mnt" 2>/dev/null || true)
        if [ -n "$src" ] && [[ "$src" == /dev/* ]]; then
            add_protected_disk "$src"
        fi
    done

    # 2. Check partitions matching Easy-HAOS or Ventoy labels
    for label in EASY_HAOS Ventoy VTOYEFI; do
        local ldev
        ldev=$(blkid -L "$label" 2>/dev/null || true)
        if [ -n "$ldev" ]; then
            add_protected_disk "$ldev"
        fi
    done

    # 3. Scan partitions for /.easy-haos-usb marker file (handles Rufus FAT32 re-labels)
    local probe_dir="/mnt/easyhaos_probe"
    mkdir -p "$probe_dir"
    for blk in $(lsblk -lno PATH,TYPE 2>/dev/null | awk '$2=="part" {print $1}'); do
        local mnt_pt
        mnt_pt=$(findmnt -n -o TARGET "$blk" 2>/dev/null | head -n 1 || true)
        if [ -n "$mnt_pt" ]; then
            if [ -f "${mnt_pt}/.easy-haos-usb" ]; then
                add_protected_disk "$blk"
            fi
        else
            if mount -o ro "$blk" "$probe_dir" 2>/dev/null; then
                if [ -f "${probe_dir}/.easy-haos-usb" ]; then
                    add_protected_disk "$blk"
                fi
                umount "$probe_dir" 2>/dev/null || true
            fi
        fi
    done
    rmdir "$probe_dir" 2>/dev/null || true

    # 4. Also protect any disk hosting our selected offline .img.xz file!
    if [ "$IS_OFFLINE_IMAGE" = true ] && [ -n "$HAOS_IMAGE_FILE" ]; then
        local img_src
        img_src=$(findmnt -n -o SOURCE --target "$HAOS_IMAGE_FILE" 2>/dev/null || true)
        if [ -n "$img_src" ] && [[ "$img_src" == /dev/* ]]; then
            add_protected_disk "$img_src"
        fi
    fi

    if [ ${#PROTECTED_DISKS[@]} -gt 0 ]; then
        echo -e "${C_YELLOW}[!] Protected Boot/Installer Media Excluded: ${PROTECTED_DISKS[*]/#/\/dev\/}${C_RESET}"
    fi
}

is_protected_disk() {
    local d_name="$1"
    for p in "${PROTECTED_DISKS[@]:-}"; do
        [ "$d_name" = "$p" ] && return 0
    done
    return 1
}

select_target_disk() {
    while true; do
        print_banner
        detect_boot_device
        echo -e "\n${C_CYAN}[*] Scanning internal block devices (NVMe, SATA SSD, eMMC)...${C_RESET}\n"

        # List raw disks excluding loop(7), ram(1), optical/sr(11)
        local raw_disks
        raw_disks=$(lsblk -d -n -o NAME,SIZE,MODEL,TRAN,TYPE -e 7,1,11 2>/dev/null || true)

        local disk_list=()
        local disk_display=()

        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local d_name d_size d_type d_tran d_model
            d_name=$(echo "$line" | awk '{print $1}')
            d_size=$(echo "$line" | awk '{print $2}')
            d_type=$(echo "$line" | awk '{print $NF}')

            # Only allow real disks
            [ "$d_type" != "disk" ] && continue
            [[ "$d_name" =~ ^(zram|ram|loop|sr|fd) ]] && continue

            # Never allow overwriting the installer USB or offline image source disk
            if is_protected_disk "$d_name"; then
                continue
            fi

            d_tran=$(lsblk -d -n -o TRAN "/dev/${d_name}" 2>/dev/null | tr -d '[:space:]' || echo "disk")
            [ -z "$d_tran" ] && d_tran="internal"
            d_model=$(lsblk -d -n -o MODEL "/dev/${d_name}" 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//' || echo "Generic Drive")
            [ -z "$d_model" ] && d_model="Generic Storage Device"

            disk_list+=("$d_name")
            disk_display+=("/dev/${d_name}  |  ${d_size}  |  [${d_tran}] ${d_model}")
        done <<< "$raw_disks"

        if [ ${#disk_list[@]} -eq 0 ]; then
            clear
            echo -e "${C_BG_RED}${C_WHITE}${C_BOLD} NO SUITABLE TARGET DISKS FOUND ${C_RESET}\n"
            echo -e "${C_RED}No internal NVMe, SATA SSD, or eMMC drives were detected!${C_RESET}\n"
            echo -e "${C_YELLOW}Troubleshooting tips for Mini PCs (N100 / NUC / OptiPlex):${C_RESET}"
            echo -e "  1. Check BIOS storage mode: switch from ${C_RED}RAID / Intel RST${C_RESET} to ${C_GREEN}AHCI / NVMe${C_RESET}."
            echo -e "  2. Verify the SSD/NVMe drive is seated firmly."
            echo -e "  3. Remember that the Easy-HAOS installer USB is automatically hidden for safety.\n"
            fatal_error "No valid install target disk detected."
        fi

        local selected_label
        selected_label=$(tui_choose "Select target disk to ERASE and install Home Assistant OS ${HAOS_VERSION}:" "${disk_display[@]}") || fatal_error "Disk selection cancelled."

        TARGET_DISK=""
        for i in "${!disk_display[@]}"; do
            if [ "${disk_display[$i]}" = "$selected_label" ]; then
                TARGET_DISK="${disk_list[$i]}"
                break
            fi
        done

        if [ -z "$TARGET_DISK" ] || [ ! -b "/dev/${TARGET_DISK}" ]; then
            fatal_error "Invalid block device selected."
        fi

        TARGET_SIZE=$(lsblk -d -n -o SIZE "/dev/${TARGET_DISK}" 2>/dev/null | tr -d '[:space:]')
        TARGET_MODEL=$(lsblk -d -n -o MODEL "/dev/${TARGET_DISK}" 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//')
        [ -z "$TARGET_MODEL" ] && TARGET_MODEL="Unknown Model"

        # Explicit Confirmation Step
        # Wiping partition tables - "Say goodbye to Windows 11 bloatware. No regrets."
        print_banner
        echo -e "\n${C_BG_RED}${C_WHITE}${C_BOLD} !!! FINAL WARNING: IRREVERSIBLE DISK WIPE !!! ${C_RESET}\n"
        echo -e "  Target Device : ${C_WHITE}${C_BOLD}/dev/${TARGET_DISK}${C_RESET}"
        echo -e "  Disk Model    : ${C_WHITE}${C_BOLD}${TARGET_MODEL}${C_RESET}"
        echo -e "  Capacity      : ${C_WHITE}${C_BOLD}${TARGET_SIZE}${C_RESET}"
        echo -e "  Installing    : ${C_GREEN}${C_BOLD}Home Assistant OS v${HAOS_VERSION}${C_RESET}\n"
        echo -e "${C_RED}${C_BOLD}ALL DATA ON /dev/${TARGET_DISK} (${TARGET_MODEL}) WILL BE PERMANENTLY ERASED!${C_RESET}\n"

        local confirm_prompt="Type YES to erase ${TARGET_MODEL} and install Home Assistant OS v${HAOS_VERSION}"
        local confirm_text=""
        if [ "$TUI_BACKEND" = "gum" ]; then
            echo -e "${C_WHITE}${confirm_prompt}:${C_RESET}"
            confirm_text=$(gum input --placeholder "Type YES in uppercase")
        else
            echo -ne "${C_WHITE}${confirm_prompt}: ${C_RESET}"
            read -r confirm_text
        fi

        if [ "$confirm_text" = "YES" ]; then
            break
        fi

        echo -e "\n${C_YELLOW}[*] Confirmation did not match 'YES'. No changes were made.${C_RESET}"
        sleep 1
    done
}

# ==============================================================================
# STEP 4: Streaming Flash & Post-Install Verification
# ==============================================================================
# Streaming HAOS - "Zero to Home Assistant in 60 seconds, straight into silicon"
flash_target_disk() {
    print_banner
    local dev="/dev/${TARGET_DISK}"

    echo -e "${C_CYAN}[1/4] Unmounting any existing partitions on ${dev}...${C_RESET}"
    for part in $(lsblk -lno PATH "${dev}" 2>/dev/null | grep -v "^${dev}$" || true); do
        umount -f "$part" 2>/dev/null || true
        swapoff "$part" 2>/dev/null || true
    done

    echo -e "${C_CYAN}[2/4] Wiping partition signatures on ${dev}...${C_RESET}"
    # Wiping partition tables - "Say goodbye to Windows 11 bloatware. No regrets."
    wipefs -a -f "${dev}" >/dev/null 2>&1 || true
    blkdiscard "${dev}" >/dev/null 2>&1 || true
    dd if=/dev/zero of="${dev}" bs=1M count=8 conv=fsync status=none 2>/dev/null || true

    echo -e "${C_CYAN}[3/4] Streaming and flashing Home Assistant OS v${HAOS_VERSION} to ${dev}...${C_RESET}"
    echo -e "${C_DIM}      (Please do not unplug power or the USB drive while writing)${C_RESET}\n"

    local start_time
    start_time=$(date +%s)
    local pipe_failed=false

    if [ "$IS_OFFLINE_IMAGE" = true ]; then
        local file_bytes
        file_bytes=$(stat -c%s "$HAOS_IMAGE_FILE" 2>/dev/null || echo 0)
        if command -v pv >/dev/null 2>&1 && [ "$file_bytes" -gt 0 ]; then
            pv -s "$file_bytes" -N "Flashing Local HAOS" "$HAOS_IMAGE_FILE" | xz -d | dd of="${dev}" bs=4M conv=fsync status=none
        elif command -v pv >/dev/null 2>&1; then
            pv -N "Flashing Local HAOS" "$HAOS_IMAGE_FILE" | xz -d | dd of="${dev}" bs=4M conv=fsync status=none
        else
            xz -dc "$HAOS_IMAGE_FILE" | dd of="${dev}" bs=4M conv=fsync status=progress
        fi
        for rc in "${PIPESTATUS[@]}"; do
            [ "$rc" -ne 0 ] && pipe_failed=true
        done
    else
        if command -v pv >/dev/null 2>&1; then
            if [ -n "$HAOS_ASSET_SIZE" ] && [ "$HAOS_ASSET_SIZE" -gt 0 ] 2>/dev/null; then
                curl -f -L --retry 3 --retry-delay 2 -s "$HAOS_DOWNLOAD_URL" | pv -s "$HAOS_ASSET_SIZE" -N "Downloading & Flashing" | xz -d | dd of="${dev}" bs=4M conv=fsync status=none
            else
                curl -f -L --retry 3 --retry-delay 2 -s "$HAOS_DOWNLOAD_URL" | pv -N "Downloading & Flashing" | xz -d | dd of="${dev}" bs=4M conv=fsync status=none
            fi
        else
            curl -f -L --retry 3 --retry-delay 2 "$HAOS_DOWNLOAD_URL" | xz -d | dd of="${dev}" bs=4M conv=fsync status=progress
        fi
        for rc in "${PIPESTATUS[@]}"; do
            [ "$rc" -ne 0 ] && pipe_failed=true
        done
    fi

    if [ "$pipe_failed" = true ]; then
        fatal_error "Streaming flash pipeline failed! Check network stability or disk health and retry."
    fi

    echo -e "\n${C_CYAN}[*] Flushing write buffers to physical storage...${C_RESET}"
    sync
    sleep 2

    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    echo -e "${C_GREEN}[✓] Flash completed cleanly in ${elapsed} seconds!${C_RESET}\n"

    # Post-Install Verification
    echo -e "${C_CYAN}[4/4] Running partprobe & verifying UEFI Boot Manager...${C_RESET}"
    # Poking UEFI firmware with a stick until it cooperates
    partprobe "${dev}" 2>/dev/null || blockdev --rereadpt "${dev}" 2>/dev/null || true
    udevadm settle 2>/dev/null || sleep 2

    local efi_part="${dev}1"
    if [[ "$dev" =~ (nvme|mmcblk) ]]; then
        efi_part="${dev}p1"
    fi

    if [ -b "$efi_part" ]; then
        echo -e "${C_GREEN}[✓] Verified Home Assistant OS EFI partition at ${efi_part}.${C_RESET}"
    else
        echo -e "${C_YELLOW}[!] Partition ${efi_part} not immediately enumerated; kernel will rescan on reboot.${C_RESET}"
    fi

    if command -v efibootmgr >/dev/null 2>&1 && [ -d /sys/firmware/efi ]; then
        echo -e "${C_CYAN}[*] Registering Home Assistant OS at top of UEFI BootOrder...${C_RESET}"
        # Remove stale duplicate entries
        while IFS= read -r bootnum; do
            [ -n "$bootnum" ] && efibootmgr -b "$bootnum" -B >/dev/null 2>&1 || true
        done < <(efibootmgr 2>/dev/null | grep -i "Home Assistant OS" | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p')

        # Create fresh entry (efibootmgr -c places the new entry at the top of BootOrder by default)
        if efibootmgr -c -d "${dev}" -p 1 -L "Home Assistant OS" -l '\EFI\BOOT\bootx64.efi' >/dev/null 2>&1; then
            local new_bootnum
            new_bootnum=$(efibootmgr 2>/dev/null | grep -i "Home Assistant OS" | head -n 1 | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p')
            if [ -n "$new_bootnum" ]; then
                local current_order
                current_order=$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder: //p' | tr -d '[:space:]')
                if [ -n "$current_order" ] && [[ "$current_order" != "${new_bootnum}"* ]]; then
                    local cleaned_order
                    cleaned_order=$(echo "$current_order" | sed "s/${new_bootnum},\?//g; s/,$//")
                    if [ -n "$cleaned_order" ]; then
                        efibootmgr -o "${new_bootnum},${cleaned_order}" >/dev/null 2>&1 || true
                    else
                        efibootmgr -o "${new_bootnum}" >/dev/null 2>&1 || true
                    fi
                fi
            fi
            echo -e "${C_GREEN}[✓] UEFI BootOrder updated: Home Assistant OS is Boot #1.${C_RESET}"
            efibootmgr 2>/dev/null | grep -E '^(BootOrder|BootCurrent|.*Home Assistant)' || true
        else
            echo -e "${C_YELLOW}[!] Could not write UEFI NVRAM entry (some Mini PCs use fallback \\EFI\\BOOT\\bootx64.efi automatically).${C_RESET}"
        fi
    fi

    # Unmount any read-only scan mounts cleanly
    for mnt in /mnt/easyhaos_src_*; do
        [ -d "$mnt" ] && umount "$mnt" 2>/dev/null || true
    done
    sleep 1
}

# ==============================================================================
# STEP 5: Completion Screen
# ==============================================================================
# Completion - "It worked on my machine, so it should work on yours!"
show_completion_screen() {
    clear
    cat << "EOF"
  ___ _   _ ____ _____  _    _     _        _  _____ ___ ___  _   _ 
 |_ _| \ | / ___|_   _|/ \  | |   | |      / \|_   _|_ _/ _ \| \ | |
  | ||  \| \___ \ | | / _ \ | |   | |     / _ \ | |  | | | | |  \| |
  | || |\  |___) || |/ ___ \| |___| |___ / ___ \| |  | | |_| | |\  |
 |___|_| \_|____/ |_/_/   \_\_____|_____/_/   \_\_| |___\___/|_| \_|
                                                                    
  ____ ___  __  __ ____  _     _____ _____ _____ ____  _ 
 / ___/ _ \|  \/  |  _ \| |   | ____|_   _| ____|  _ \| |
| |  | | | | |\/| | |_) | |   |  _|   | | |  _| | | | | |
| |__| |_| | |  | |  __/| |___| |___  | | | |___| |_| |_|
 \____\___/|_|  |_|_|   |_____|_____| |_| |_____|____/(_)
EOF

    echo -e "\n${C_GREEN}${C_BOLD}======================================================================${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}   Home Assistant OS v${HAOS_VERSION} Installed on /dev/${TARGET_DISK}!${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}======================================================================${C_RESET}\n"

    local ips
    ips=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {split($2,a,"/"); print a[1]}' || true)

    echo -e "${C_WHITE}${C_BOLD}NEXT STEPS:${C_RESET}"
    echo -e "  1. ${C_YELLOW}${C_BOLD}REMOVE THE USB INSTALLER STICK${C_RESET} from this computer right now."
    echo -e "  2. Press ${C_CYAN}[ENTER]${C_RESET} below to reboot into Home Assistant OS."
    echo -e "  3. Wait ~2-5 minutes on first boot while HAOS initializes."
    echo -e "  4. Open your browser from any device on your network and visit:"
    echo -e "     ${C_GREEN}${C_BOLD}http://homeassistant.local:8123${C_RESET}"

    if [ -n "$ips" ]; then
        echo -e "\n${C_WHITE}Detected Local IPv4 Address(es) (if DHCP assigns the same lease):${C_RESET}"
        while IFS= read -r ip; do
            [ -n "$ip" ] && echo -e "     ${C_CYAN}${C_BOLD}http://${ip}:8123${C_RESET}"
        done <<< "$ips"
    fi

    echo -e "\n${C_BLUE}──────────────────────────────────────────────────────────────────────${C_RESET}"
    echo -e "${C_WHITE}${C_BOLD}  Easy-HAOS by Christian Bennetsen${C_RESET}"
    echo -e "   • Website : ${C_CYAN}https://bennetsen.dk${C_RESET}"
    echo -e "   • Email   : ${C_CYAN}christian@bennetsen.dk${C_RESET}"
    echo -e "   • LinkedIn: ${C_CYAN}https://www.linkedin.com/in/mrbennetsen/${C_RESET}"
    echo -e "   • YouTube : ${C_CYAN}https://www.youtube.com/@BennetsenTech${C_RESET}"
    echo -e "${C_BLUE}──────────────────────────────────────────────────────────────────────${C_RESET}\n"

    echo -ne "${C_YELLOW}${C_BOLD}Unplug the USB stick, then press [ENTER] to reboot... ${C_RESET}"
    read -r
    echo -e "${C_GREEN}[*] Rebooting into Home Assistant OS... Enjoy your smart home!${C_RESET}"
    sync
    reboot
}

# ==============================================================================
# MAIN EXECUTION FLOW
# ==============================================================================
main() {
    print_banner
    echo -e "${C_CYAN}[*] Starting Easy-HAOS Pre-Flight Checks...${C_RESET}\n"

    check_uefi_mode
    check_secure_boot
    check_network
    fetch_haos_release
    select_target_disk
    flash_target_disk
    show_completion_screen
}

main "$@"
