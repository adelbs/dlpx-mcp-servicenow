#!/bin/bash
# Single entry point: interactive menu to install, check status, start,
# stop and update the Delphix <-> ServiceNow orchestrator on the remote
# server. Nothing to install — just bash + ssh/scp (already present on any
# macOS/Linux machine).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=deploy/lib/common.sh
source "$SCRIPT_DIR/deploy/lib/common.sh"
# shellcheck source=deploy/lib/ssh.sh
source "$SCRIPT_DIR/deploy/lib/ssh.sh"
# shellcheck source=deploy/lib/action_install.sh
source "$SCRIPT_DIR/deploy/lib/action_install.sh"
# shellcheck source=deploy/lib/action_status.sh
source "$SCRIPT_DIR/deploy/lib/action_status.sh"
# shellcheck source=deploy/lib/action_start_stop.sh
source "$SCRIPT_DIR/deploy/lib/action_start_stop.sh"
# shellcheck source=deploy/lib/action_update.sh
source "$SCRIPT_DIR/deploy/lib/action_update.sh"
# shellcheck source=deploy/lib/action_uninstall.sh
source "$SCRIPT_DIR/deploy/lib/action_uninstall.sh"

print_menu() {
    echo
    echo "=========================================="
    echo " Delphix <-> ServiceNow Orchestrator"
    echo "=========================================="
    echo "1) Install / reconfigure the server (from scratch)"
    echo "2) View service status"
    echo "3) Start service"
    echo "4) Stop service"
    echo "5) Update orchestrator (re-upload + restart)"
    echo "6) Uninstall (remove everything from the server)"
    echo "0) Exit"
    echo
}

run_choice() {
    case "$1" in
        1) action_install ;;
        2) action_status ;;
        3) action_start ;;
        4) action_stop ;;
        5) action_update ;;
        6) action_uninstall ;;
        0) exit 0 ;;
        *) log_warn "Invalid option." ;;
    esac
}

if [ "$#" -ge 1 ]; then
    # Optional non-interactive use: ./orchestrator.sh <1-6>
    run_choice "$1"
    exit 0
fi

while true; do
    print_menu
    read -r -p "Choose an option: " choice
    # In interactive menu mode, an error in one action (e.g. SSH failed,
    # missing conf) shouldn't take down the whole script — each action
    # already logs its own error; the user just sees the menu again to
    # retry.
    run_choice "$choice" || true
done
