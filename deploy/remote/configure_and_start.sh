#!/bin/bash
# Runs INSIDE the server (CentOS/RHEL or Ubuntu/Debian, via ssh, as
# root/sudo), invoked by
# ./orchestrator.sh ("Install"), right after install_prereqs.sh.
#
# Idempotent: safe to run again from scratch at any time.
#
# Expects to find, in STAGING_DIR (uploaded beforehand via scp by
# deploy/lib/action_install.sh):
#   - deploy_vars.env   (DOMAIN, LETSENCRYPT_EMAIL, LLM_PROVIDER,
#                         ANTHROPIC_API_KEY, ANTHROPIC_MODEL, OLLAMA_MODEL,
#                         DCT_BASE_URL, DCT_API_KEY, SERVICENOW_*)
#   - app/              (application source code)
#   - pyproject.toml
#   - templates/        (systemd unit + Nginx vhost templates)
#   - setup_nginx.sh
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
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL not set in deploy_vars.env}"
: "${DCT_BASE_URL:?DCT_BASE_URL not set in deploy_vars.env}"
: "${DCT_API_KEY:?DCT_API_KEY not set in deploy_vars.env}"
: "${SERVICENOW_INSTANCE_URL:?SERVICENOW_INSTANCE_URL not set in deploy_vars.env}"
: "${SERVICENOW_USER:?SERVICENOW_USER not set in deploy_vars.env}"
: "${SERVICENOW_PASSWORD:?SERVICENOW_PASSWORD not set in deploy_vars.env}"
ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-claude-haiku-4-5-20251001}"
LLM_PROVIDER="${LLM_PROVIDER:-ollama}"
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.2:3b}"
OLLAMA_BASE_URL="http://127.0.0.1:11434"
if [ "$LLM_PROVIDER" = "anthropic" ]; then
    : "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set in deploy_vars.env (required when LLM_PROVIDER=anthropic)}"
fi

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

if [ "$LLM_PROVIDER" = "ollama" ]; then
    log "LLM_PROVIDER=ollama — pulling $OLLAMA_MODEL (this can take a while on first run)..."
    ollama pull "$OLLAMA_MODEL"
else
    log "LLM_PROVIDER=anthropic — skipping Ollama model pull (Ollama itself stays installed, idle)."
fi

# -- 2. Environment file (secrets), 600 root:root ----------------------------

install -m 600 -o root -g root /dev/null "$ETC_DIR/orchestrator.env"
cat > "$ETC_DIR/orchestrator.env" <<EOF
LLM_PROVIDER=${LLM_PROVIDER}
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
ANTHROPIC_MODEL=${ANTHROPIC_MODEL}
OLLAMA_BASE_URL=${OLLAMA_BASE_URL}
OLLAMA_MODEL=${OLLAMA_MODEL}
DCT_BASE_URL=${DCT_BASE_URL}
DCT_API_KEY=${DCT_API_KEY}
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

# -- 5. Own Nginx vhost + Let's Encrypt certificate (see setup_nginx.sh) ----

log "Setting up this project's own Nginx vhost and TLS certificate for $DOMAIN..."
"$STAGING_DIR/setup_nginx.sh" "$STAGING_DIR" "$DOMAIN" "$LETSENCRYPT_EMAIL"

# -- 6. Install the status script at a permanent location (outside of
#       staging, which is removed next) for future "status" runs.

mkdir -p "$SERVICE_HOME/bin"
install -m 750 -o root -g root "$STAGING_DIR/check_status.sh" "$SERVICE_HOME/bin/check_status.sh"

# -- 7. Sanity check: did the app (and its dct-mcp-server subprocess) start? -
# app/main.py's lifespan spawns dct-mcp-server and opens the MCP session at
# boot, failing fast if DCT_BASE_URL/DCT_API_KEY are wrong or the subprocess
# can't start — so a healthy /health response here is real signal, not just
# "uvicorn is up".

log "Checking that the app started successfully (via /health)..."
sleep 2
if curl -sf -m 5 http://127.0.0.1:8940/health >/dev/null; then
    log "App is up and healthy."
else
    log "WARNING: http://127.0.0.1:8940/health did not respond. Check 'journalctl -u"
    log "dlpx-servicenow-orchestrator' — a common cause is a bad DCT_BASE_URL/DCT_API_KEY,"
    log "which makes dct-mcp-server (and so the app) fail to start."
fi

# -- 8. Cleanup ---------------------------------------------------------------

rm -rf "$STAGING_DIR"

log "Installation complete."
echo "WEBHOOK_URL=https://${DOMAIN}/servicenow-webhook"
