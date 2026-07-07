#!/bin/bash
# Runs INSIDE the CentOS server (via ssh, as root/sudo) by
# ./orchestrator.sh ("View status"). Read-only — changes nothing.
set -uo pipefail

echo "=== Service ==="
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
echo "=== Dependency: dlpx-mcp-remote-server (local MCP wrapper) ==="
state=$(systemctl is-active dlpx-dct-mcp-proxy 2>/dev/null)
printf '%-30s active=%s\n' "dlpx-dct-mcp-proxy" "${state:-not installed}"

echo
echo "=== Shared Nginx vhost route (/servicenow-webhook) ==="
if grep -q "# BEGIN dlpx-servicenow-orchestrator" /etc/nginx/conf.d/dlpx-mcp.conf 2>/dev/null; then
    echo "Present in /etc/nginx/conf.d/dlpx-mcp.conf."
else
    echo "MISSING from /etc/nginx/conf.d/dlpx-mcp.conf — run this orchestrator's"
    echo "Install option again (it may have been wiped by a dlpx-mcp-remote-server reinstall)."
fi

echo
echo "=== Local app reachability ==="
code=$(curl -s -o /dev/null -w '%{http_code}' -m 5 http://127.0.0.1:8940/health 2>/dev/null || echo "000")
echo "GET http://127.0.0.1:8940/health -> $code"
