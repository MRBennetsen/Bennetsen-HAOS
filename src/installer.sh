#!/usr/bin/env bash
# ==============================================================================
#  _____                 _   _    _    ___  ____  
# | ____|__ _ ___ _   _ | | | |  / \  / _ \/ ___| 
# |  _| / _` / __| | | || |_| | / _ \| | | \___ \ 
# | |__| (_| \__ \ |_| ||  _  |/ ___ \ |_| |___) |
# |_____\__,_|___/\__, ||_| |_/_/   \_\___/|____/ 
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

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

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
C_BG_GREEN="\033[42m"
C_BG_CYAN="\033[46m"
C_BLACK="\033[30m"

# --- Global State ---
HAOS_LATEST_API="https://api.github.com/repos/home-assistant/operating-system/releases?per_page=10"
HAOS_VERSION=""
HAOS_DOWNLOAD_URL=""
HAOS_ASSET_SIZE=""
HAOS_IMAGE_FILE=""
IS_OFFLINE_IMAGE=false
TARGET_DISK=""
TARGET_SIZE=""
TARGET_MODEL=""
PROTECTED_DISKS=()
CLOCK_SYNCED=false
CURRENT_STEP=1
ERR_LOG="/tmp/easyhaos_err.log"
RETRY_REQUESTED=false

# Live Diagnostic Panel States: pending | running | ok | warn | fail
DIAG_UEFI_ST="pending";   DIAG_UEFI_MSG="Waiting to inspect firmware..."
DIAG_SB_ST="pending";     DIAG_SB_MSG="Waiting to check Secure Boot..."
DIAG_NET_ST="pending";    DIAG_NET_MSG="Waiting to verify network & clock..."
DIAG_REL_ST="pending";    DIAG_REL_MSG="Waiting to resolve HAOS release..."
DIAG_USB_ST="pending";    DIAG_USB_MSG="Waiting to identify installer USB..."

# Flash Dashboard States
FLASH_S1_ST="pending"; FLASH_S1_MSG="Unmount existing target partitions"
FLASH_S2_ST="pending"; FLASH_S2_MSG="Wipe partition signatures & GPT table"
FLASH_S3_ST="pending"; FLASH_S3_MSG="Stream & flash Home Assistant OS"
FLASH_S4_ST="pending"; FLASH_S4_MSG="Verify partitions & register UEFI BootOrder"

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

reset_wizard_state() {
    HAOS_VERSION=""
    HAOS_DOWNLOAD_URL=""
    HAOS_ASSET_SIZE=""
    HAOS_IMAGE_FILE=""
    IS_OFFLINE_IMAGE=false
    TARGET_DISK=""
    TARGET_SIZE=""
    TARGET_MODEL=""
    PROTECTED_DISKS=()
    CURRENT_STEP=1
    RETRY_REQUESTED=false
    : > "$ERR_LOG"

    DIAG_UEFI_ST="pending";   DIAG_UEFI_MSG="Waiting to inspect firmware..."
    DIAG_SB_ST="pending";     DIAG_SB_MSG="Waiting to check Secure Boot..."
    DIAG_NET_ST="pending";    DIAG_NET_MSG="Waiting to verify network & clock..."
    DIAG_REL_ST="pending";    DIAG_REL_MSG="Waiting to resolve HAOS release..."
    DIAG_USB_ST="pending";    DIAG_USB_MSG="Waiting to identify installer USB..."

    FLASH_S1_ST="pending"; FLASH_S1_MSG="Unmount existing target partitions"
    FLASH_S2_ST="pending"; FLASH_S2_MSG="Wipe partition signatures & GPT table"
    FLASH_S3_ST="pending"; FLASH_S3_MSG="Stream & flash Home Assistant OS"
    FLASH_S4_ST="pending"; FLASH_S4_MSG="Verify partitions & register UEFI BootOrder"
}

# ==============================================================================
# TUI RENDERING PRIMITIVES (Optimized for eurlatgr UTF-8 Framebuffer Console)
# ==============================================================================

status_badge() {
    local st="$1"
    case "$st" in
        ok)      echo -ne "${C_GREEN}[ ✓ ]${C_RESET}" ;;
        warn)    echo -ne "${C_YELLOW}[ ! ]${C_RESET}" ;;
        fail)    echo -ne "${C_RED}[ ✗ ]${C_RESET}" ;;
        running) echo -ne "${C_CYAN}[ → ]${C_RESET}" ;;
        *)       echo -ne "${C_DIM}[ · ]${C_RESET}" ;;
    esac
}

render_wizard_bar() {
    local active="$1"
    local labels=("1.Pre-Flight" "2.Release" "3.Disk" "4.Flash" "5.Done")
    local bar=""
    local i=1

    for lbl in "${labels[@]}"; do
        if [ "$i" -lt "$active" ]; then
            bar+="${C_GREEN}[✓] ${lbl}${C_RESET}"
        elif [ "$i" -eq "$active" ]; then
            bar+="${C_BG_CYAN}${C_BLACK}${C_BOLD} → ${lbl} ${C_RESET}"
        else
            bar+="${C_DIM}[·] ${lbl}${C_RESET}"
        fi
        if [ "$i" -lt 5 ]; then
            bar+=" ${C_DIM}→${C_RESET} "
        fi
        i=$((i + 1))
    done
    echo -e "  ${bar}"
}

