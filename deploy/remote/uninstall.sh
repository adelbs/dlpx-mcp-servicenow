#!/bin/bash
# Runs INSIDE the CentOS server (via ssh, as root/sudo), invoked by
# ./orchestrator.sh ("Uninstall").
#
# Removes everything install_prereqs.sh/configure_and_start.sh created
# specifically for this project: the systemd service, the application code,
# the environment file (secrets), the service user, and the
# /servicenow-webhook location block it added to dlpx-mcp-remote-server's
# shared Nginx vhost.
#
# Does NOT remove generic system packages (nginx, uv) or touch anything
# else in dlpx-mcp-remote-server's own vhost, service, code, or user.
# Idempotent: safe to run even if some of this is already gone.
set -uo pipefail

SERVICE_USER="svcnow-orch"
SERVICE_HOME="/opt/dlpx-servicenow-orchestrator"
ETC_DIR="/etc/dlpx-servicenow-orchestrator"
MCP_CONF="/etc/nginx/conf.d/dlpx-mcp.conf"

log() { echo "[uninstall] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sudo)." >&2
    exit 1
fi

log "Stopping and disabling the service..."
systemctl disable --now dlpx-servicenow-orchestrator >/dev/null 2>&1 || true

log "Removing the systemd unit..."
rm -f /etc/systemd/system/dlpx-servicenow-orchestrator.service
systemctl daemon-reload

log "Removing the /servicenow-webhook route from the shared Nginx vhost..."
if [ -f "$MCP_CONF" ] && grep -q "# BEGIN dlpx-servicenow-orchestrator" "$MCP_CONF"; then
    sed -i "/# BEGIN dlpx-servicenow-orchestrator/,/# END dlpx-servicenow-orchestrator/d" "$MCP_CONF"
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    else
        log "WARNING: 'nginx -t' failed after removing the route — check $MCP_CONF manually."
    fi
fi

log "Removing application code and configuration..."
rm -rf "$SERVICE_HOME" "$ETC_DIR"

if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log "Removing service user '$SERVICE_USER'..."
    userdel -f "$SERVICE_USER" >/dev/null 2>&1 || log "WARNING: could not remove user '$SERVICE_USER' automatically."
fi

log "Uninstall complete."
echo "nginx, uv, and dlpx-mcp-remote-server (including its own vhost/certificate) were NOT touched."
