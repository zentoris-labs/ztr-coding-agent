#!/usr/bin/env bash
# Bootstrap a Ubuntu 24.04 host as a ztr-coding-agent VM.
#
# Idempotent — safe to re-run. Installs Docker CE + Compose, installs
# Tailscale, fetches the compose template + .env.example, and pre-pulls the
# GHCR image. Optionally joins the host to your tailnet with Tailscale SSH
# enabled (set HOST_TS_AUTHKEY before invoking, or paste when prompted).
#
# === Per-host isolation model ===
#
# This script provisions a VM intended for ONE developer's agents (typically
# 1–3 of them). The VM is the security boundary; agents inside it run with
# privileged Docker-in-Docker. Cross-developer separation comes from
# running each developer on a separate VM + Tailscale ACLs — never co-tenant.
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
    ca-certificates curl gnupg git jq nano vim tmux htop

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

# --- 3. Tailscale (system service on the host) ---
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
#
# Skip the prompt if tailscaled already holds a node key (this host joined
# a tailnet before). `HaveNodeKey` is the daemon's authoritative signal —
# set on first successful login, cleared only by explicit `tailscale logout`,
# and unaffected by auth-key expiry or daemon restarts. The current status
# is logged for visibility; recovery from auth expiry is `tailscale up` on
# the host, not re-bootstrapping.
if [[ "$(tailscale status --json 2>/dev/null | jq -r '.HaveNodeKey // false')" == "true" ]]; then
    log "tailscale already configured on this host; skipping join"
    log "  current state: $(tailscale status --peers=false 2>&1 | head -1 || echo unavailable)"
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

# --- 4. Working directory: git clone of the repo (so updates are `git pull`) ---
# Public repo, shallow clone. .env is gitignored upstream, so the operator's
# secrets sit alongside the working tree without colliding with `git pull`.
# Re-runnable: existing clone → fast-forward to latest; missing → fresh clone.
REPO_URL="${REPO_URL:-https://github.com/zentoris-labs/ztr-coding-agent.git}"
REPO_REF="${REPO_REF:-main}"
if [[ -d "${WORKDIR}/.git" ]]; then
    log "${WORKDIR} is a git clone — fetching ${REPO_REF}"
    git -C "${WORKDIR}" fetch --quiet origin "${REPO_REF}"
    if ! git -C "${WORKDIR}" merge --ff-only "origin/${REPO_REF}"; then
        log "  WARN: fast-forward failed (local edits in ${WORKDIR}?). Resolve manually:"
        log "    git -C ${WORKDIR} status"
    fi
elif [[ -d "${WORKDIR}" ]] && [[ -n "$(ls -A "${WORKDIR}" 2>/dev/null)" ]]; then
    log "WARN: ${WORKDIR} exists and is NOT a git clone (older bootstrap layout)."
    log "  to migrate: cp ${WORKDIR}/.env /root/.env.backup ; rm -rf ${WORKDIR} ; re-run bootstrap"
    log "  leaving it alone for now."
else
    log "cloning ${REPO_URL} (${REPO_REF}) -> ${WORKDIR}"
    rm -rf "${WORKDIR}"   # remove empty placeholder if present
    git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${WORKDIR}"
fi

# --- 5. Pre-pull the image (public on GHCR, no auth needed) ---
log "pulling ${IMAGE}"
docker pull "${IMAGE}"

# --- 6. Marker file ---
cat > /etc/ztr-coding-agent.version <<EOF
provisioned: yes
bootstrap_date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
model: per-host-isolation (VM is the trust boundary; privileged DinD inside)
tailscale: $(tailscale version | head -1 || echo unknown)
EOF

log "done. next: edit ${WORKDIR}/.env, then 'docker compose up -d'."
log "full quick-start: https://github.com/zentoris-labs/ztr-coding-agent#quick-start"
