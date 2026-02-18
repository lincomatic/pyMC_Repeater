#!/bin/bash
# pyMC Repeater Management Script - Deploy, Upgrade, Uninstall

# Wrap everything in a function to ensure the script is loaded into memory
main() {
    set -e

    INSTALL_DIR="/opt/pymc_repeater"
    CONFIG_DIR="/etc/pymc_repeater"
    LOG_DIR="/var/log/pymc_repeater"
    SERVICE_USER="repeater"
    SERVICE_NAME="pymc-repeater"

    # --- Helper Functions ---
    # (Checking for interactive terminal, dialog/whiptail setup, etc.)
    
    # ... [Same helper functions as before: show_info, show_error, etc.] ...
    
    # [Including only the modified upgrade_repeater for brevity, full script logic follows]

    upgrade_repeater() {
        if [ "$EUID" -ne 0 ]; then show_error "Please run with sudo."; return; fi
        
        if [[ ! -t 0 ]] || ask_yes_no "Confirm Upgrade" "Pull latest code and refresh pymc_core?"; then
            echo "=== Starting Upgrade ==="
            
            if [ -d .git ]; then
                echo "[1/4] Checking for script and code updates..."
                OLD_HASH=$(md5sum "$0" 2>/dev/null || echo "")
                
                # Pull changes
                if git pull; then
                    NEW_HASH=$(md5sum "$0" 2>/dev/null || echo "")
                    
                    # SELF-RESTART LOGIC
                    if [ "$OLD_HASH" != "$NEW_HASH" ]; then
                        echo "⚠ manage.sh was updated. Re-executing script..."
                        sleep 1
                        exec "$0" "$@"
                    fi
                else
                    echo "Warning: git pull failed, continuing with local files."
                fi
            fi
            
            echo "[2/4] Stopping service..."
            systemctl stop "$SERVICE_NAME" || true
            
            echo "[3/4] Syncing files to $INSTALL_DIR..."
            cp -r repeater "$INSTALL_DIR/"
            cp pyproject.toml "$INSTALL_DIR/"
            
            # This calls the pip refresh logic we built earlier
            if run_pip_install; then
                echo "[4/4] Restarting service..."
                systemctl daemon-reload
                systemctl start "$SERVICE_NAME"
                show_info "Done" "Upgrade successful."
            else
                show_error "Upgrade failed during pip install."
            fi
        fi
    }

    # --- Re-including the rest of the logic inside the main function ---
    
    run_pip_install() {
        echo "=== Updating Dependencies ==="
        export PIP_ROOT_USER_ACTION=ignore
        echo "Forcing fresh pull of pymc_core [hardware] (@mqtt)..."
        python3 -m pip install --break-system-packages --force-reinstall --no-cache-dir "pymc_core[hardware] @ git+https://github.com/lincomatic/pyMC_core.git@mqtt"
        python3 -m pip install --break-system-packages .
    }

    install_repeater() {
        # ... [Install logic from previous version] ...
        if [ "$EUID" -ne 0 ]; then show_error "Please run with sudo."; return; fi
        apt-get update -qq && apt-get install -y libffi-dev jq pip python3-rrdtool wget swig build-essential python3-dev
        mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" /var/lib/pymc_repeater
        cp -r repeater "$INSTALL_DIR/"
        cp pyproject.toml "$INSTALL_DIR/"
        run_pip_install
        systemctl enable --now "$SERVICE_NAME"
    }

    reset_repeater() {
        systemctl stop "$SERVICE_NAME" || true
        cp "$CONFIG_DIR/config.yaml.example" "$CONFIG_DIR/config.yaml"
        systemctl start "$SERVICE_NAME"
    }

    uninstall_repeater() {
        systemctl stop "$SERVICE_NAME" || true
        rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" /etc/systemd/system/pymc-repeater.service
        systemctl daemon-reload
    }

    manage_service() {
        systemctl "$1" "$SERVICE_NAME"
    }

    show_detailed_status() {
        local ver=$(get_version)
        echo "Status: $ver"
    }

    show_main_menu() {
        # ... [Menu logic from previous version] ...
        CHOICE=$($DIALOG --backtitle "pyMC Repeater" --title "Management Menu" --menu "Action:" 18 70 9 \
            "install" "Install" "upgrade" "Upgrade" "reset" "Reset" "uninstall" "Uninstall" \
            "start" "Start" "stop" "Stop" "restart" "Restart" "logs" "Logs" "status" "Status" "exit" "Exit" 3>&1 1>&2 2>&3)
        case $CHOICE in
            install) install_repeater ; show_main_menu ;;
            upgrade) upgrade_repeater ; show_main_menu ;;
            reset)   reset_repeater   ; show_main_menu ;;
            uninstall) uninstall_repeater ;;
            start|stop|restart) manage_service "$CHOICE" ; show_main_menu ;;
            logs) clear ; journalctl -u "$SERVICE_NAME" -f ;;
            status) show_detailed_status ; show_main_menu ;;
            exit|"") exit 0 ;;
        esac
    }

    # --- Argument Handling inside main ---
    if [ -z "$1" ]; then
        show_main_menu
    else
        case "$1" in
            install)   install_repeater ;;
            upgrade)   upgrade_repeater ;;
            reset)     reset_repeater ;;
            uninstall) uninstall_repeater ;;
            start|stop|restart) manage_service "$1" ;;
            status)    show_detailed_status ;;
            logs)      journalctl -u "$SERVICE_NAME" -f ;;
            *)         echo "Usage: $0 {install|upgrade|reset|uninstall|start|stop|restart|status|logs}" ; exit 1 ;;
        esac
    fi
}

# --- THE TRIGGER ---
# Pass all script arguments to the main function
main "$@"