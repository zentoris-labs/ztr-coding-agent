#!/usr/bin/env bash
# Runs as PID 1 in the container. Sequence:
#   1. Generate SSH host keys if missing (persisted via the ssh-keys volume)
#   2. Export whitelisted env to /etc/environment so SSH sessions see it
#   3. Wire up git author identity + HTTPS credentials
#   4. Set SSH password (SSH_PASSWORD; required — sshd is tailnet-only,
#      and Claude Code Desktop can't use key auth cleanly per issue #25661)
#   5. In-container Docker daemon (on by default; AGENT_ENABLE_DOCKER=0 to skip; needs `privileged: true` AND a named volume on /var/lib/docker in compose)
#   6. Optional repo auto-clone (AGENT_REPOS)
#   7. Start tailscaled and join the tailnet (sshd is reachable only via the tailnet)
#   8. Start sshd in the foreground; container exits if either tailscaled or sshd dies
#
# Claude Code defaults (~/.claude/settings.json) are baked into the image —
# see config/claude/settings.json in the repo. The named volume on /home/agent
# preserves user edits across rebuilds.

set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# --- 1. SSH host keys (one-time generation, persisted in volume) ---
install -d -m 0755 /etc/ssh/keys
for type in ed25519 rsa ecdsa; do
    key="/etc/ssh/keys/ssh_host_${type}_key"
    if [[ ! -f "$key" ]]; then
        log "generating SSH host key ($type)"
        ssh-keygen -t "$type" -f "$key" -N "" -q < /dev/null
    fi
    chmod 600 "$key"
    chmod 644 "$key.pub"
done

# --- 2. Export whitelisted env to /etc/environment ---
# pam_env reads /etc/environment on login; sshd otherwise strips most container env.
{
    echo "# Managed by entrypoint.sh — do not edit"
    for var in AGENT_ID GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GITHUB_TOKEN ANTHROPIC_API_KEY; do
        val="${!var:-}"
        if [[ -n "$val" ]]; then
            printf '%s="%s"\n' "$var" "$val"
        fi
    done
} > /etc/environment
chmod 0644 /etc/environment

# --- 3. Git credentials + author identity (as `agent` user) ---
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    log "configuring git credentials for agent user"
    runuser -u agent -- bash -c '
        set -e
        umask 077
        printf "https://x-access-token:%s@github.com\n" "$GITHUB_TOKEN" \
            > "$HOME/.git-credentials"
        git config --global credential.helper store
    '
fi
if [[ -n "${GIT_AUTHOR_NAME:-}" ]]; then
    runuser -u agent -- git config --global user.name  "$GIT_AUTHOR_NAME"
fi
if [[ -n "${GIT_AUTHOR_EMAIL:-}" ]]; then
    runuser -u agent -- git config --global user.email "$GIT_AUTHOR_EMAIL"
fi
runuser -u agent -- git config --global --get init.defaultBranch >/dev/null 2>&1 \
    || runuser -u agent -- git config --global init.defaultBranch main
runuser -u agent -- git config --global --get pull.rebase >/dev/null 2>&1 \
    || runuser -u agent -- git config --global pull.rebase false

# --- 4. SSH password auth ---
# Tailnet-only sshd: Tailscale identity gates network reach; password gates
# shell. This is the ONLY supported SSH auth method — key auth was removed
# because Claude Code Desktop's SSH connector can't use keys cleanly
# (github.com/anthropics/claude-code/issues/25661). Fine because the network
# layer is already authenticated.
if [[ -z "${SSH_PASSWORD:-}" ]]; then
    log "ERROR: SSH_PASSWORD not set — agent would be unreachable. Set it in .env on the host."
    exit 1
fi
log "enabling SSH password auth"
echo "agent:${SSH_PASSWORD}" | chpasswd
sed -i 's/^PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config

# --- 5. In-container Docker daemon (on by default; set AGENT_ENABLE_DOCKER=0 to skip) ---
if [[ "${AGENT_ENABLE_DOCKER:-1}" != "0" ]]; then
    log "starting Docker daemon"
    nohup dockerd >/tmp/dockerd.log 2>&1 &
    DOCKERD_PID=$!
    for i in $(seq 1 30); do
        if [[ -S /var/run/docker.sock ]] && kill -0 "$DOCKERD_PID" 2>/dev/null; then
            chgrp docker /var/run/docker.sock 2>/dev/null || true
            chmod 0660 /var/run/docker.sock
            log "dockerd ready (pid $DOCKERD_PID)"
            break
        fi
        sleep 0.5
    done
    if ! kill -0 "$DOCKERD_PID" 2>/dev/null; then
        log "ERROR: dockerd exited during startup — container needs 'privileged: true' AND a named volume on /var/lib/docker in compose. See /tmp/dockerd.log."
    fi
fi

# --- 6. Optional repo auto-clone ---
if [[ -n "${AGENT_REPOS:-}" ]]; then
    log "auto-cloning configured repos"
    for repo in $AGENT_REPOS; do
        case "$repo" in
            *://*|git@*) url="$repo" ;;
            */*)         url="https://github.com/${repo}.git" ;;
            *) log "  skipping malformed entry: $repo"; continue ;;
        esac
        name="${repo##*/}"
        name="${name%.git}"
        dest="/home/agent/$name"
        if [[ -d "$dest/.git" ]]; then
            log "  $name: already present, skipping"
        else
            log "  $name: cloning from $url"
            runuser -u agent -- git clone --quiet "$url" "$dest" \
                && log "  $name: done" \
                || log "  $name: CLONE FAILED (check token scopes / repo URL)"
        fi
    done
fi

# --- 7. Tailscale (network overlay; no `--ssh` so plain sshd handles auth) ---
if [[ -z "${TS_AUTHKEY:-}" ]]; then
    log "ERROR: TS_AUTHKEY not set — agent has no inbound network. Set TS_AUTHKEY in .env on the host."
    exit 1
fi

log "starting tailscaled"
install -d -m 0700 /var/lib/tailscale /var/run/tailscale
nohup tailscaled \
    --tun=userspace-networking \
    --state=/var/lib/tailscale/tailscaled.state \
    --socket=/var/run/tailscale/tailscaled.sock \
    >/tmp/tailscaled.log 2>&1 &
TAILSCALED_PID=$!

for i in $(seq 1 30); do
    if [[ -S /var/run/tailscale/tailscaled.sock ]] && kill -0 "$TAILSCALED_PID" 2>/dev/null; then
        break
    fi
    sleep 0.5
done
if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
    log "ERROR: tailscaled exited during startup — see /tmp/tailscaled.log"
    exit 1
fi

TS_HOSTNAME="${TS_HOSTNAME:-agent-${AGENT_ID:-unset}}"
log "joining tailnet as $TS_HOSTNAME"
tailscale --socket=/var/run/tailscale/tailscaled.sock up \
    --authkey="$TS_AUTHKEY" \
    --hostname="$TS_HOSTNAME" \
    --accept-routes \
    || { log "ERROR: tailscale up failed"; exit 1; }

# --- 8. Start sshd. Container exits if either tailscaled or sshd dies. ---
log "ready (agent=${AGENT_ID:-unset}); tailnet=$TS_HOSTNAME"
log "starting sshd"
/usr/sbin/sshd -D -e &
SSHD_PID=$!

# Wait for either tailscaled or sshd to exit; restart policy handles recovery.
wait -n "$TAILSCALED_PID" "$SSHD_PID"
log "one of (tailscaled, sshd) exited — bringing container down for restart"
kill "$TAILSCALED_PID" "$SSHD_PID" 2>/dev/null || true
exit 1
