#!/bin/bash
# "Update orchestrator (re-upload + restart)" action. Sourced by orchestrator.sh.
#
# Unlike dxi-mcp-server (an external upstream project, git-cloned on the
# server), this project's own code has no independent git checkout living on
# the server — it's uploaded via scp on every install/update, same as
# dlpx-mcp-remote-server treats its own custom gateway/ code. So "update"
# here means: re-upload the current local working tree, resync dependencies,
# restart.

action_update() {
    require_conf_for_ssh || return 1
    ssh_init

    log_info "Re-uploading app/, pyproject.toml and README.md to the server..."
    remote_run "rm -rf /tmp/dlpx-svcnow-orch-update && mkdir -p /tmp/dlpx-svcnow-orch-update"
    upload_dir "$REPO_ROOT/app" "/tmp/dlpx-svcnow-orch-update"
    upload_file "$REPO_ROOT/pyproject.toml" "/tmp/dlpx-svcnow-orch-update/pyproject.toml"
    # pyproject.toml declares readme = "README.md" — hatchling needs it
    # alongside to build the package (even for `uv sync`'s editable install).
    upload_file "$REPO_ROOT/README.md" "/tmp/dlpx-svcnow-orch-update/README.md"

    log_info "Syncing files into place and reinstalling dependencies..."
    remote_sudo "rm -rf /opt/dlpx-servicenow-orchestrator/app /opt/dlpx-servicenow-orchestrator/pyproject.toml /opt/dlpx-servicenow-orchestrator/README.md && \
        cp -r /tmp/dlpx-svcnow-orch-update/app /opt/dlpx-servicenow-orchestrator/app && \
        cp /tmp/dlpx-svcnow-orch-update/pyproject.toml /opt/dlpx-servicenow-orchestrator/pyproject.toml && \
        cp /tmp/dlpx-svcnow-orch-update/README.md /opt/dlpx-servicenow-orchestrator/README.md && \
        chown -R svcnow-orch:svcnow-orch /opt/dlpx-servicenow-orchestrator && \
        sudo -u svcnow-orch -H bash -c 'cd /opt/dlpx-servicenow-orchestrator && /usr/local/bin/uv sync'"
    remote_run "rm -rf /tmp/dlpx-svcnow-orch-update"

    log_info "Restarting the service..."
    remote_sudo "systemctl restart dlpx-servicenow-orchestrator"

    log_info "Update complete."
}
