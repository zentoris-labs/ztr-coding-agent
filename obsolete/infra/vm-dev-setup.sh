#!/usr/bin/env bash
# Provision a fresh Ubuntu 24.04 Server VM as a single-developer Claude Code
# dev box, with Docker running NATIVELY on the VM (no container layer).
#
# NOTE: For the lower-friction local setup, prefer `infra/multipass-cloud-init.yaml`
# (Multipass — sane defaults, coexists with Docker Desktop). This script remains
# the provisioner for a hand-built Hyper-V or bare Ubuntu VM.
#
# === How this differs from the container image ===
#
# The GHCR image runs dockerd *inside* a container, which is why it needs
# privileged: true, a named volume on /var/lib/docker, and the overlay2
# daemon.json hack. Here Claude Code runs as a normal process on the VM and
# Docker is just the host daemon — so ALL of that machinery is gone. The agent
# spawns containers (debug shells, Testcontainers, throwaway services) directly
# against the local socket with no nesting.
#
# === Trust model ===
#
# The VM is the security boundary; Windows is protected by the Hyper-V VM
# boundary (the VM cannot see C:\ unless you add a shared folder). Inside the
# VM the agent has Docker socket access == root-equivalent, so treat the whole
# VM as owned by the agent: put only scoped secrets in it (a repo-scoped git
# token, the Anthropic key) — nothing you wouldn't hand the agent.
#
# Idempotent — safe to re-run. Mirrors the package manifest in ../Dockerfile.
#
# Usage (on a fresh Ubuntu 24.04 Server VM):
#   sudo bash vm-dev-setup.sh
#   # TARGET_USER defaults to the invoking sudo user; override with:
#   #   sudo TARGET_USER=alice bash vm-dev-setup.sh

set -euo pipefail

log() { printf '[vm-setup] %s\n' "$*" >&2; }

# --- Tunables (override at invocation) ---
DOTNET_CHANNEL="${DOTNET_CHANNEL:-10.0}"
NODE_MAJOR="${NODE_MAJOR:-22}"

if [[ $EUID -ne 0 ]]; then
    log "ERROR: must run as root (try: sudo bash $0)"
    exit 1
fi

# --- Resolve the non-root developer user (docker group + per-user config) ---
TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
    TARGET_USER="$(awk -F: '$3>=1000 && $3<65534 {print $1; exit}' /etc/passwd || true)"
fi
if [[ -z "$TARGET_USER" ]] || ! id "$TARGET_USER" >/dev/null 2>&1; then
    log "ERROR: could not determine a target user. Re-run with TARGET_USER=<name>."
    exit 1
fi
log "provisioning for developer user: $TARGET_USER"

export DEBIAN_FRONTEND=noninteractive

# --- 1. Base OS packages (developer toolbelt, mirrors ../Dockerfile) ---
log "apt update + base packages"
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg \
    git git-lfs \
    openssh-server avahi-daemon \
    sudo less vim nano \
    jq yq ripgrep fd-find tmux htop tree \
    tzdata unzip zip \
    build-essential libicu74 \
    python3 python3-venv python3-pip pipx \
    bash-completion openssl \
    dnsutils iputils-ping netcat-openbsd lsof strace \
    postgresql-client redis-tools
git lfs install --system >/dev/null 2>&1 || true

# --- 2. Node (NodeSource) — needed for the Claude Code CLI ---
if ! command -v node >/dev/null 2>&1 || [[ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -lt "$NODE_MAJOR" ]]; then
    log "installing Node ${NODE_MAJOR}.x"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y --no-install-recommends nodejs
else
    log "node already present ($(node -v))"
fi

# --- 3. .NET via official dotnet-install.sh, channel-pinned ---
if [[ ! -x /usr/share/dotnet/dotnet ]]; then
    log "installing .NET (channel ${DOTNET_CHANNEL})"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    chmod +x /tmp/dotnet-install.sh
    /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --install-dir /usr/share/dotnet
    rm -f /tmp/dotnet-install.sh
    ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
else
    log ".NET already present ($(/usr/share/dotnet/dotnet --version 2>/dev/null || echo unknown))"
fi

# --- 4. GitHub CLI (gh) from the official apt repo ---
if ! command -v gh >/dev/null 2>&1; then
    log "installing GitHub CLI"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq
    apt-get install -y --no-install-recommends gh
else
    log "gh already present ($(gh --version | head -1))"
fi

# --- 5. Docker CE — NATIVE host daemon (no nesting, no privileged) ---
# Unlike the container image, dockerd runs as a normal systemd service on the
# VM. No daemon.json overlay2 override and no /var/lib/docker volume are needed
# because there is no overlay-on-overlay: the VM's disk is the backing store.
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
    log "docker already present ($(docker --version))"
fi
systemctl enable --now docker >/dev/null
# Let the developer (and the agent it runs) use Docker without sudo.
# NB: docker group membership == root-equivalent on this VM — intended here.
usermod -aG docker "$TARGET_USER"

# --- 6. Claude Code CLI (global; autoupdater enabled at runtime) ---
if ! command -v claude >/dev/null 2>&1; then
    log "installing Claude Code CLI"
    npm install -g "@anthropic-ai/claude-code@latest"
else
    log "claude already present ($(claude --version 2>/dev/null || echo unknown))"
fi

# --- 7. Shell environment (login shells: SSH, VS Code Remote, etc.) ---
# Quoted heredoc — $HOME/$PATH stay literal so they resolve per-session.
cat > /etc/profile.d/zz-dev-env.sh <<'EOF'
# Managed by vm-dev-setup.sh
export DOTNET_ROOT=/usr/share/dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
# pipx installs land in ~/.local/bin
export PATH="$DOTNET_ROOT:$HOME/.local/bin:$PATH"
EOF
chmod 0644 /etc/profile.d/zz-dev-env.sh

# --- 8. SSH + mDNS (reach the VM as <hostname>.local from Windows) ---
# avahi advertises <hostname>.local so you don't chase the NAT IP that the
# Hyper-V Default Switch hands out fresh on each boot. Standard key-based SSH
# is assumed (add your Windows public key to ~/.ssh/authorized_keys). If you
# specifically use Claude Code *Desktop's* SSH connector, that needs password
# auth (see the project's known-issues note) — terminal + VS Code Remote-SSH
# work fine with keys.
systemctl enable --now ssh >/dev/null
systemctl enable --now avahi-daemon >/dev/null

# --- 9. Done ---
log "done."
log "  reach it:   ssh ${TARGET_USER}@$(hostname).local"
log "  docker:     log out/in once so '${TARGET_USER}' picks up the docker group"
log "  claude:     no in-VM login needed — Claude Code runs on your host and connects over SSH"
log "  verify:     docker run --rm hello-world && dotnet --info && node -v"
