#!/bin/bash
# "View service status" action. Sourced by orchestrator.sh.

action_status() {
    require_conf_for_ssh || return 1
    ssh_init

    log_info "Checking status on the server..."
    remote_sudo "/opt/dlpx-servicenow-orchestrator/bin/check_status.sh"

    if command -v curl >/dev/null 2>&1 && [ -n "${DOMAIN:-}" ]; then
        echo
        log_info "Checking public accessibility (HTTPS)..."
        # /servicenow-webhook only accepts POST, so a GET is expected to
        # reach the app and come back with 405 — that's success here (it
        # proves Nginx routes to this app), not an error. Anything else
        # (000, 404, 502...) means the route or the app isn't reachable.
        code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 "https://$DOMAIN/servicenow-webhook")
        if [ "$code" = "405" ]; then
            echo "OK: https://$DOMAIN/servicenow-webhook is routed to the app (405 Method Not Allowed on GET, as expected)."
        else
            log_warn "Unexpected response from https://$DOMAIN/servicenow-webhook: HTTP $code"
        fi
    fi
}