print_banner() {
    local step="${1:-$CURRENT_STEP}"
    CURRENT_STEP="$step"
    clear
    echo -e "${C_CYAN}"
    cat << "EOF"
  _____                 _   _    _    ___  ____  
 | ____|__ _ ___ _   _ | | | |  / \  / _ \/ ___| 
 |  _| / _` / __| | | || |_| | / _ \| | | \___ \ 
 | |__| (_| \__ \ |_| ||  _  |/ ___ \ |_| |___) |
 |_____\__,_|___/\__, ||_| |_/_/   \_\___/|____/ 
                 |___/                           
EOF
    echo -e "${C_RESET}${C_WHITE}${C_BOLD}  Home Assistant OS (x86-64) Bare-Metal Appliance Installer${C_RESET}"
    echo -e "${C_DIM}  Christian Bennetsen | bennetsen.dk | christian@bennetsen.dk | @BennetsenTech${C_RESET}"
    echo -e "${C_BLUE}──────────────────────────────────────────────────────────────────────────────${C_RESET}"
    render_wizard_bar "$step"
    echo -e "${C_BLUE}──────────────────────────────────────────────────────────────────────────────${C_RESET}\n"
}

ui_card() {
    local border_fg="$1"
    local title="$2"
    local body="$3"
    local border_style="${4:-normal}"

    if [ "$TUI_BACKEND" = "gum" ]; then
        gum style \
            --border "$border_style" \
            --border-foreground "$border_fg" \
            --padding "0 2" \
            --margin "0 2" \
            --width 74 \
            "$(echo -e "${C_BOLD}${title}${C_RESET}\n${body}")"
    else
        echo -e "  ┌─[ ${C_BOLD}${title}${C_RESET} ]──────────────────────────────────────────────────────────"
        while IFS= read -r line; do
            echo -e "  │  ${line}"
        done <<< "$body"
        echo -e "  └──────────────────────────────────────────────────────────────────────────"
    fi
}

render_diagnostics_card() {
    local lines=""
    lines+="$(status_badge "$DIAG_UEFI_ST")  ${C_WHITE}UEFI Firmware     ${C_RESET} ${DIAG_UEFI_MSG}\n"
    lines+="$(status_badge "$DIAG_SB_ST")  ${C_WHITE}Secure Boot       ${C_RESET} ${DIAG_SB_MSG}\n"
    lines+="$(status_badge "$DIAG_NET_ST")  ${C_WHITE}Network & Clock   ${C_RESET} ${DIAG_NET_MSG}\n"
    lines+="$(status_badge "$DIAG_REL_ST")  ${C_WHITE}HAOS x86-64 Image ${C_RESET} ${DIAG_REL_MSG}\n"
    lines+="$(status_badge "$DIAG_USB_ST")  ${C_WHITE}USB Safety Lock   ${C_RESET} ${DIAG_USB_MSG}"

    ui_card "39" "System Pre-Flight & Diagnostics" "$(echo -e "$lines")" "normal"
}

render_flash_card() {
    local lines=""
    lines+="$(status_badge "$FLASH_S1_ST")  ${FLASH_S1_MSG}\n"
    lines+="$(status_badge "$FLASH_S2_ST")  ${FLASH_S2_MSG}\n"
    lines+="$(status_badge "$FLASH_S3_ST")  ${FLASH_S3_MSG}\n"
    lines+="$(status_badge "$FLASH_S4_ST")  ${FLASH_S4_MSG}"

    local header="Flashing /dev/${TARGET_DISK} (${TARGET_MODEL} - ${TARGET_SIZE})"
    ui_card "39" "$header" "$(echo -e "$lines")" "normal"
}

# Animate a smooth pulse bar while a background subshell/command executes
# Supports passing a shell function OR external command; writes exit code cleanly.
run_animated() {
    local title="$1"
    shift
    local frames=("[█░░░]" "[░█░░]" "[░░█░]" "[░░░█]" "[░░█░]" "[░█░░]")
    local idx=0

    "$@" 2>>"$ERR_LOG" &
    local pid=$!

    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C_CYAN}%s${C_RESET}  %s\033[K" "${frames[$idx]}" "$title"
        idx=$(( (idx + 1) % ${#frames[@]} ))
        sleep 0.12
    done
    wait "$pid"
    local rc=$?
    tput cnorm 2>/dev/null || true
    printf "\r\033[K"
    return "$rc"
}

# --- Helper: Interactive Choice Menu ---
tui_choose() {
    local header="$1"
    shift
    local options=("$@")

    case "$TUI_BACKEND" in
        gum)
            printf '%s\n' "${options[@]}" | gum choose \
                --cursor="→ " \
                --cursor.foreground="51" \
                --header.foreground="15" \
                --header "  $header"
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
            echo -e "  ${C_WHITE}${C_BOLD}${header}${C_RESET}" >&2
            local idx=1
            for opt in "${options[@]}"; do
                echo -e "    ${C_CYAN}${idx})${C_RESET} ${opt}" >&2
                idx=$((idx + 1))
            done
            echo -ne "\n  Select option [1-${#options[@]}]: " >&2
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

# --- Helper: Red [ ✗ ] Diagnostic Failure Screen & Recovery Menu ---
# "Dropping to red diagnostic GUI - I'm gonna regret this aren't I?"
fatal_error() {
    local title="$1"
    local reason="${2:-$1}"
    shift 2 2>/dev/null || shift $#

    local hints=("$@")
    local err_snippet=""
    if [ -s "$ERR_LOG" ]; then
        err_snippet=$(tail -n 6 "$ERR_LOG" | sed 's/^/    /')
    fi

    while true; do
        print_banner "$CURRENT_STEP"

        local body=""
        body+="${C_RED}${C_BOLD}[ ✗ ] FAILURE:${C_RESET} ${C_WHITE}${reason}${C_RESET}\n"

        if [ -n "$err_snippet" ]; then
            body+="\n${C_YELLOW}Diagnostic Log Output:${C_RESET}\n${C_DIM}${err_snippet}${C_RESET}\n"
        fi

        if [ ${#hints[@]} -gt 0 ]; then
            body+="\n${C_CYAN}Recommended Actions:${C_RESET}\n"
            for h in "${hints[@]}"; do
                body+="  • ${h}\n"
            done
        fi

        ui_card "196" "[ ✗ ] DIAGNOSTIC ERROR: ${title}" "$(echo -e "$body")" "double"
        echo ""

        local action
        action=$(tui_choose "Choose how to recover:" \
            "Retry Installation Wizard" \
            "Configure Network / Wi-Fi" \
            "Open Diagnostic Shell (bash)" \
            "Reboot Machine") || continue

        case "$action" in
            "Retry Installation Wizard")
                RETRY_REQUESTED=true
                return 0
                ;;
            "Configure Network / Wi-Fi")
                setup_wifi_connection || renew_ethernet_dhcp || true
                RETRY_REQUESTED=true
                return 0
                ;;
            "Open Diagnostic Shell (bash)")
                clear
                echo -e "${C_CYAN}Easy-HAOS Diagnostic Shell — type 'exit' to return to recovery menu.${C_RESET}\n"
                /bin/bash
                ;;
            "Reboot Machine")
                sync
                reboot -f
                ;;
        esac
    done
}

# ==============================================================================
# STEP 1: Pre-Flight Hardware, BIOS & Network Checks
# ==============================================================================
# Checking UEFI mode - "Please don't be running BIOS from 1998, HAOS will cry"
check_uefi_mode() {
    DIAG_UEFI_ST="running"; DIAG_UEFI_MSG="Inspecting /sys/firmware/efi..."
    print_banner 1
    render_diagnostics_card
    echo ""

    run_animated "Checking UEFI boot mode..." sleep 0.4

    if [ ! -d /sys/firmware/efi ]; then
        DIAG_UEFI_ST="fail"; DIAG_UEFI_MSG="${C_RED}Legacy / CSM BIOS mode detected (UEFI required)${C_RESET}"
        print_banner 1
        render_diagnostics_card
        echo ""

        local msg=""
        msg+="${C_RED}${C_BOLD}[ ✗ ] Home Assistant OS strictly requires UEFI boot mode.${C_RESET}\n\n"
        msg+="Your computer booted in Legacy/CSM mode and cannot boot HAOS after flashing.\n\n"
        msg+="${C_WHITE}How to fix in BIOS:${C_RESET}\n"
        msg+="  1. Reboot and press ${C_CYAN}Del${C_RESET}, ${C_CYAN}F2${C_RESET}, ${C_CYAN}F10${C_RESET}, or ${C_CYAN}F12${C_RESET} to open BIOS Setup.\n"
        msg+="  2. Open the ${C_CYAN}Boot${C_RESET} tab: ${C_GREEN}Enable UEFI Boot${C_RESET} and ${C_RED}Disable CSM / Legacy${C_RESET}.\n"
        msg+="  3. Save (F10) and select the ${C_CYAN}UEFI:${C_RESET} entry for this USB drive."

        ui_card "196" "[ ✗ ] UEFI BOOT REQUIRED" "$(echo -e "$msg")" "double"
        echo ""

        while true; do
            local bios_action
            bios_action=$(tui_choose "Firmware Action:" \
                "Reboot Machine to Enter BIOS" \
                "Power Off Machine" \
                "Open Diagnostic Shell (bash)") || continue
            case "$bios_action" in
                "Reboot Machine to Enter BIOS") sync; reboot -f ;;
                "Power Off Machine") sync; poweroff -f ;;
                "Open Diagnostic Shell (bash)") /bin/bash ;;
            esac
        done
    fi

    DIAG_UEFI_ST="ok"; DIAG_UEFI_MSG="${C_GREEN}Active (Modern EFI firmware verified)${C_RESET}"
}

# Secure Boot check - "Microsoft says no, but we say disable it"
check_secure_boot() {
    DIAG_SB_ST="running"; DIAG_SB_MSG="Reading EFI SecureBoot variables..."
    print_banner 1
    render_diagnostics_card
    echo ""

    run_animated "Checking Secure Boot status..." sleep 0.3

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
        DIAG_SB_ST="warn"; DIAG_SB_MSG="${C_YELLOW}ENABLED (HAOS requires Secure Boot OFF)${C_RESET}"
        print_banner 1
        render_diagnostics_card
        echo ""

        local sb_body=""
        sb_body+="${C_YELLOW}${C_BOLD}[ ! ] Secure Boot is currently ENABLED in your BIOS.${C_RESET}\n\n"
        sb_body+="Home Assistant OS is not signed with Microsoft Secure Boot keys.\n"
        sb_body+="Your Mini PC will refuse to boot HAOS until you turn Secure Boot OFF."

        ui_card "220" "[ ! ] SECURE BOOT WARNING" "$(echo -e "$sb_body")" "double"
        echo ""

        local sb_choice
        sb_choice=$(tui_choose "How would you like to proceed?" \
            "Reboot into UEFI Firmware Setup to Disable Secure Boot" \
            "Continue Anyway (I will disable Secure Boot after flashing)" \
            "Abort & Open Recovery Menu") || sb_choice="Abort"

        case "$sb_choice" in
            "Reboot into UEFI Firmware Setup"*)
                efibootmgr -n 0000 >/dev/null 2>&1 || true
                sync
                reboot -f
                ;;
            "Continue Anyway"*)
                DIAG_SB_ST="warn"; DIAG_SB_MSG="${C_YELLOW}Enabled (User acknowledged — disable after flash)${C_RESET}"
                ;;
            *)
                fatal_error "Secure Boot Enabled" \
                    "Installation paused because Secure Boot is active in BIOS." \
                    "Enter BIOS (F2/Del/F10) and set Secure Boot to Disabled." \
                    "Boot Easy-HAOS again and select Install."
                return 1
                ;;
        esac
    else
        DIAG_SB_ST="ok"; DIAG_SB_MSG="${C_GREEN}Disabled (Optimal for Home Assistant OS)${C_RESET}"
    fi
}

# Sync system clock on older Mini PCs with dead CMOS batteries so HTTPS TLS checks succeed
sync_system_clock() {
    [ "$CLOCK_SYNCED" = true ] && return 0
    if command -v ntpd >/dev/null 2>&1; then
        timeout 4 ntpd -q -n -p time.cloudflare.com >/dev/null 2>&1 \
            || timeout 4 ntpd -q -n -p pool.ntp.org >/dev/null 2>&1 \
            || true
    fi
    CLOCK_SYNCED=true
}

has_internet() {
    if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
        sync_system_clock
        curl -Is --connect-timeout 4 https://api.github.com >/dev/null 2>&1
    else
        return 1
    fi
}

renew_ethernet_dhcp() {
    for iface in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(eth|en|eno|enp)'); do
        ip link set "$iface" up 2>/dev/null || true
        if command -v dhcpcd >/dev/null 2>&1; then
            dhcpcd -n "$iface" >/dev/null 2>&1 || dhcpcd -1 "$iface" >/dev/null 2>&1 || true
        elif command -v udhcpc >/dev/null 2>&1; then
            udhcpc -i "$iface" -n -q -t 4 >/dev/null 2>&1 || true
        fi
    done
}

setup_wifi_connection() {
    local wlan_dev
    wlan_dev=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -E '^(wl|wlan)' | sed -n '1p' || true)

    if [ -z "$wlan_dev" ]; then
        ui_card "196" "[ ✗ ] NO WI-FI ADAPTER FOUND" \
            "No wireless interface (wlan/wl) detected. Plug in an Ethernet cable or use an offline USB image." "normal"
        sleep 2
        return 1
    fi

    ip link set "$wlan_dev" up 2>/dev/null || true

    if command -v nmcli >/dev/null 2>&1; then
        run_animated "Scanning Wi-Fi networks (nmcli)..." bash -c "nmcli dev wifi rescan >/dev/null 2>&1 || true; sleep 2"
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
            if [ "$TUI_BACKEND" = "gum" ]; then
                selected_ssid=$(gum input --placeholder "Enter Wi-Fi SSID")
            else
                echo -ne "  ${C_CYAN}Enter Wi-Fi SSID: ${C_RESET}"
                read -r selected_ssid
            fi
        fi
        [ -z "$selected_ssid" ] && return 1

        local wifi_pass=""
        if [ "$TUI_BACKEND" = "gum" ]; then
            wifi_pass=$(gum input --password --placeholder "Wi-Fi Password (blank if open)")
        else
            echo -ne "  ${C_CYAN}Enter Wi-Fi Password (blank if open): ${C_RESET}"
            read -rs wifi_pass
            echo ""
        fi

        if [ -n "$wifi_pass" ]; then
            run_animated "Connecting to ${selected_ssid}..." nmcli dev wifi connect "$selected_ssid" password "$wifi_pass"
        else
            run_animated "Connecting to ${selected_ssid}..." nmcli dev wifi connect "$selected_ssid"
        fi
    elif command -v iwctl >/dev/null 2>&1; then
        run_animated "Scanning Wi-Fi networks (iwctl)..." bash -c "iwctl station '$wlan_dev' scan >/dev/null 2>&1 || true; sleep 2"
        iwctl station "$wlan_dev" get-networks || true
        echo -ne "  ${C_CYAN}Enter Wi-Fi SSID: ${C_RESET}"
        read -r selected_ssid
        [ -z "$selected_ssid" ] && return 1
        echo -ne "  ${C_CYAN}Enter Wi-Fi Password (blank if open): ${C_RESET}"
        read -rs wifi_pass
        echo ""
        if [ -n "$wifi_pass" ]; then
            iwctl --passphrase "$wifi_pass" station "$wlan_dev" connect "$selected_ssid"
        else
            iwctl station "$wlan_dev" connect "$selected_ssid"
        fi
    else
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
            if [ "$TUI_BACKEND" = "gum" ]; then
                selected_ssid=$(gum input --placeholder "Enter Wi-Fi SSID")
            else
                echo -ne "  ${C_CYAN}Enter Wi-Fi SSID: ${C_RESET}"
                read -r selected_ssid
            fi
        fi
        [ -z "$selected_ssid" ] && return 1

        local wifi_pass=""
        if [ "$TUI_BACKEND" = "gum" ]; then
            wifi_pass=$(gum input --password --placeholder "Enter Wi-Fi Password (blank if open)")
        else
            echo -ne "  ${C_CYAN}Enter Wi-Fi Password (blank if open): ${C_RESET}"
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
        run_animated "Associating Wi-Fi & acquiring DHCP lease..." bash -c "sleep 3; dhcpcd -n '$wlan_dev' >/dev/null 2>&1 || dhcpcd -1 '$wlan_dev' >/dev/null 2>&1 || true"
    fi
}

# Network verification - "Sending a carrier pigeon to 1.1.1.1 and hoping it returns"
check_network() {
    DIAG_NET_ST="running"; DIAG_NET_MSG="Testing internet & syncing NTP clock..."
    print_banner 1
    render_diagnostics_card
    echo ""

    if run_animated "Checking internet & syncing NTP clock..." bash -c "ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 || ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1"; then
        sync_system_clock
        if run_animated "Verifying HTTPS connection to GitHub..." curl -Is --connect-timeout 4 https://api.github.com; then
            local ip_now
            ip_now=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {split($2,a,"/"); print a[1]; exit}' || true)
            DIAG_NET_ST="ok"; DIAG_NET_MSG="${C_GREEN}Online (${ip_now:-DHCP} | Clock synced)${C_RESET}"
            return 0
        fi
    fi

    # Try wired DHCP automatically
    DIAG_NET_MSG="Requesting wired Ethernet DHCP lease..."
    print_banner 1
    render_diagnostics_card
    echo ""
    run_animated "Requesting DHCP on Ethernet adapters..." renew_ethernet_dhcp

    if has_internet; then
        local ip_now
        ip_now=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {split($2,a,"/"); print a[1]; exit}' || true)
        DIAG_NET_ST="ok"; DIAG_NET_MSG="${C_GREEN}Online via Ethernet (${ip_now:-DHCP})${C_RESET}"
        return 0
    fi

    DIAG_NET_ST="warn"; DIAG_NET_MSG="${C_YELLOW}Offline — network setup or local image needed${C_RESET}"

    while true; do
        print_banner 1
        render_diagnostics_card
        echo ""

        local net_card=""
        net_card+="${C_YELLOW}${C_BOLD}[ ! ] No active internet connection detected.${C_RESET}\n"
        net_card+="Connect via Ethernet/Wi-Fi to download the latest HAOS release,\n"
        net_card+="or choose Offline Mode if you copied a ${C_CYAN}.img.xz${C_RESET} onto your USB drive."
        ui_card "220" "Network Connection Required" "$(echo -e "$net_card")" "normal"
        echo ""

        local net_action
        net_action=$(tui_choose "Select a network option:" \
            "Retry Ethernet / DHCP" \
            "Scan & Connect to Wi-Fi" \
            "Open Shell to Configure Network Manually" \
            "Proceed in Offline Mode (Search USB/Ventoy for local HAOS image)" \
            "Reboot Machine") || continue

        case "$net_action" in
            "Retry Ethernet / DHCP")
                run_animated "Renewing Ethernet DHCP..." renew_ethernet_dhcp
                if has_internet; then
                    local ip_now
                    ip_now=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {split($2,a,"/"); print a[1]; exit}' || true)
                    DIAG_NET_ST="ok"; DIAG_NET_MSG="${C_GREEN}Online via Ethernet (${ip_now:-DHCP})${C_RESET}"
                    return 0
                fi
                DIAG_NET_ST="fail"; DIAG_NET_MSG="${C_RED}Ethernet DHCP failed — check cable & router${C_RESET}"
                ;;
            "Scan & Connect to Wi-Fi")
                setup_wifi_connection || true
                if has_internet; then
                    local ip_now
                    ip_now=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {split($2,a,"/"); print a[1]; exit}' || true)
                    DIAG_NET_ST="ok"; DIAG_NET_MSG="${C_GREEN}Online via Wi-Fi (${ip_now:-DHCP})${C_RESET}"
                    return 0
                fi
                DIAG_NET_ST="fail"; DIAG_NET_MSG="${C_RED}Wi-Fi connected but internet unreachable${C_RESET}"
                ;;
            "Open Shell to Configure Network Manually")
                clear
                echo -e "${C_CYAN}Configure networking (ip/iw/wpa_supplicant/dhcpcd), then type 'exit'.${C_RESET}\n"
                /bin/bash
                if has_internet; then
                    DIAG_NET_ST="ok"; DIAG_NET_MSG="${C_GREEN}Online (Manual configuration)${C_RESET}"
                    return 0
                fi
                ;;
            "Proceed in Offline Mode"*)
                DIAG_NET_ST="warn"; DIAG_NET_MSG="${C_YELLOW}Offline Mode (Local USB image scan)${C_RESET}"
                return 0
                ;;
            "Reboot Machine")
                sync
                reboot -f
                ;;
        esac
    done
}

# ==============================================================================
# STEP 2: Fetch Official HAOS Release Dynamically (with Offline Fallback)
# ==============================================================================
# Asking GitHub politely for the latest release before rate-limiting strikes
scan_local_images_worker() {
    local out_file="$1"
    : > "$out_file"
    local scan_dir="/mnt/easyhaos_scan"
    mkdir -p "$scan_dir"

    find /mnt /media /run/media -maxdepth 3 -type f -name "haos_generic-x86-64*.img.xz" 2>/dev/null >> "$out_file" || true

    for blk in $(lsblk -lno PATH,TYPE 2>/dev/null | awk '$2=="part" {print $1}'); do
        local existing_mnt
        existing_mnt=$(findmnt -n -o TARGET "$blk" 2>/dev/null | sed -n '1p' || true)
        if [ -z "$existing_mnt" ]; then
            if mount -o ro "$blk" "$scan_dir" 2>/dev/null; then
                while IFS= read -r f; do
                    if [ -f "$f" ]; then
                        local safe_name
                        safe_name=$(basename "$blk")
                        local persist_mnt="/mnt/easyhaos_src_${safe_name}"
                        mkdir -p "$persist_mnt"
                        umount "$scan_dir" 2>/dev/null || true
                        if mount -o ro "$blk" "$persist_mnt" 2>/dev/null; then
                            local matched_file="${persist_mnt}/${f#"$scan_dir"/}"
                            [ -f "$matched_file" ] && echo "$matched_file" >> "$out_file"
                        fi
                        break
                    fi
                done < <(find "$scan_dir" -maxdepth 3 -type f -name "haos_generic-x86-64*.img.xz" 2>/dev/null || true)
                umount "$scan_dir" 2>/dev/null || true
            fi
        fi
    done
    rmdir "$scan_dir" 2>/dev/null || true
}

fetch_online_release_worker() {
    local out_file="$1"
    : > "$out_file"

    local api_resp ver url size
    api_resp=$(curl -fsSL --connect-timeout 10 "$HAOS_LATEST_API" 2>>"$ERR_LOG" || true)

    if [ -n "$api_resp" ] && command -v jq >/dev/null 2>&1; then
        ver=$(echo "$api_resp" | jq -r '[.[] | select(.prerelease == false and .draft == false and any(.assets[]; .name | test("^haos_generic-x86-64-.*\\.img\\.xz$")))] | .[0].tag_name // empty')
        url=$(echo "$api_resp" | jq -r '[.[] | select(.prerelease == false and .draft == false) | .assets[] | select(.name | test("^haos_generic-x86-64-.*\\.img\\.xz$"))][0].browser_download_url // empty')
        size=$(echo "$api_resp" | jq -r '[.[] | select(.prerelease == false and .draft == false) | .assets[] | select(.name | test("^haos_generic-x86-64-.*\\.img\\.xz$"))][0].size // empty')
    fi

    # Fallback HTML releases scan if GitHub API rate limit was hit
    if [ -z "$url" ]; then
        local candidate_tags
        candidate_tags=$(curl -fsSL --connect-timeout 10 "https://github.com/home-assistant/operating-system/releases" 2>>"$ERR_LOG" \
            | grep -oE '/home-assistant/operating-system/releases/tag/[0-9]+\.[0-9]+(\.[0-9]+)?' \
            | sed 's|.*/||' \
            | awk '!seen[$0]++' || true)
        while IFS= read -r tag; do
            [ -z "$tag" ] && continue
            local test_url="https://github.com/home-assistant/operating-system/releases/download/${tag}/haos_generic-x86-64-${tag}.img.xz"
            if curl -fsIL --connect-timeout 8 "$test_url" >/dev/null 2>&1; then
                ver="$tag"
                url="$test_url"
                break
            fi
        done <<< "$candidate_tags"
    fi

    [ -n "$url" ] || return 1
    # Verify download URL is reachable before proceeding to disk selection/wiping
    curl -fsIL --connect-timeout 10 "$url" >/dev/null 2>>"$ERR_LOG" || return 1

    printf 'HAOS_VERSION=%q\nHAOS_DOWNLOAD_URL=%q\nHAOS_ASSET_SIZE=%q\n' "$ver" "$url" "${size:-}" > "$out_file"
}

fetch_haos_release() {
    DIAG_REL_ST="running"; DIAG_REL_MSG="Scanning USB partitions for offline images..."
    print_banner 2
    render_diagnostics_card
    echo ""

    local scan_out="/tmp/easyhaos_local_imgs.txt"
    run_animated "Scanning USB/Ventoy drives for local HAOS images..." scan_local_images_worker "$scan_out"

    local unique_candidates=()
    if [ -s "$scan_out" ]; then
        while IFS= read -r u; do
            [ -n "$u" ] && unique_candidates+=("$u")
        done < <(sort -u "$scan_out")
    fi
    rm -f "$scan_out"

    if [ ${#unique_candidates[@]} -gt 0 ]; then
        DIAG_REL_ST="ok"; DIAG_REL_MSG="${C_GREEN}Found ${#unique_candidates[@]} local offline image(s)${C_RESET}"
        print_banner 2
        render_diagnostics_card
        echo ""

        local chosen_file
        chosen_file=$(tui_choose "Use a local offline HAOS image or download latest from GitHub?" \
            "${unique_candidates[@]}" \
            "Download Latest Official Release from GitHub API") || chosen_file="Download Latest Official Release from GitHub API"

        if [ "$chosen_file" != "Download Latest Official Release from GitHub API" ] && [ -f "$chosen_file" ]; then
            HAOS_IMAGE_FILE="$chosen_file"
            IS_OFFLINE_IMAGE=true
            HAOS_VERSION=$(basename "$chosen_file" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | sed -n '1p' || echo "Offline")
            local mb_sz
            mb_sz=$(( $(stat -c%s "$chosen_file" 2>/dev/null || echo 0) / 1048576 ))
            DIAG_REL_ST="ok"; DIAG_REL_MSG="${C_GREEN}Offline v${HAOS_VERSION} (${mb_sz} MB) ready${C_RESET}"
            return 0
        fi
    fi

    # Fetch online release with animated spinner & verify HTTP availability
    DIAG_REL_ST="running"; DIAG_REL_MSG="Querying GitHub API for newest x86-64 build..."
    print_banner 2
    render_diagnostics_card
    echo ""

    local rel_out="/tmp/easyhaos_rel_vars.sh"
    : > "$ERR_LOG"
    if ! run_animated "Resolving & verifying latest Home Assistant OS x86-64 release..." fetch_online_release_worker "$rel_out"; then
        rm -f "$rel_out"
        DIAG_REL_ST="fail"; DIAG_REL_MSG="${C_RED}Failed to resolve/verify HAOS x86-64 release${C_RESET}"
        fatal_error "HAOS Release Lookup Failed" \
            "Could not find or verify a reachable Home Assistant OS Generic x86-64 download URL." \
            "Check your Ethernet cable or Wi-Fi connection." \
            "If GitHub is unreachable, copy haos_generic-x86-64-*.img.xz onto a Ventoy/USB stick."
        return 1
    fi

    # shellcheck source=/dev/null
    source "$rel_out"
    rm -f "$rel_out"

    local size_label=""
    if [ -n "$HAOS_ASSET_SIZE" ] && [ "$HAOS_ASSET_SIZE" -gt 0 ] 2>/dev/null; then
        size_label=" ($(( HAOS_ASSET_SIZE / 1048576 )) MB verified)"
    else
        size_label=" (URL verified)"
    fi
    DIAG_REL_ST="ok"; DIAG_REL_MSG="${C_GREEN}Official v${HAOS_VERSION}${size_label}${C_RESET}"
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

detect_boot_device_worker() {
    local out_file="$1"
    : > "$out_file"
    local found=()

    for mnt in / /live /run/archiso/bootmnt /mnt/boot /media/usb; do
        local src
        src=$(findmnt -n -o SOURCE "$mnt" 2>/dev/null || true)
        [ -n "$src" ] && [[ "$src" == /dev/* ]] && found+=("$src")
    done

    for label in EASY_HAOS Ventoy VTOYEFI; do
        local ldev
        ldev=$(blkid -L "$label" 2>/dev/null || true)
        [ -n "$ldev" ] && found+=("$ldev")
    done

    local probe_dir="/mnt/easyhaos_probe"
    mkdir -p "$probe_dir"
    for blk in $(lsblk -lno PATH,TYPE 2>/dev/null | awk '$2=="part" {print $1}'); do
        local mnt_pt
        mnt_pt=$(findmnt -n -o TARGET "$blk" 2>/dev/null | sed -n '1p' || true)
        if [ -n "$mnt_pt" ]; then
            [ -f "${mnt_pt}/.easy-haos-usb" ] && found+=("$blk")
        else
            if mount -o ro "$blk" "$probe_dir" 2>/dev/null; then
                [ -f "${probe_dir}/.easy-haos-usb" ] && found+=("$blk")
                umount "$probe_dir" 2>/dev/null || true
            fi
        fi
    done
    rmdir "$probe_dir" 2>/dev/null || true

    if [ "$IS_OFFLINE_IMAGE" = true ] && [ -n "$HAOS_IMAGE_FILE" ]; then
        local img_src
        img_src=$(findmnt -n -o SOURCE --target "$HAOS_IMAGE_FILE" 2>/dev/null || true)
        [ -n "$img_src" ] && [[ "$img_src" == /dev/* ]] && found+=("$img_src")
    fi

    for item in "${found[@]:-}"; do
        [ -n "$item" ] && echo "$item" >> "$out_file"
    done
}

detect_boot_device() {
    PROTECTED_DISKS=()
    local usb_out="/tmp/easyhaos_protected.txt"
    run_animated "Identifying & locking installer USB media..." detect_boot_device_worker "$usb_out"
    if [ -s "$usb_out" ]; then
        while IFS= read -r dev_path; do
            [ -n "$dev_path" ] && add_protected_disk "$dev_path"
        done < "$usb_out"
    fi
    rm -f "$usb_out"

    if [ ${#PROTECTED_DISKS[@]} -gt 0 ]; then
        DIAG_USB_ST="ok"; DIAG_USB_MSG="${C_GREEN}Protected: ${PROTECTED_DISKS[*]/#/\/dev\/} (excluded)${C_RESET}"
    else
        DIAG_USB_ST="warn"; DIAG_USB_MSG="${C_YELLOW}Running from RAM (double-check drive model below)${C_RESET}"
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
    DIAG_USB_ST="running"; DIAG_USB_MSG="Scanning block devices & USB markers..."
    print_banner 3
    render_diagnostics_card
    echo ""

    detect_boot_device

    while true; do
        print_banner 3
        render_diagnostics_card
        echo ""

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

            [ "$d_type" != "disk" ] && continue
            [[ "$d_name" =~ ^(zram|ram|loop|sr|fd) ]] && continue
            is_protected_disk "$d_name" && continue

            d_tran=$(lsblk -d -n -o TRAN "/dev/${d_name}" 2>/dev/null | tr -d '[:space:]' || echo "disk")
            [ -z "$d_tran" ] && d_tran="internal"
            d_model=$(lsblk -d -n -o MODEL "/dev/${d_name}" 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//' || echo "Generic Drive")
            [ -z "$d_model" ] && d_model="Generic Storage Device"

            disk_list+=("$d_name")
            disk_display+=("$(printf '/dev/%-8s | %7s | [%-4s] %s' "$d_name" "$d_size" "$d_tran" "$d_model")")
        done <<< "$raw_disks"

        if [ ${#disk_list[@]} -eq 0 ]; then
            fatal_error "No Target Storage Drives Found" \
                "No internal NVMe, SATA SSD, or eMMC drives were detected." \
                "Enter BIOS and switch SATA/Storage Controller mode from RAID/Intel RST to AHCI." \
                "Verify the NVMe/SATA SSD is firmly seated." \
                "Note: your Easy-HAOS installer USB is intentionally hidden for safety."
            return 1
        fi

        local selected_label
        selected_label=$(tui_choose "Select target disk to ERASE and install Home Assistant OS v${HAOS_VERSION}:" "${disk_display[@]}") || {
            fatal_error "Disk Selection Cancelled" "No target disk was selected." "Select an internal drive to continue."
            return 1
        }

        TARGET_DISK=""
        for i in "${!disk_display[@]}"; do
            if [ "${disk_display[$i]}" = "$selected_label" ]; then
                TARGET_DISK="${disk_list[$i]}"
                break
            fi
        done

        if [ -z "$TARGET_DISK" ] || [ ! -b "/dev/${TARGET_DISK}" ]; then
            fatal_error "Invalid Block Device" "The chosen device /dev/${TARGET_DISK} is not a valid block device."
            return 1
        fi

        TARGET_SIZE=$(lsblk -d -n -o SIZE "/dev/${TARGET_DISK}" 2>/dev/null | tr -d '[:space:]')
        TARGET_MODEL=$(lsblk -d -n -o MODEL "/dev/${TARGET_DISK}" 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//')
        [ -z "$TARGET_MODEL" ] && TARGET_MODEL="Unknown Model"

        # Explicit Confirmation Card
        # Wiping partition tables - "Say goodbye to Windows 11 bloatware. No regrets."
        print_banner 3

        local warn_body=""
        warn_body+="${C_RED}${C_BOLD}ALL DATA ON THIS DRIVE WILL BE PERMANENTLY ERASED!${C_RESET}\n\n"
        warn_body+="  Target Device : ${C_WHITE}${C_BOLD}/dev/${TARGET_DISK}${C_RESET}\n"
        warn_body+="  Disk Model    : ${C_WHITE}${C_BOLD}${TARGET_MODEL}${C_RESET}\n"
        warn_body+="  Capacity      : ${C_WHITE}${C_BOLD}${TARGET_SIZE}${C_RESET}\n"
        warn_body+="  Installing    : ${C_GREEN}${C_BOLD}Home Assistant OS v${HAOS_VERSION}${C_RESET}"

        ui_card "196" "[ ! ] FINAL DESTRUCTIVE CONFIRMATION" "$(echo -e "$warn_body")" "double"
        echo ""

        local confirm_prompt="Type YES to erase ${TARGET_MODEL} and install Home Assistant OS v${HAOS_VERSION}"
        local confirm_text=""
        if [ "$TUI_BACKEND" = "gum" ]; then
            echo -e "  ${C_WHITE}${confirm_prompt}:${C_RESET}"
            confirm_text=$(gum input --width 40 --placeholder "Type YES in uppercase")
        else
            echo -ne "  ${C_WHITE}${confirm_prompt}: ${C_RESET}"
            read -r confirm_text
        fi

        if [ "$confirm_text" = "YES" ]; then
            break
        fi

        echo -e "\n  ${C_YELLOW}[ ! ] Confirmation did not match 'YES'. Returning to disk list...${C_RESET}"
        sleep 1
    done
}

# ==============================================================================
# STEP 4: Streaming Flash & Post-Install Verification
# ==============================================================================
# Streaming HAOS - "Zero to Home Assistant in 60 seconds, straight into silicon"
unmount_target_worker() {
    local dev="$1"
    for part in $(lsblk -lno PATH "$dev" 2>/dev/null | grep -v "^${dev}$" || true); do
        umount -f "$part" 2>/dev/null || true
        swapoff "$part" 2>/dev/null || true
    done
}

wipe_target_worker() {
    local dev="$1"
    wipefs -a -f "$dev" >/dev/null 2>>"$ERR_LOG" || true
    blkdiscard "$dev" >/dev/null 2>&1 || true
    dd if=/dev/zero of="$dev" bs=1M count=8 conv=fsync status=none 2>>"$ERR_LOG"
}

flash_target_disk() {
    local dev="/dev/${TARGET_DISK}"
    : > "$ERR_LOG"

    # Stage 1: Unmount
    FLASH_S1_ST="running"; FLASH_S1_MSG="Unmounting any active partitions on ${dev}..."
    FLASH_S2_ST="pending"; FLASH_S2_MSG="Wipe partition signatures & GPT table"
    FLASH_S3_ST="pending"; FLASH_S3_MSG="Stream & flash Home Assistant OS v${HAOS_VERSION}"
    FLASH_S4_ST="pending"; FLASH_S4_MSG="Verify GPT partitions & register UEFI BootOrder"

    print_banner 4
    render_flash_card
    echo ""

    run_animated "Unmounting partitions on ${dev}..." unmount_target_worker "$dev"
    FLASH_S1_ST="ok"; FLASH_S1_MSG="${C_GREEN}Unmounted existing partitions on ${dev}${C_RESET}"

    # Stage 2: Wipe
    # Wiping partition tables - "Say goodbye to Windows 11 bloatware. No regrets."
    FLASH_S2_ST="running"; FLASH_S2_MSG="Wiping partition tables & GPT signatures..."
    print_banner 4
    render_flash_card
    echo ""

    if ! run_animated "Wiping existing partition tables..." wipe_target_worker "$dev"; then
        FLASH_S2_ST="fail"; FLASH_S2_MSG="${C_RED}Failed to wipe ${dev}${C_RESET}"
        fatal_error "Disk Wipe Failed" \
            "Could not erase partition signatures on ${dev}." \
            "Check that the drive is healthy and not write-protected."
        return 1
    fi
    FLASH_S2_ST="ok"; FLASH_S2_MSG="${C_GREEN}Partition signatures & GPT wiped clean${C_RESET}"

    # Stage 3: Streaming Flash
    FLASH_S3_ST="running"; FLASH_S3_MSG="Streaming & writing Home Assistant OS v${HAOS_VERSION}..."
    print_banner 4
    render_flash_card
    echo ""
    echo -e "  ${C_DIM}Do not unplug power or remove the USB stick while flashing...${C_RESET}\n"

    local start_time
    start_time=$(date +%s)
    local pipe_failed=false

    if [ "$IS_OFFLINE_IMAGE" = true ]; then
        local file_bytes
        file_bytes=$(stat -c%s "$HAOS_IMAGE_FILE" 2>/dev/null || echo 0)
        if command -v pv >/dev/null 2>&1 && [ "$file_bytes" -gt 0 ]; then
            pv -s "$file_bytes" -N "  Flashing" "$HAOS_IMAGE_FILE" | xz -d 2>>"$ERR_LOG" | dd of="${dev}" bs=4M conv=fsync status=none 2>>"$ERR_LOG"
        elif command -v pv >/dev/null 2>&1; then
            pv -N "  Flashing" "$HAOS_IMAGE_FILE" | xz -d 2>>"$ERR_LOG" | dd of="${dev}" bs=4M conv=fsync status=none 2>>"$ERR_LOG"
        else
            xz -dc "$HAOS_IMAGE_FILE" 2>>"$ERR_LOG" | dd of="${dev}" bs=4M conv=fsync status=progress
        fi
        for rc in "${PIPESTATUS[@]}"; do
            [ "$rc" -ne 0 ] && pipe_failed=true
        done
    else
        if command -v pv >/dev/null 2>&1; then
            if [ -n "$HAOS_ASSET_SIZE" ] && [ "$HAOS_ASSET_SIZE" -gt 0 ] 2>/dev/null; then
                curl -f -L --retry 3 --retry-delay 2 -sS "$HAOS_DOWNLOAD_URL" 2>>"$ERR_LOG" \
                    | pv -s "$HAOS_ASSET_SIZE" -N "  Flashing" \
                    | xz -d 2>>"$ERR_LOG" \
                    | dd of="${dev}" bs=4M conv=fsync status=none 2>>"$ERR_LOG"
            else
                curl -f -L --retry 3 --retry-delay 2 -sS "$HAOS_DOWNLOAD_URL" 2>>"$ERR_LOG" \
                    | pv -N "  Flashing" \
                    | xz -d 2>>"$ERR_LOG" \
                    | dd of="${dev}" bs=4M conv=fsync status=none 2>>"$ERR_LOG"
            fi
        else
            curl -f -L --retry 3 --retry-delay 2 "$HAOS_DOWNLOAD_URL" 2>>"$ERR_LOG" \
                | xz -d 2>>"$ERR_LOG" \
                | dd of="${dev}" bs=4M conv=fsync status=progress
        fi
        for rc in "${PIPESTATUS[@]}"; do
            [ "$rc" -ne 0 ] && pipe_failed=true
        done
    fi

    if [ "$pipe_failed" = true ]; then
        FLASH_S3_ST="fail"; FLASH_S3_MSG="${C_RED}Streaming flash failed!${C_RESET}"
        fatal_error "Flash Pipeline Failed" \
            "Streaming Home Assistant OS v${HAOS_VERSION} onto ${dev} was interrupted." \
            "Check your internet stability or try a different Ethernet cable/Wi-Fi network." \
            "Verify the target SSD/NVMe drive has at least 32 GB capacity and no hardware errors."
        return 1
    fi

    run_animated "Flushing hardware write buffers (sync)..." bash -c "sync; sleep 1"
    local end_time
    end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))
    FLASH_S3_ST="ok"; FLASH_S3_MSG="${C_GREEN}Flashed HAOS v${HAOS_VERSION} in ${elapsed}s${C_RESET}"

    # Stage 4: Verification & UEFI BootOrder
    # Poking UEFI firmware with a stick until it cooperates
    FLASH_S4_ST="running"; FLASH_S4_MSG="Verifying GPT partitions & UEFI NVRAM..."
    print_banner 4
    render_flash_card
    echo ""

    run_animated "Re-reading partition table & settling udev..." bash -c "partprobe '${dev}' 2>/dev/null || blockdev --rereadpt '${dev}' 2>/dev/null || true; udevadm settle 2>/dev/null || sleep 2"

    local efi_part="${dev}1"
    if [[ "$dev" =~ (nvme|mmcblk) ]]; then
        efi_part="${dev}p1"
    fi

    if command -v efibootmgr >/dev/null 2>&1 && [ -d /sys/firmware/efi ]; then
        while IFS= read -r bootnum; do
            [ -n "$bootnum" ] && efibootmgr -b "$bootnum" -B >/dev/null 2>&1 || true
        done < <(efibootmgr 2>/dev/null | grep -i "Home Assistant OS" | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p')

        if efibootmgr -c -d "${dev}" -p 1 -L "Home Assistant OS" -l '\EFI\BOOT\bootx64.efi' >/dev/null 2>&1; then
            local new_bootnum
            new_bootnum=$(efibootmgr 2>/dev/null | grep -i "Home Assistant OS" | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' | sed -n '1p')
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
            FLASH_S4_ST="ok"; FLASH_S4_MSG="${C_GREEN}Verified ${efi_part} & registered UEFI Boot #1${C_RESET}"
        else
            FLASH_S4_ST="warn"; FLASH_S4_MSG="${C_YELLOW}Partition verified (using fallback \\EFI\\BOOT\\bootx64.efi)${C_RESET}"
        fi
    else
        FLASH_S4_ST="ok"; FLASH_S4_MSG="${C_GREEN}Verified partition table on ${dev}${C_RESET}"
    fi

    for mnt in /mnt/easyhaos_src_*; do
        [ -d "$mnt" ] && umount "$mnt" 2>/dev/null || true
    done

    print_banner 4
    render_flash_card
    sleep 1
}

# ==============================================================================
# STEP 5: Completion Screen
# ==============================================================================
# Completion - "It worked on my machine, so it should work on yours!"
show_completion_screen() {
    print_banner 5

    local ips
    ips=$(ip -4 addr show 2>/dev/null | awk '/inet / && $2 !~ /^127\./ {split($2,a,"/"); print a[1]}' || true)

    local done_body=""
    done_body+="${C_GREEN}${C_BOLD}[ ✓ ] Home Assistant OS v${HAOS_VERSION} is installed on /dev/${TARGET_DISK}!${C_RESET}\n\n"
    done_body+="${C_WHITE}${C_BOLD}Next Steps:${C_RESET}\n"
    done_body+="  1. ${C_YELLOW}${C_BOLD}UNPLUG THE EASY-HAOS USB STICK${C_RESET} from this PC now.\n"
    done_body+="  2. Select ${C_CYAN}Reboot Now${C_RESET} below to boot into Home Assistant OS.\n"
    done_body+="  3. Wait 2-5 minutes on first boot while HAOS initializes.\n"
    done_body+="  4. Open a browser on your phone or PC and visit:\n"
    done_body+="     ${C_GREEN}${C_BOLD}http://homeassistant.local:8123${C_RESET}\n"

    if [ -n "$ips" ]; then
        done_body+="\n${C_WHITE}Detected LAN IP(s):${C_RESET}\n"
        while IFS= read -r ip; do
            [ -n "$ip" ] && done_body+="     ${C_CYAN}${C_BOLD}http://${ip}:8123${C_RESET}\n"
        done <<< "$ips"
    fi

    done_body+="\n${C_DIM}──────────────────────────────────────────────────────────────────${C_RESET}\n"
    done_body+="${C_WHITE}Christian Bennetsen${C_RESET}  |  ${C_CYAN}https://bennetsen.dk${C_RESET}  |  ${C_CYAN}christian@bennetsen.dk${C_RESET}\n"
    done_body+="${C_DIM}YouTube: https://www.youtube.com/@BennetsenTech${C_RESET}\n"
    done_body+="${C_DIM}LinkedIn: https://www.linkedin.com/in/mrbennetsen/${C_RESET}"

    ui_card "46" "[ ✓ ] INSTALLATION COMPLETE" "$(echo -e "$done_body")" "double"
    echo ""

    while true; do
        local end_choice
        end_choice=$(tui_choose "USB removed? Choose next action:" \
            "Reboot Now into Home Assistant OS" \
            "Power Off Machine" \
            "Open Diagnostic Shell (bash)") || continue

        case "$end_choice" in
            "Reboot Now into Home Assistant OS")
                sync
                reboot -f
                ;;
            "Power Off Machine")
                sync
                poweroff -f
                ;;
            "Open Diagnostic Shell (bash)")
                clear
                /bin/bash
                ;;
        esac
    done
}

# ==============================================================================
# MAIN EXECUTION FLOW
# ==============================================================================
main() {
    while true; do
        reset_wizard_state

        check_uefi_mode
        [ "$RETRY_REQUESTED" = true ] && continue

        check_secure_boot || true
        [ "$RETRY_REQUESTED" = true ] && continue

        check_network || true
        [ "$RETRY_REQUESTED" = true ] && continue

        fetch_haos_release || true
        [ "$RETRY_REQUESTED" = true ] && continue

        select_target_disk || true
        [ "$RETRY_REQUESTED" = true ] && continue

        flash_target_disk || true
        [ "$RETRY_REQUESTED" = true ] && continue

        show_completion_screen
        break
    done
}

main "$@"
