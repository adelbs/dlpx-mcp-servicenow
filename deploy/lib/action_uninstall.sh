#!/bin/bash
# "Uninstall (remove everything from the server)" action. Sourced by orchestrator.sh.

action_uninstall() {
    require_conf_for_ssh || return 1

    echo
    log_warn "This will STOP and REMOVE the service, the code, and the environment"
    log_warn "file (secrets) on server $SSH_HOST."
    log_warn "System packages (nginx, certbot, uv, etc.) and the issued TLS"
    log_warn "certificate are NOT removed. dlpx-mcp-remote-server (the MCP wrapper)"
    log_warn "running on the same server is NOT affected."
    read -r -p "Type 'uninstall' to confirm: " confirm
    if [ "$confirm" != "uninstall" ]; then
        log_info "Cancelled — nothing was changed."
        return 0
    fi

    ssh_init

    log_info "Uploading uninstall script..."
    remote_run "mkdir -p /tmp/dlpx-svcnow-orch-uninstall"
    upload_file "$REPO_ROOT/deploy/remote/uninstall.sh" "/tmp/dlpx-svcnow-orch-uninstall/uninstall.sh"

    log_info "Removing service, code and data on the server..."
    remote_sudo "chmod +x /tmp/dlpx-svcnow-orch-uninstall/uninstall.sh && /tmp/dlpx-svcnow-orch-uninstall/uninstall.sh"
    remote_run "rm -rf /tmp/dlpx-svcnow-orch-uninstall"

    log_info "Uninstall complete."
}
