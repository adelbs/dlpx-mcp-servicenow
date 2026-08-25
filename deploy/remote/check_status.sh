#!/bin/bash
# Runs INSIDE the CentOS server (via ssh, as root/sudo) by
# ./orchestrator.sh ("View status"). Read-only — changes nothing.
set -uo pipefail

echo "=== Services ==="
for svc in dlpx-servicenow-orchestrator nginx; do
    # `systemctl is-active`/`is-enabled` always print a state to stdout
    # (active, inactive, failed, disabled, ...) even when they exit non-zero
    # (e.g. a stopped service returns exit != 0, which isn't a command
    # failure) — so we do NOT use `|| echo "unknown"` here, which would
    # concatenate both outputs when the service was merely stopped.
    state=$(systemctl is-active "$svc" 2>/dev/null)
    enabled=$(systemctl is-enabled "$svc" 2>/dev/null)
    printf '%-30s active=%-12s enabled=%s\n' "$svc" "${state:-unknown}" "${enabled:-unknown}"
done

echo
echo "=== Nginx vhost ==="
if [ -f /etc/nginx/conf.d/dlpx-servicenow-orchestrator.conf ]; then
    echo "Present: /etc/nginx/conf.d/dlpx-servicenow-orchestrator.conf"
else
    echo "MISSING: /etc/nginx/conf.d/dlpx-servicenow-orchestrator.conf — run the Install option."
fi

echo
echo "=== TLS certificate ==="
cert_dir=$(find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d -name '*' 2>/dev/null | head -n1)
if [ -n "$cert_dir" ] && [ -f "$cert_dir/fullchain.pem" ]; then
    expiry=$(openssl x509 -enddate -noout -in "$cert_dir/fullchain.pem" 2>/dev/null | cut -d= -f2)
    echo "Present: $cert_dir (expires: ${expiry:-unknown})"
else
    echo "No certificate found under /etc/letsencrypt/live — run the Install option."
fi

echo
echo "=== dxi-mcp-server (dct-mcp-server, spawned directly by the app) ==="
if [ -x /opt/dlpx-servicenow-orchestrator/.venv/bin/dct-mcp-server ]; then
    echo "Installed: /opt/dlpx-servicenow-orchestrator/.venv/bin/dct-mcp-server"
else
    echo "MISSING — run 'uv sync' (Install or Update) to install it as a project dependency."
fi

echo
echo "=== Local app reachability ==="
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:8940/health 2>/dev/null || echo "000")
echo "GET http://127.0.0.1:8940/health -> $code"
