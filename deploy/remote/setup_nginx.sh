#!/bin/bash
# Runs INSIDE the CentOS server (via ssh, as root/sudo), invoked by
# configure_and_start.sh.
#
# This project owns its own Nginx vhost and Let's Encrypt certificate for
# DOMAIN (no longer piggybacking on another project's shared vhost — see
# docs/architecture.md). Requires DOMAIN's DNS to already point at this
# server and ports 80/443 reachable from the internet (install_prereqs.sh
# opens them in firewalld; a cloud security group in front of this host is
# outside this script's control and must allow them too).
#
# Idempotent: the plain-HTTP template is re-rendered from scratch on every
# run, and `certbot --nginx` reinserts the SSL block, reusing/renewing the
# existing certificate under /etc/letsencrypt/live/$DOMAIN if one is already
# there rather than issuing a new one every time.
set -euo pipefail

STAGING_DIR="${1:?usage: setup_nginx.sh STAGING_DIR DOMAIN LETSENCRYPT_EMAIL}"
DOMAIN="${2:?usage: setup_nginx.sh STAGING_DIR DOMAIN LETSENCRYPT_EMAIL}"
LETSENCRYPT_EMAIL="${3:?usage: setup_nginx.sh STAGING_DIR DOMAIN LETSENCRYPT_EMAIL}"

VHOST_CONF="/etc/nginx/conf.d/dlpx-servicenow-orchestrator.conf"

log() { echo "[setup_nginx] $*"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must run as root (sudo)." >&2
    exit 1
fi

log "Rendering the Nginx vhost for $DOMAIN..."
sed -e "s#{{DOMAIN}}#${DOMAIN}#g" \
    "$STAGING_DIR/templates/nginx-dlpx-servicenow-orchestrator.conf.tmpl" > "$VHOST_CONF"

log "Validating and reloading Nginx..."
nginx -t
systemctl reload nginx

log "Requesting/renewing the Let's Encrypt certificate for $DOMAIN..."
certbot --nginx --non-interactive --agree-tos -m "$LETSENCRYPT_EMAIL" -d "$DOMAIN" --redirect

log "Nginx vhost and TLS certificate ready."
