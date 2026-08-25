#!/bin/bash
# Runs INSIDE the CentOS server (via ssh, as root/sudo), invoked by
# ./orchestrator.sh ("Install"). Idempotent: safe to run again any time.
#
# This project is fully self-contained: it installs and owns its own Nginx,
# Certbot/TLS certificate and firewall rules (no dependency on
# dlpx-mcp-remote-server or any other project being present on the host —
# see docs/architecture.md). dxi-mcp-server itself isn't installed here: it's
# a project dependency in pyproject.toml, installed into the venv by `uv
# sync` in configure_and_start.sh.
set -euo pipefail

SERVICE_USER="svcnow-orch"
SERVICE_HOME="/opt/dlpx-servicenow-orchestrator"

log() { echo "[install_prereqs] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sudo)." >&2
    exit 1
fi

PKG="yum"
command -v dnf >/dev/null 2>&1 && PKG="dnf"

log "Refreshing package cache ($PKG)..."
$PKG makecache -y

if ! rpm -q epel-release >/dev/null 2>&1; then
    log "Installing epel-release (needed for certbot on CentOS/RHEL)..."
    $PKG install -y epel-release
else
    log "epel-release already installed."
fi

log "Installing nginx, firewalld, certbot and supporting tools..."
$PKG install -y nginx firewalld certbot python3-certbot-nginx policycoreutils-python-utils openssl

log "Enabling and starting firewalld, opening HTTP/HTTPS..."
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --reload

log "Enabling and starting nginx..."
systemctl enable --now nginx

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
