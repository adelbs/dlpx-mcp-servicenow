#!/bin/bash
# Shared helpers: locate directories, logging, load/create deploy.conf.
# Sourced by orchestrator.sh — not meant to be executed directly.

DEPLOY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "$DEPLOY_LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEPLOY_DIR/.." && pwd)"
DEPLOY_CONF="$DEPLOY_DIR/deploy.conf"

log_info()  { printf '\033[1;34m[info]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; }

conf_exists() { [ -f "$DEPLOY_CONF" ]; }

load_conf() {
    # shellcheck disable=SC1090
    source "$DEPLOY_CONF"
}

prompt_default() {
    # prompt_default "Message" "default_value" -> prints result to stdout
    local message="$1" default="${2:-}" answer
    if [ -n "$default" ]; then
        read -r -p "$message [$default]: " answer
        echo "${answer:-$default}"
    else
        read -r -p "$message: " answer
        echo "$answer"
    fi
}

prompt_secret() {
    local message="$1" answer
    read -r -s -p "$message: " answer
    echo >&2
    echo "$answer"
}

# Interactively asks for everything missing to install from scratch and
# saves it to deploy/deploy.conf (gitignored, 600) so it isn't asked again.
ensure_conf() {
    if conf_exists; then
        load_conf
        return 0
    fi

    log_warn "deploy/deploy.conf not found — let's create it now (only asked once)."
    local ssh_host ssh_user ssh_port domain letsencrypt_email
    local anthropic_api_key anthropic_model dct_base_url dct_api_key
    local servicenow_instance_url servicenow_user servicenow_password

    ssh_host=$(prompt_default "CentOS server host/IP" "")
    ssh_user=$(prompt_default "SSH user" "root")
    ssh_port=$(prompt_default "SSH port" "22")
    domain=$(prompt_default "Public hostname for this orchestrator's own Nginx vhost/TLS certificate (must already have a DNS A/AAAA record pointing at this server)" "$ssh_host")
    letsencrypt_email=$(prompt_default "Email for Let's Encrypt (certificate expiry notices)" "")
    anthropic_api_key=$(prompt_secret "ANTHROPIC_API_KEY")
    anthropic_model=$(prompt_default "ANTHROPIC_MODEL" "claude-haiku-4-5-20251001")
    dct_base_url=$(prompt_default "DCT_BASE_URL (Delphix DCT instance URL, no trailing /dct)" "")
    dct_api_key=$(prompt_secret "DCT_API_KEY (same credential dxi-mcp-server uses to call DCT)")
    servicenow_instance_url=$(prompt_default "SERVICENOW_INSTANCE_URL" "")
    servicenow_user=$(prompt_default "SERVICENOW_USER" "delphix.orchestrator")
    servicenow_password=$(prompt_secret "SERVICENOW_PASSWORD")

    cat > "$DEPLOY_CONF" <<EOF
SSH_HOST="$ssh_host"
SSH_USER="$ssh_user"
SSH_PORT="$ssh_port"
DOMAIN="$domain"
LETSENCRYPT_EMAIL="$letsencrypt_email"
ANTHROPIC_API_KEY="$anthropic_api_key"
ANTHROPIC_MODEL="$anthropic_model"
DCT_BASE_URL="$dct_base_url"
DCT_API_KEY="$dct_api_key"
SERVICENOW_INSTANCE_URL="$servicenow_instance_url"
SERVICENOW_USER="$servicenow_user"
SERVICENOW_PASSWORD="$servicenow_password"
EOF
    chmod 600 "$DEPLOY_CONF"
    log_info "Configuration saved to deploy/deploy.conf (not committed to git)."
    load_conf
}

# Used by actions that only need host/user (status/start/stop/update):
# requires a configuration to already exist, without offering to create one.
require_conf_for_ssh() {
    if ! conf_exists; then
        log_error "No configuration found at deploy/deploy.conf. Run the 'Install' option first."
        return 1
    fi
    load_conf
}
