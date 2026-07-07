#!/bin/bash
# "Start service" and "Stop service" actions. Sourced by orchestrator.sh.

action_start() {
    require_conf_for_ssh || return 1
    ssh_init
    log_info "Starting the service..."
    remote_sudo "systemctl start dlpx-servicenow-orchestrator"
    log_info "Service started."
}

action_stop() {
    require_conf_for_ssh || return 1
    ssh_init
    log_info "Stopping the service..."
    remote_sudo "systemctl stop dlpx-servicenow-orchestrator"
    log_info "Service stopped."
}
