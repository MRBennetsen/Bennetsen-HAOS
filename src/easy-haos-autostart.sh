#!/usr/bin/env bash
# ==============================================================================
# Easy-HAOS tty1 Auto-Start Wrapper
# ==============================================================================
# Start GUI installation - "I have no idea how I got this to work"
# Automatically launches the installer on tty1 at boot.
#
# Christian Bennetsen | https://bennetsen.dk | christian@bennetsen.dk
# ==============================================================================

export TERM="${TERM:-linux}"

# Ensure cursor is visible and clear boot messages
setterm -cursor on 2>/dev/null || true
clear

# Load readable console font if available
setfont Lat15-TerminusBold16 2>/dev/null || setfont default8x16 2>/dev/null || true

while true; do
    if [ -x /usr/local/bin/installer.sh ]; then
        /usr/local/bin/installer.sh
    elif [ -x /usr/bin/installer.sh ]; then
        /usr/bin/installer.sh
    else
        echo "CRITICAL: /usr/local/bin/installer.sh not found!"
    fi

    echo ""
    echo "======================================================================"
    echo " Easy-HAOS Installer exited."
    echo "  • Type 'installer' to restart the installer."
    echo "  • Type 'reboot' to restart the machine."
    echo "  • Type 'poweroff' to shut down."
    echo "======================================================================"
    echo ""
    /bin/bash --login
done
