#!/usr/bin/env bash
# Bootstrap a Ubuntu 24.04 host as a ztr-coding-agent VM.
#
# Idempotent — safe to re-run. Installs Docker CE + Compose, sysbox-ce
# (pinned), registers sysbox-runc as a Docker runtime, installs Tailscale,
# and pre-pulls the GHCR image. Optionally joins the host to your tailnet
# with Tailscale SSH enabled (set HOST_TS_AUTHKEY before invoking).
#
# Usage (recommended — SSH in first, then run on the host):
#   ssh root@<host>
#   # then on the host:
#   curl -fsSL https://raw.githubusercontent.com/zentoris-labs/ztr-coding-agent/main/infra/bootstrap.sh | bash
#   # → script prompts (silently) for the Tailscale auth key. Paste it.
#
# Non-interactive (CI / scripted): pre-set HOST_TS_AUTHKEY env before running.

set -euo pipefail

log() { printf '[bootstrap] %s\n' "$*" >&2; }

SYSBOX_VERSION="${SYSBOX_VERSION:-0.6.7}"
WORKDIR="${WORKDIR:-/opt/ztr-coding-agent}"
IMAGE="${IMAGE:-ghcr.io/zentoris-labs/ztr-coding-agent:latest}"

if [[ $EUID -ne 0 ]]; then
    log "ERROR: must run as root (try: sudo bash $0)"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# --- 1. Base packages ---
log "apt update"
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg git jq vim tmux htop

# --- 2. Docker CE (skip if already installed) ---
if ! command -v docker >/dev/null 2>&1; then
    log "installing Docker CE + Compose"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    . /etc/os-release
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
else
    log "docker already installed ($(docker --version))"
fi

# --- 3. sysbox-ce (skip if already installed) ---
if ! command -v sysbox-runc >/dev/null 2>&1; then
    log "installing sysbox-ce ${SYSBOX_VERSION}"
    cd /tmp
    curl -fsSL -o sysbox-ce.deb \
        "https://downloads.nestybox.com/sysbox/releases/v${SYSBOX_VERSION}/sysbox-ce_${SYSBOX_VERSION}-0.linux_amd64.deb"
    apt-get install -y ./sysbox-ce.deb
    rm -f sysbox-ce.deb
else
    log "sysbox-ce already installed"
fi

# --- 4. Register sysbox-runc with Docker daemon ---
DAEMON_JSON=/etc/docker/daemon.json
if [[ -f "$DAEMON_JSON" ]] && grep -q sysbox-runc "$DAEMON_JSON"; then
    log "daemon.json already registers sysbox-runc"
else
    log "writing daemon.json + restarting docker"
    install -d -m 0755 /etc/docker
    cat > "$DAEMON_JSON" <<'EOF'
{
  "runtimes": {
    "sysbox-runc": {
      "path": "/usr/bin/sysbox-runc"
    }
  }
}
EOF
    systemctl restart docker
fi

# --- 5. Tailscale (system service on the host) ---
if ! command -v tailscale >/dev/null 2>&1; then
    log "installing Tailscale"
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
        > /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
        > /etc/apt/sources.list.d/tailscale.list
    apt-get update -qq
    apt-get install -y --no-install-recommends tailscale
else
    log "tailscale already installed"
fi
systemctl enable --now tailscaled >/dev/null

# Join the tailnet. Prefer HOST_TS_AUTHKEY env (for non-interactive runs);
# otherwise prompt silently via /dev/tty so the key never lands in env,
# shell history, or files.
if tailscale status --json 2>/dev/null | grep -q '"BackendState":"Running"' ; then
    log "tailscale already up; skipping join"
else
    if [[ -z "${HOST_TS_AUTHKEY:-}" && -r /dev/tty ]]; then
        printf '[bootstrap] paste Tailscale auth key (tag:agent-host, hidden): ' >&2
        IFS= read -rs HOST_TS_AUTHKEY < /dev/tty
        echo >&2
    fi
    if [[ -n "${HOST_TS_AUTHKEY:-}" ]]; then
        log "joining tailnet (Tailscale SSH enabled)"
        tailscale up --auth-key="$HOST_TS_AUTHKEY" --ssh --accept-routes
        unset HOST_TS_AUTHKEY
    else
        log "no auth key provided — tailscale installed but not joined."
        log "  to join later: tailscale up --ssh"
    fi
fi

# --- 6. Working directory + repo files (compose template + .env.example) ---
# Pulls the latest docker-compose.yml and .env.example from the public repo
# so the operator doesn't have to scp them. Existing files are NOT overwritten
# (so re-running bootstrap won't clobber a customized compose).
install -d -m 0755 "${WORKDIR}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/zentoris-labs/ztr-coding-agent/main}"
for f in docker-compose.yml .env.example; do
    target="${WORKDIR}/${f}"
    if [[ -f "$target" ]]; then
        log "$target already exists, leaving it alone"
    else
        log "fetching $f -> $target"
        curl -fsSL "${RAW_BASE}/${f}" -o "$target"
    fi
done

# --- 7. Pre-pull the image (public on GHCR, no auth needed) ---
log "pulling ${IMAGE}"
docker pull "${IMAGE}"

# --- 8. Marker file ---
cat > /etc/ztr-coding-agent.version <<EOF
provisioned: yes
bootstrap_date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
sysbox-ce: ${SYSBOX_VERSION}
tailscale: $(tailscale version | head -1 || echo unknown)
EOF

log "done."
log "next steps (all on this host, in ${WORKDIR}/):"
log "  1. If tailscale not joined yet:  tailscale up --ssh"
log "  2. Per developer, copy .env.example -> .env.<initials> and fill in"
log "     their TS_AUTHKEY, GITHUB_TOKEN, ANTHROPIC_API_KEY, SSH_PASSWORD, etc."
log "     example:  cp .env.example .env.al && \$EDITOR .env.al"
log "  3. Edit docker-compose.yml: replace 'xx' placeholders with the owner's"
log "     initials. Duplicate the service block per agent if multiple developers."
log "  4. docker compose up -d"
log "  5. From any tailnet client:  ssh agent@agent-<initials>-01"
