#!/bin/bash
# Runs INSIDE the CentOS server (via ssh, as root/sudo), invoked by
# ./orchestrator.sh ("Install"). Idempotent: safe to run again any time.
#
# This project deliberately does NOT install nginx/certbot/firewalld/EPEL:
# they're already present and managed by dlpx-mcp-remote-server, which is
# expected to already be installed on this same host, and this project only
# ever reads/patches its existing Nginx vhost (see patch_shared_nginx.sh) —
# it never issues its own certificate or opens its own firewall rule.
set -euo pipefail

SERVICE_USER="svcnow-orch"
SERVICE_HOME="/opt/dlpx-servicenow-orchestrator"

log() { echo "[install_prereqs] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sudo)." >&2
    exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
    echo "nginx not found — this project expects dlpx-mcp-remote-server to already be" >&2
    echo "installed on this host (it owns the shared Nginx vhost this project patches)." >&2
    exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
    log "Installing uv (manages its own Python 3.11+ and virtualenvs)..."
    curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
else
    log "uv already installed: $(uv --version)"
fi

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    log "Creating service user '$SERVICE_USER'..."
    useradd --system --create-home --home-dir "$SERVICE_HOME" --shell /sbin/nologin "$SERVICE_USER"
else
    log "Service user '$SERVICE_USER' already exists."
fi

mkdir -p "$SERVICE_HOME" /etc/dlpx-servicenow-orchestrator
chown -R "$SERVICE_USER:$SERVICE_USER" "$SERVICE_HOME"
chmod 750 /etc/dlpx-servicenow-orchestrator

log "Prerequisites installed successfully."
