#!/bin/bash
# Runs INSIDE the CentOS server (via ssh, as root/sudo), invoked by
# ./orchestrator.sh ("Install"), right after install_prereqs.sh.
#
# Idempotent: safe to run again from scratch at any time.
#
# Expects to find, in STAGING_DIR (uploaded beforehand via scp by
# deploy/lib/action_install.sh):
#   - deploy_vars.env   (DOMAIN, ANTHROPIC_API_KEY, ANTHROPIC_MODEL,
#                         MCP_LOCAL_URL, SERVICENOW_*)
#   - app/              (application source code)
#   - pyproject.toml
#   - templates/        (systemd unit template)
#   - patch_shared_nginx.sh
set -euo pipefail

STAGING_DIR="${1:-/tmp/dlpx-svcnow-orch-deploy}"
SERVICE_USER="svcnow-orch"
SERVICE_HOME="/opt/dlpx-servicenow-orchestrator"
APP_DIR="$SERVICE_HOME/app"
ETC_DIR="/etc/dlpx-servicenow-orchestrator"

log() { echo "[configure_and_start] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sudo)." >&2
    exit 1
fi

if [ ! -f "$STAGING_DIR/deploy_vars.env" ]; then
    echo "Could not find $STAGING_DIR/deploy_vars.env — upload the files before running this script." >&2
    exit 1
fi

# shellcheck disable=SC1090
source "$STAGING_DIR/deploy_vars.env"

: "${DOMAIN:?DOMAIN not set in deploy_vars.env}"
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set in deploy_vars.env}"
: "${SERVICENOW_INSTANCE_URL:?SERVICENOW_INSTANCE_URL not set in deploy_vars.env}"
: "${SERVICENOW_USER:?SERVICENOW_USER not set in deploy_vars.env}"
: "${SERVICENOW_PASSWORD:?SERVICENOW_PASSWORD not set in deploy_vars.env}"
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-haiku-4-5-20251001}"
MCP_LOCAL_URL="${MCP_LOCAL_URL:-http://127.0.0.1:8930/sse}"

export PATH="/usr/local/bin:$PATH"

# -- 1. Application code: copy the uploaded source and sync dependencies ----

log "Installing application code into $APP_DIR..."
mkdir -p "$SERVICE_HOME"
rm -rf "${APP_DIR:?}" "$SERVICE_HOME/pyproject.toml" "$SERVICE_HOME/README.md"
mkdir -p "$APP_DIR"
cp -r "$STAGING_DIR/app/." "$APP_DIR/"
cp "$STAGING_DIR/pyproject.toml" "$SERVICE_HOME/pyproject.toml"
# pyproject.toml declares readme = "README.md" — hatchling needs it alongside
# to build the package (even for `uv sync`'s editable install).
cp "$STAGING_DIR/README.md" "$SERVICE_HOME/README.md"
chown -R "$SERVICE_USER:$SERVICE_USER" "$SERVICE_HOME"

log "Running 'uv sync'..."
sudo -u "$SERVICE_USER" -H bash -c "cd '$SERVICE_HOME' && /usr/local/bin/uv sync"

# -- 2. Environment file (secrets), 600 root:root ----------------------------

install -m 600 -o root -g root /dev/null "$ETC_DIR/orchestrator.env"
cat > "$ETC_DIR/orchestrator.env" <<EOF
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
ANTHROPIC_MODEL=${ANTHROPIC_MODEL}
MCP_LOCAL_URL=${MCP_LOCAL_URL}
SERVICENOW_INSTANCE_URL=${SERVICENOW_INSTANCE_URL}
SERVICENOW_USER=${SERVICENOW_USER}
SERVICENOW_PASSWORD=${SERVICENOW_PASSWORD}
EOF

# -- 3. Render the systemd unit ----------------------------------------------

render_template() {
    local src="$1" dst="$2"
    sed \
        -e "s#{{SERVICE_USER}}#${SERVICE_USER}#g" \
        -e "s#{{SERVICE_HOME}}#${SERVICE_HOME}#g" \
        -e "s#{{ETC_DIR}}#${ETC_DIR}#g" \
        "$src" > "$dst"
}

log "Rendering systemd unit..."
render_template "$STAGING_DIR/templates/dlpx-servicenow-orchestrator.service.tmpl" /etc/systemd/system/dlpx-servicenow-orchestrator.service

# -- 4. Application service ----------------------------------------------------

systemctl daemon-reload
systemctl enable --now dlpx-servicenow-orchestrator
# Pick up code/config changes on a re-install, not just a first start.
systemctl restart dlpx-servicenow-orchestrator

# -- 5. Patch the shared Nginx vhost (see patch_shared_nginx.sh for why) -----

log "Patching the shared Nginx vhost (dlpx-mcp-remote-server's) with the /servicenow-webhook route..."
"$STAGING_DIR/patch_shared_nginx.sh"

# -- 6. Install the status script at a permanent location (outside of
#       staging, which is removed next) for future "status" runs.

mkdir -p "$SERVICE_HOME/bin"
install -m 750 -o root -g root "$STAGING_DIR/check_status.sh" "$SERVICE_HOME/bin/check_status.sh"

# -- 7. Sanity check: is dlpx-mcp-remote-server's local mcp-proxy reachable? -

if systemctl is-active --quiet dlpx-dct-mcp-proxy; then
    log "dlpx-dct-mcp-proxy (dlpx-mcp-remote-server) is active on this host — good."
else
    log "WARNING: dlpx-dct-mcp-proxy is not active on this host. This orchestrator"
    log "needs dlpx-mcp-remote-server installed and running locally (127.0.0.1:8930)."
fi

# -- 8. Cleanup ---------------------------------------------------------------

rm -rf "$STAGING_DIR"

log "Installation complete."
echo "WEBHOOK_URL=https://${DOMAIN}/servicenow-webhook"
