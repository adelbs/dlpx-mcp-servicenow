#!/bin/bash
# "Install / reconfigure the server (from scratch)" action.
# Sourced by orchestrator.sh — not meant to be executed directly.

action_install() {
    ensure_conf
    if [ -z "${SSH_HOST:-}" ] || [ -z "${DOMAIN:-}" ]; then
        log_error "SSH_HOST and DOMAIN must be set in deploy/deploy.conf."
        return 1
    fi

    ssh_init

    log_info "Preparing staging directory on the server..."
    remote_run "rm -rf /tmp/dlpx-svcnow-orch-deploy && mkdir -p /tmp/dlpx-svcnow-orch-deploy"

    log_info "Uploading app/, remote scripts, templates and project metadata..."
    upload_dir "$REPO_ROOT/app" "/tmp/dlpx-svcnow-orch-deploy"
    upload_file "$REPO_ROOT/pyproject.toml" "/tmp/dlpx-svcnow-orch-deploy/pyproject.toml"
    # pyproject.toml declares readme = "README.md" — hatchling refuses to
    # build the package (even for `uv sync`'s editable install) without it.
    upload_file "$REPO_ROOT/README.md" "/tmp/dlpx-svcnow-orch-deploy/README.md"
    for f in "$REPO_ROOT"/deploy/remote/*.sh; do
        upload_file "$f" "/tmp/dlpx-svcnow-orch-deploy/$(basename "$f")"
    done
    upload_dir "$REPO_ROOT/deploy/templates" "/tmp/dlpx-svcnow-orch-deploy"

    local vars_file
    vars_file="$(mktemp)"
    chmod 600 "$vars_file"
    # %q shell-escapes each value (quotes, $, backticks, etc.) so that
    # configure_and_start.sh's `source deploy_vars.env` on the server gets
    # back the exact original string — a secret that happens to contain a
    # literal "$" (e.g. "...UN$a?Hh...") would otherwise be misread as a
    # variable expansion when re-sourced, corrupting the value (or, under
    # `set -u`, aborting with "unbound variable").
    {
        printf 'DOMAIN=%q\n' "$DOMAIN"
        printf 'ANTHROPIC_API_KEY=%q\n' "$ANTHROPIC_API_KEY"
        printf 'ANTHROPIC_MODEL=%q\n' "$ANTHROPIC_MODEL"
        printf 'MCP_LOCAL_URL=%q\n' "$MCP_LOCAL_URL"
        printf 'SERVICENOW_INSTANCE_URL=%q\n' "$SERVICENOW_INSTANCE_URL"
        printf 'SERVICENOW_USER=%q\n' "$SERVICENOW_USER"
        printf 'SERVICENOW_PASSWORD=%q\n' "$SERVICENOW_PASSWORD"
    } > "$vars_file"
    upload_file "$vars_file" "/tmp/dlpx-svcnow-orch-deploy/deploy_vars.env"
    rm -f "$vars_file"

    log_info "Installing prerequisites on the server (this may take a few minutes)..."
    remote_sudo "chmod +x /tmp/dlpx-svcnow-orch-deploy/*.sh && /tmp/dlpx-svcnow-orch-deploy/install_prereqs.sh"

    log_info "Configuring and starting the service (uv sync, systemd, shared nginx route)..."
    remote_sudo "/tmp/dlpx-svcnow-orch-deploy/configure_and_start.sh /tmp/dlpx-svcnow-orch-deploy"

    echo
    log_info "Installation complete. Update the 'delphix.orchestrator_webhook_url' system"
    log_info "property in ServiceNow with:"
    echo "  https://$DOMAIN/servicenow-webhook"
}
