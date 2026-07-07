#!/bin/bash
# Multiplexed SSH session (ControlMaster): the password/key is only asked
# when there isn't already a valid master connection to this server. Sourced
# by orchestrator.sh — not meant to be executed directly.
#
# On purpose, this script NEVER closes the master connection at the end of
# execution (there's no `ssh -O exit` anywhere): it stays alive in the
# background, outside of orchestrator.sh's own process, for as long as
# ControlPersist defines. That's what makes the password only get asked
# "for real" once — even across separate invocations of ./orchestrator.sh
# (e.g. installing and, minutes later, checking status) — not just within a
# single run of the menu. After ControlPersist elapses unused, ssh closes
# the connection on its own.

SSH_OPTS=()
SSH_CONTROL_PATH=""

ssh_init() {
    # The control socket must live under /tmp — literally "/tmp", not
    # "$TMPDIR" — and not under the repository directory: Unix sockets have
    # a ~104 byte path limit, and on macOS "$TMPDIR" is already a long,
    # process-specific path (e.g. /var/folders/.../T/) that blows past that
    # limit even with a short file name. `%C` (hash of local host + remote
    # host + port + user) keeps the name always short and still unique per
    # server — and is also what lets future invocations of ./orchestrator.sh
    # against the same server reuse the same master connection. The
    # "dlpx-svcnow-orch-" prefix keeps this project's sockets independent
    # from dlpx-mcp-remote-server's own SSH multiplexing, even when both
    # target the same server.
    SSH_CONTROL_PATH="/tmp/dlpx-svcnow-orch-ssh-%C"
    SSH_OPTS=(
        -o "ControlMaster=auto"
        -o "ControlPath=$SSH_CONTROL_PATH"
        -o "ControlPersist=1h"
        -p "${SSH_PORT:-22}"
    )
    # Opens (or reuses, if one already exists) the master connection now —
    # this is where the password/key is asked, if needed.
    #
    # Some networks/VMs reset the connection sporadically during the SSH
    # handshake itself (kex_exchange_identification: Connection reset),
    # unrelated to wrong credentials. Retry a few times before giving up,
    # instead of failing the whole install over a transient network blip.
    local attempt
    for attempt in 1 2 3; do
        if ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" true; then
            return 0
        fi
        if [ "$attempt" -lt 3 ]; then
            log_warn "Failed to connect via SSH (attempt $attempt/3) — retrying in a few seconds..."
            sleep 3
        fi
    done
    log_error "Could not establish SSH connection to $SSH_USER@$SSH_HOST after 3 attempts."
    return 1
}

# Runs a remote command (no elevated privilege) through the SSH user's
# default shell. Accepts the command as a single string (can contain &&, |, etc.).
remote_run() {
    local cmd="$*"
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "$cmd"
}

# Runs a remote command as root. If the SSH user is already root, run it
# directly (avoids depending on the `sudo` package being installed);
# otherwise use `sudo` with a pseudo-tty (to allow a sudo password prompt,
# if any).
remote_sudo() {
    local cmd="$*"
    # `printf '%q'` produces a shell-safe quoted representation of the
    # command. It's more robust than manually escaping single quotes, which
    # breaks as soon as the command itself already contains quotes (e.g. an
    # argument like '$DOMAIN').
    local quoted
    quoted=$(printf '%q' "$cmd")
    if [ "$SSH_USER" = "root" ]; then
        ssh "${SSH_OPTS[@]}" "$SSH_USER@$SSH_HOST" "bash -c $quoted"
    else
        ssh "${SSH_OPTS[@]}" -t "$SSH_USER@$SSH_HOST" "sudo bash -c $quoted"
    fi
}

# Uploads an entire local directory into an existing remote parent directory
# (scp -r always nests by base name, so the result lands at
# "$remote_parent_dir/$(basename local_dir)").
upload_dir() {
    local local_dir="$1" remote_parent_dir="$2"
    scp -o "ControlPath=$SSH_CONTROL_PATH" -P "${SSH_PORT:-22}" -r \
        "$local_dir" "$SSH_USER@$SSH_HOST:$remote_parent_dir/"
}

# Uploads a single local file to an exact remote path.
upload_file() {
    local local_file="$1" remote_path="$2"
    scp -o "ControlPath=$SSH_CONTROL_PATH" -P "${SSH_PORT:-22}" \
        "$local_file" "$SSH_USER@$SSH_HOST:$remote_path"
}
