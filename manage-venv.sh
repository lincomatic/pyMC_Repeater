#!/bin/bash
# pyMC Repeater Management Script - VENV + SELF-HEALING

main() {
    set -e

    INSTALL_DIR="/opt/pymc_repeater"
    VENV_DIR="$INSTALL_DIR/venv"
    CONFIG_DIR="/etc/pymc_repeater"
    LOG_DIR="/var/log/pymc_repeater"
    SERVICE_USER="repeater"
    SERVICE_NAME="pymc-repeater"

    # --- Helpers ---
    show_info() { [ -t 0 ] && $DIALOG --backtitle "pyMC" --msgbox "$2" 12 70 || echo "INFO: $2"; }
    show_error() { [ -t 0 ] && $DIALOG --backtitle "pyMC" --msgbox "$1" 8 60 || echo "ERROR: $1"; }
    ask_yes_no() { [ -t 0 ] && $DIALOG --backtitle "pyMC" --yesno "$2" 10 70 || return 0; }
    
    is_running() { systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; }

    run_pip_venv() {
        echo "=== Updating Virtual Environment ==="
        if [ ! -d "$VENV_DIR" ]; then
            echo "Creating venv..."
            python3 -m venv "$VENV_DIR"
        fi

        echo "Forcing fresh pull of pymc_core [hardware] (@mqtt)..."
        # We use the venv's pip directly
        "$VENV_DIR/bin/pip" install --upgrade pip
        "$VENV_DIR/bin/pip" install --force-reinstall --no-cache-dir "pymc_core[hardware] @ git+https://github.com/lincomatic/pyMC_core.git@mqtt"

        echo "Installing repeater package..."
        "$VENV_DIR/bin/pip" install .
    }

    # --- Actions ---
    install_repeater() {
        if [ "$EUID" -ne 0 ]; then show_error "Run with sudo."; return; fi
        
        echo "Installing system dependencies..."
        apt-get update -qq && apt-get install -y python3-venv python3-pip libffi-dev jq wget swig build-essential python3-dev
        
        if ! id "$SERVICE_USER" &>/dev/null; then 
            useradd --system --home /var/lib/pymc_repeater --shell /sbin/nologin "$SERVICE_USER"
        fi
        
        mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" /var/lib/pymc_repeater
        cp -r repeater pyproject.toml "$INSTALL_DIR/"
        
        run_pip_venv
        
        cp pymc-repeater.service /etc/systemd/system/
        chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR"
        
        systemctl daemon-reload
        systemctl enable --now "$SERVICE_NAME"
        show_info "Success" "Installation complete in VENV."
    }

    upgrade_repeater() {
        if [ "$EUID" -ne 0 ]; then show_error "Run with sudo."; return; fi
        
        if ask_yes_no "Upgrade" "Pull code and refresh VENV?"; then
            if [ -d .git ]; then
                OLD_HASH=$(md5sum "$0" 2>/dev/null || echo "")
                git pull
                if [ "$OLD_HASH" != "$(md5sum "$0" 2>/dev/null)" ]; then
                    echo "manage.sh updated. Restarting..."
                    exec "$0" "$@"
                fi
            fi

            systemctl stop "$SERVICE_NAME" || true
            cp -r repeater pyproject.toml "$INSTALL_DIR/"
            
            # Navigate to install dir to run pip install .
            cd "$INSTALL_DIR"
            run_pip_venv
            
            systemctl daemon-reload
            systemctl start "$SERVICE_NAME"
            show_info "Done" "Upgrade finished."
        fi
    }

    # --- Menu/CLI Logic ---
    if command -v whiptail &> /dev/null; then DIALOG="whiptail"; else DIALOG="dialog"; fi

    if [ -z "$1" ]; then
        CHOICE=$($DIALOG --menu "pyMC VENV Manager" 18 70 10 \
            "install" "Full Install" \
            "upgrade" "Upgrade (Refresh Core)" \
            "status" "Check Status" \
            "logs" "View Logs" \
            "exit" "Exit" 3>&1 1>&2 2>&3)
        case $CHOICE in
            install) install_repeater ;;
            upgrade) upgrade_repeater ;;
            status)  show_info "Status" "Running: $(is_running && echo 'Yes' || echo 'No')" ;;
            logs)    clear; journalctl -u "$SERVICE_NAME" -f ;;
            *) exit 0 ;;
        esac
    else
        case "$1" in
            install) install_repeater ;;
            upgrade) upgrade_repeater ;;
            start|stop|restart) systemctl "$1" "$SERVICE_NAME" ;;
            logs) journalctl -u "$SERVICE_NAME" -f ;;
            *) echo "Usage: $0 {install|upgrade|start|stop|restart|logs}" ;;
        esac
    fi
}

main "$@"
