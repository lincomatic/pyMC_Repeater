#!/bin/bash
# pyMC Repeater Management Script - Deploy, Upgrade, Uninstall

main() {
    set -e

    INSTALL_DIR="/opt/pymc_repeater"
    CONFIG_DIR="/etc/pymc_repeater"
    LOG_DIR="/var/log/pymc_repeater"
    SERVICE_USER="repeater"
    SERVICE_NAME="pymc-repeater"

    # --- Helper Functions (Inside main to ensure memory loading) ---

    show_info() {
        if [ -t 0 ]; then
            $DIALOG --backtitle "pyMC Repeater" --title "$1" --msgbox "$2" 12 70
        else
            echo -e "\nINFO [$1]: $2"
        fi
    }

    show_error() {
        if [ -t 0 ]; then
            $DIALOG --backtitle "pyMC Repeater" --title "Error" --msgbox "$1" 8 60
        else
            echo -e "\nERROR: $1"
        fi
    }

    ask_yes_no() {
        if [ -t 0 ]; then
            $DIALOG --backtitle "pyMC Repeater" --title "$1" --yesno "$2" 10 70
        else
            # If not interactive, assume yes
            return 0
        fi
    }

    service_exists() {
        systemctl list-unit-files | grep -q "^$SERVICE_NAME.service"
    }

    is_installed() {
        [ -d "$INSTALL_DIR" ] && service_exists
    }

    is_running() {
        systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1
    }

    get_version() {
        if [ -f "$INSTALL_DIR/repeater/_version.py" ]; then
            grep "^__version__ = version = " "$INSTALL_DIR/repeater/_version.py" | cut -d"'" -f2 2>/dev/null || echo "unknown"
        elif [ -f "$INSTALL_DIR/pyproject.toml" ]; then
            grep "^version" "$INSTALL_DIR/pyproject.toml" | cut -d'"' -f2 2>/dev/null || echo "unknown"
        else
            echo "not installed"
        fi
    }

    run_pip_install() {
        echo "=== Updating Dependencies ==="
        export PIP_ROOT_USER_ACTION=ignore
        
        echo "Forcing fresh pull of pymc_core [hardware] from GitHub (@mqtt)..."
        if python3 -m pip install --break-system-packages --force-reinstall --no-cache-dir "pymc_core[hardware] @ git+https://github.com/lincomatic/pyMC_core.git@mqtt"; then
            echo "    ✓ pymc_core updated."
        else
            echo "    ✗ Failed to update pymc_core."
            return 1
        fi
        

        echo ""
        echo "✓ All packages including pymc_core reinstalled successfully"

        echo "Updating repeater package and stable dependencies..."
        if python3 -m pip install --break-system-packages .; then
            echo "    ✓ Repeater installation updated."
            return 0
        else
            echo "    ✗ Repeater installation failed."
            return 1
        fi
    }

    # --- Action Functions ---

    install_repeater() {
        if [ "$EUID" -ne 0 ]; then show_error "Requires root privileges (sudo)."; return; fi
        
        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        
        echo "Creating service user and directories..."
        if ! id "$SERVICE_USER" &>/dev/null; then 
            useradd --system --home /var/lib/pymc_repeater --shell /sbin/nologin "$SERVICE_USER"
        fi
        usermod -a -G gpio,i2c,spi,dialout "$SERVICE_USER" 2>/dev/null || true
        mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" /var/lib/pymc_repeater
        
        echo "Installing system dependencies..."
        apt-get update -qq && apt-get install -y libffi-dev jq pip python3-rrdtool wget swig build-essential python3-dev
        
        cp -r "$SCRIPT_DIR/repeater" "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/pyproject.toml" "$INSTALL_DIR/"
        cp "$SCRIPT_DIR/config.yaml.example" "$CONFIG_DIR/"
        [ ! -f "$CONFIG_DIR/config.yaml" ] && cp "$SCRIPT_DIR/config.yaml.example" "$CONFIG_DIR/config.yaml"
        cp "$SCRIPT_DIR/pymc-repeater.service" /etc/systemd/system/
        
        chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" /var/lib/pymc_repeater
        
        if run_pip_install; then
            systemctl daemon-reload
            systemctl enable --now "$SERVICE_NAME"
            show_info "Success" "Installation Complete."
        else
            show_error "Python installation failed."
        fi
    }

    upgrade_repeater() {
        if [ "$EUID" -ne 0 ]; then show_error "Requires root privileges (sudo)."; return; fi
        
        if ask_yes_no "Confirm Upgrade" "This will pull latest code and force-refresh pymc_core."; then
            echo "=== Starting Upgrade ==="
            
            if [ -d .git ]; then
                echo "[1/4] Checking for code and script updates..."
                OLD_HASH=$(md5sum "$0" 2>/dev/null || echo "")
                
                if git pull; then
                    NEW_HASH=$(md5sum "$0" 2>/dev/null || echo "")
                    if [ "$OLD_HASH" != "$NEW_HASH" ]; then
                        echo "⚠ manage.sh was updated. Self-restarting..."
                        sleep 1
                        exec "$0" "$@"
                    fi
                else
                    echo "Warning: git pull failed."
                fi
            fi
            
            echo "[2/4] Stopping service..."
            systemctl stop "$SERVICE_NAME" || true
            
            echo "[3/4] Updating files..."
            cp -r repeater "$INSTALL_DIR/"
            cp pyproject.toml "$INSTALL_DIR/"
            
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

    reset_repeater() {
        if ask_yes_no "Confirm Reset" "Restore default configuration?"; then
            systemctl stop "$SERVICE_NAME" || true
            cp "$CONFIG_DIR/config.yaml.example" "$CONFIG_DIR/config.yaml"
            systemctl start "$SERVICE_NAME"
            show_info "Reset" "Configuration restored to defaults."
        fi
    }

    uninstall_repeater() {
        if ask_yes_no "Confirm Uninstall" "Completely remove pyMC Repeater?"; then
            systemctl stop "$SERVICE_NAME" || true
            systemctl disable "$SERVICE_NAME" || true
            rm -rf "$INSTALL_DIR" "$CONFIG_DIR" "$LOG_DIR" /etc/systemd/system/pymc-repeater.service
            systemctl daemon-reload
            show_info "Uninstalled" "System cleaned."
        fi
    }

    show_detailed_status() {
        local ip_address=$(hostname -I | awk '{print $1}')
        local ver=$(get_version)
        local run=$(is_running && echo "Running ✓" || echo "Stopped ✗")
        show_info "System Status" "Version: $ver\nIP: $ip_address\nStatus: $run"
    }

    # --- Menu and Argument Setup ---

    # Setup DIALOG tool
    if command -v whiptail &> /dev/null; then DIALOG="whiptail"; else DIALOG="dialog"; fi

    show_main_menu() {
        CHOICE=$($DIALOG --backtitle "pyMC Repeater" --title "Management Menu" --menu "Action:" 18 70 10 \
            "install" "Install Repeater" \
            "upgrade" "Upgrade & Refresh Core" \
            "reset" "Reset Config to Default" \
            "uninstall" "Remove Everything" \
            "start" "Start Service" \
            "stop" "Stop Service" \
            "restart" "Restart Service" \
            "logs" "View Live Logs" \
            "status" "Detailed Status" \
            "exit" "Exit" 3>&1 1>&2 2>&3)
        
        case $CHOICE in
            install) install_repeater ; show_main_menu ;;
            upgrade) upgrade_repeater ; show_main_menu ;;
            reset)   reset_repeater   ; show_main_menu ;;
            uninstall) uninstall_repeater ;;
            start)   systemctl start "$SERVICE_NAME" ; show_main_menu ;;
            stop)    systemctl stop "$SERVICE_NAME" ; show_main_menu ;;
            restart) systemctl restart "$SERVICE_NAME" ; show_main_menu ;;
            logs)    clear ; journalctl -u "$SERVICE_NAME" -f ;;
            status)  show_detailed_status ; show_main_menu ;;
            exit|"") exit 0 ;;
        esac
    }

    if [ -z "$1" ]; then
        show_main_menu
    else
        case "$1" in
            install)   install_repeater ;;
            upgrade)   upgrade_repeater ;;
            reset)     reset_repeater ;;
            uninstall) uninstall_repeater ;;
            start|stop|restart) systemctl "$1" "$SERVICE_NAME" ;;
            status)    show_detailed_status ;;
            logs)      journalctl -u "$SERVICE_NAME" -f ;;
            *)         echo "Usage: $0 {install|upgrade|reset|uninstall|start|stop|restart|status|logs}" ; exit 1 ;;
        esac
    fi
}

# Load the entire script into memory and execute
main "$@"