#!/bin/bash
# "Send a test provision/teardown webhook" actions. Sourced by orchestrator.sh.
#
# Emulates exactly what ServiceNow's two Business Rules POST (see
# docs/servicenow_runbook_rebuild_from_scratch.md's "Delphix - Provisionar
# VDB" / "Delphix - Destruir VDB" sections — same JSON shape, same field
# names) against this orchestrator's real public HTTPS endpoint. Useful to
# validate the whole pipeline (LLM extraction -> Delphix provisioning/
# teardown) end to end before pointing ServiceNow's own
# `delphix.orchestrator_webhook_url` system property at this server.
#
# No SSH involved: this is a plain HTTPS POST from this machine, exactly
# like ServiceNow's PDI would make.
#
# NOT a dry run: it really provisions/deletes a VDB in Delphix. The default
# sys_id is the same fake one used in tests/sample_*.json — Delphix
# provisioning/teardown works fine against it, but the final ServiceNow
# Table API PATCH (updating work_notes/state) will 404, since that sys_id
# doesn't exist on a real instance. That's expected here; pass a real
# incident's sys_id (create one manually in ServiceNow, leave it at New) if
# you also want that last step validated.

_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

_send_test_webhook() {
    local action="$1"
    require_conf_for_ssh || return 1

    local incident_number sys_id opened_at raw_short_description raw_description short_description description payload

    incident_number=$(prompt_default "Incident number (use the SAME number for both the provision and the teardown call, so teardown finds the VDB by its incident:<number> tag)" "INC0009009")
    sys_id=$(prompt_default "sys_id (fake by default — the ServiceNow PATCH step will 404 unless this is a real incident's sys_id; harmless either way)" "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4")
    # Free text, exactly as an analyst would type it into ServiceNow — this
    # is what incident_agent.py hands to the LLM to extract the affected
    # app + timestamp, so typing a real/varied incident here is how you
    # actually test the LLM's interpretation, not just the Delphix plumbing.
    raw_short_description=$(prompt_default "Incident short_description (free text — this is what the LLM reads to identify the affected app + timestamp)" "CRM erroring out for all users since this morning")
    raw_description=$(prompt_default "Incident description (optional, more detail — leave blank to skip)" "")
    opened_at=$(date -u +"%Y-%m-%d %H:%M:%S")

    short_description="$(_json_escape "$raw_short_description")"
    description="$(_json_escape "$raw_description")"

    payload=$(printf '{"action":"%s","sys_id":"%s","number":"%s","short_description":"%s","description":"%s","opened_at":"%s"}' \
        "$(_json_escape "$action")" "$(_json_escape "$sys_id")" "$(_json_escape "$incident_number")" \
        "$short_description" "$description" "$(_json_escape "$opened_at")")

    echo
    log_info "Payload:"
    echo "$payload"
    echo
    log_info "POSTing to https://$DOMAIN/servicenow-webhook ..."
    curl -sS -w '\n\nHTTP %{http_code}\n' -X POST "https://$DOMAIN/servicenow-webhook" \
        -H "Content-Type: application/json" \
        -d "$payload"
    echo
    log_info "Follow along on the server with: sudo journalctl -u dlpx-servicenow-orchestrator -f"
}

action_test_webhook_provision() {
    log_warn "This really provisions a VDB in Delphix (tagged incident:<number>) — it is NOT a dry run."
    _send_test_webhook "provision"
}

action_test_webhook_teardown() {
    log_warn "This really looks up and deletes the VDB tagged incident:<number> in Delphix — it is NOT a dry run."
    _send_test_webhook "teardown"
}
