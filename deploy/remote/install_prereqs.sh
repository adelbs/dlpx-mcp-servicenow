#!/bin/bash
# Runs INSIDE the server (via ssh, as root/sudo), invoked by
# ./orchestrator.sh ("Install"). Idempotent: safe to run again any time.
#
# Supports both RHEL-family (CentOS/RHEL/Fedora, yum/dnf) and Debian-family
# (Debian/Ubuntu, apt) hosts — see OS_FAMILY detection below. Everything past
# package installation (firewalld's own commands, systemd, useradd, uv,
# Ollama's official installer) is identical on both, so only the package
# list/manager differs.
#
# This project is fully self-contained: it installs and owns its own Nginx,
# Certbot/TLS certificate, firewall rules and (optionally used) local Ollama
# server — no dependency on dlpx-mcp-remote-server or any other project being
# present on the host — see docs/architecture.md. dxi-mcp-server itself isn't
# installed here: it's a project dependency in pyproject.toml, installed
# into the venv by `uv sync` in configure_and_start.sh.
set -euo pipefail

SERVICE_USER="svcnow-orch"
SERVICE_HOME="/opt/dlpx-servicenow-orchestrator"

log() { echo "[install_prereqs] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sudo)." >&2
    exit 1
fi

OS_FAMILY=""
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    case " ${ID:-} ${ID_LIKE:-} " in
        *" rhel "*|*" centos "*|*" fedora "*) OS_FAMILY="rhel" ;;
        *" debian "*|*" ubuntu "*) OS_FAMILY="debian" ;;
    esac
fi
if [ -z "$OS_FAMILY" ]; then
    # Fallback for minimal images without a usable /etc/os-release.
    if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        OS_FAMILY="rhel"
    elif command -v apt-get >/dev/null 2>&1; then
        OS_FAMILY="debian"
    fi
fi
if [ -z "$OS_FAMILY" ]; then
    echo "Unsupported OS: could not detect a yum/dnf (RHEL-family) or apt (Debian-family) system." >&2
    exit 1
fi
log "Detected OS family: $OS_FAMILY"

case "$OS_FAMILY" in
rhel)
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
    ;;
debian)
    log "Refreshing package cache (apt)..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y

    # No epel-release/policycoreutils-python-utils equivalent needed here:
    # these packages are already in Ubuntu/Debian's default repos, and
    # SELinux (what policycoreutils manages) isn't the default MAC on
    # Debian-family systems (AppArmor is, and needs no special handling for
    # a plain nginx/systemd setup like this one).
    log "Installing nginx, firewalld, certbot and supporting tools..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y nginx firewalld certbot python3-certbot-nginx openssl
    ;;
esac

# Ubuntu ships with ufw (usually inactive by default, but may have been
# enabled manually). This project manages the firewall via firewalld on
# every OS_FAMILY, to keep one set of commands — running both firewall
# managers at once fights over the same netfilter rules.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    log "ufw is active — disabling it in favor of firewalld (this project owns firewall config via firewalld on every supported OS)..."
    ufw disable
fi

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

# Always installed (cheap — idle Ollama is just its server process, no model
# loaded yet — see docs/architecture.md), regardless of LLM_PROVIDER, so
# switching from Anthropic to local inference later doesn't need a reinstall.
# configure_and_start.sh only pulls a model when LLM_PROVIDER=ollama.
if ! command -v ollama >/dev/null 2>&1; then
    log "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
else
    log "Ollama already installed: $(ollama --version 2>&1 | head -n1)"
fi

# This host has modest RAM (see docs/architecture.md) — cap Ollama to one
# loaded model / one in-flight request at a time (this app only ever issues
# one sequential call per incident, so there's no concurrency to gain from
# the defaults), and unload an idle model after 5 minutes so its RAM is
# freed between incidents rather than held indefinitely.
log "Configuring Ollama resource limits (OLLAMA_MAX_LOADED_MODELS, OLLAMA_NUM_PARALLEL, OLLAMA_KEEP_ALIVE)..."
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/resource-limits.conf <<'EOF'
[Service]
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_NUM_PARALLEL=1"
Environment="OLLAMA_KEEP_ALIVE=5m"
EOF
systemctl daemon-reload
systemctl enable --now ollama
systemctl restart ollama

if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    # `nologin` lives at /sbin/nologin on RHEL-family and /usr/sbin/nologin
    # on Debian-family (some Ubuntu releases symlink /sbin -> /usr/sbin, but
    # not all) — resolve it via PATH instead of hardcoding either.
    nologin_shell="$(command -v nologin || echo /usr/sbin/nologin)"
    log "Creating service user '$SERVICE_USER' (shell: $nologin_shell)..."
    useradd --system --create-home --home-dir "$SERVICE_HOME" --shell "$nologin_shell" "$SERVICE_USER"
else
    log "Service user '$SERVICE_USER' already exists."
fi

mkdir -p "$SERVICE_HOME" /etc/dlpx-servicenow-orchestrator
chown -R "$SERVICE_USER:$SERVICE_USER" "$SERVICE_HOME"
chmod 750 /etc/dlpx-servicenow-orchestrator

log "Prerequisites installed successfully."
