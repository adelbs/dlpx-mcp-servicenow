#!/bin/bash
# Runs INSIDE the CentOS server (via ssh, as root/sudo), invoked by
# ./orchestrator.sh ("Uninstall").
#
# Removes everything install_prereqs.sh/configure_and_start.sh created
# specifically for this project: the systemd service, the application code,
# the environment file (secrets), the service user, and this project's own
# Nginx vhost.
#
# Does NOT remove generic system packages (nginx, certbot, firewalld, uv,
# ollama) or the issued TLS certificate under /etc/letsencrypt — those may be
# reused by a future reinstall, and removing a Let's Encrypt certificate is
# easy to get wrong (rate limits on reissuing). Idempotent: safe to run even
# if some of this is already gone.
set -uo pipefail

SERVICE_USER="svcnow-orch"
SERVICE_HOME="/opt/dlpx-servicenow-orchestrator"
ETC_DIR="/etc/dlpx-servicenow-orchestrator"
VHOST_CONF="/etc/nginx/conf.d/dlpx-servicenow-orchestrator.conf"

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

log "Removing this project's Nginx vhost..."
if [ -f "$VHOST_CONF" ]; then
    rm -f "$VHOST_CONF"
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    else
        log "WARNING: 'nginx -t' failed after removing $VHOST_CONF — check the Nginx config manually."
    fi
fi

log "Removing application code and configuration..."
rm -rf "$SERVICE_HOME" "$ETC_DIR"

if id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log "Removing service user '$SERVICE_USER'..."
    userdel -f "$SERVICE_USER" >/dev/null 2>&1 || log "WARNING: could not remove user '$SERVICE_USER' automatically."
fi

log "Uninstall complete."
echo "nginx, certbot, firewalld, uv, ollama (including any pulled models), and the TLS certificate"
echo "under /etc/letsencrypt were NOT touched."
