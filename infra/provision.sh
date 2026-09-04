#!/usr/bin/env bash
# Idempotent provisioner for a local Multipass Claude Code agent VM.
#
# SINGLE SOURCE OF TRUTH for the VM toolchain. It is:
#   - run once at first boot by infra/multipass-cloud-init.yaml, and
#   - safe to re-run any time to ADD or UPDATE tools on an existing VM.
#
# Update one VM (from the host):
#   multipass exec <vm> -- bash -c 'curl -fsSL <raw>/infra/provision.sh | sudo bash'
# ...or all of them at once — see README "Updating the toolchain".
#
# PURE TOOLCHAIN — no secrets. Credentials/keys are still added by hand after
# launch (NetBird setup key, SSH public key, gh auth); see README.
#
# Idempotent: every step checks before it acts, so re-runs are fast and safe.
# Re-running upgrades apt packages, Go, and the browser; bump the version
# tunables below for a new major runtime (e.g. a newer .NET channel or JDK).

set -euo pipefail
log() { printf '[provision] %s\n' "$*" >&2; }

# --- Tunables (override via env) ---
DOTNET_CHANNEL="${DOTNET_CHANNEL:-10.0}"
JAVA_PKG="${JAVA_PKG:-openjdk-21-jdk}"
GO_VERSION="${GO_VERSION:-}"           # empty → latest stable from go.dev
TARGET_USER="${TARGET_USER:-ubuntu}"   # the agent/dev user (docker group, ~/.claude)

[[ $EUID -eq 0 ]] || { log "ERROR: run as root (sudo bash $0)"; exit 1; }
id "$TARGET_USER" >/dev/null 2>&1 || { log "ERROR: user '$TARGET_USER' not found (set TARGET_USER)"; exit 1; }
ARCH="$(dpkg --print-architecture)"    # amd64 | arm64
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
export DEBIAN_FRONTEND=noninteractive

# --- 1. Base packages: dev CLIs, build tools, Python, Java, headless-browser display ---
# apt-get install upgrades already-present packages, so a re-run refreshes these.
log "apt: base packages, Python, Java (${JAVA_PKG}), dev CLIs"
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release unattended-upgrades \
    git git-lfs \
    build-essential pkg-config \
    jq ripgrep fd-find fzf tree \
    tmux htop vim nano less openssl \
    unzip zip \
    dnsutils iputils-ping netcat-openbsd lsof \
    postgresql-client redis-tools sqlite3 \
    shellcheck \
    python3 python3-pip python3-venv python3-dev pipx python-is-python3 \
    "${JAVA_PKG}" \
    xvfb
git lfs install --system >/dev/null 2>&1 || true
runuser -l "$TARGET_USER" -c 'pipx ensurepath >/dev/null 2>&1 || true'

# --- 2. Node.js (current LTS via NodeSource) ---
if ! command -v node >/dev/null 2>&1; then
    log "installing Node.js (LTS)"
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
    apt-get install -y nodejs
else
    log "node present ($(node -v))"
fi

# --- 3. GitHub CLI ---
if ! command -v gh >/dev/null 2>&1; then
    log "installing GitHub CLI"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq
    apt-get install -y gh
else
    log "gh present"
fi

# --- 4. .NET SDK (channel-pinned, official installer) ---
if [[ ! -x /usr/share/dotnet/dotnet ]]; then
    log "installing .NET SDK (channel ${DOTNET_CHANNEL})"
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --install-dir /usr/share/dotnet
    rm -f /tmp/dotnet-install.sh
    ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet
else
    log ".NET present ($(/usr/share/dotnet/dotnet --version 2>/dev/null || echo unknown))"
fi

# --- 5. Go (latest stable from go.dev, or GO_VERSION); re-run updates it ---
GO_WANT="${GO_VERSION:-$(curl -fsSL 'https://go.dev/VERSION?m=text' 2>/dev/null | head -1 || true)}"
GO_HAVE="$(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || true)"
if [[ -z "$GO_WANT" ]]; then
    log "WARN: could not resolve latest Go version (offline?) — skipping Go"
elif [[ "$GO_WANT" != "$GO_HAVE" ]]; then
    log "installing Go ${GO_WANT} (${ARCH})"
    if curl -fsSL "https://go.dev/dl/${GO_WANT}.linux-${ARCH}.tar.gz" -o /tmp/go.tgz; then
        rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
    else
        log "WARN: Go download failed — skipping (re-run to retry)"
    fi
else
    log "go present (${GO_HAVE})"
fi

# --- 6. Docker CE (native daemon) ---
if ! command -v docker >/dev/null 2>&1; then
    log "installing Docker CE"
    curl -fsSL https://get.docker.com | sh
else
    log "docker present ($(docker --version))"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker || usermod -aG docker "$TARGET_USER"

# --- 7. NetBird client (network + DNS; join manually with `netbird up`) ---
if ! command -v netbird >/dev/null 2>&1; then
    log "installing NetBird client"
    curl -fsSL https://pkgs.netbird.io/install.sh | sh
else
    log "netbird present ($(netbird version 2>/dev/null || echo unknown))"
fi

# --- 8. Claude Code CLI (global) ---
if ! command -v claude >/dev/null 2>&1; then
    log "installing Claude Code CLI"
    npm install -g @anthropic-ai/claude-code
else
    log "claude present ($(claude --version 2>/dev/null || echo unknown))"
fi

# --- 9. Headless browser for agents (Playwright + Chromium; re-run updates chromium) ---
# Non-fatal: a flaky browser download must not abort the rest of provisioning.
log "playwright: chromium + deps"
npx --yes playwright@latest install-deps chromium || log "WARN: playwright install-deps failed (re-run to retry)"
runuser -l "$TARGET_USER" -c 'npx --yes playwright@latest install chromium' || log "WARN: playwright chromium install failed (re-run to retry)"
# Register the Playwright MCP for the agent user (idempotent)
runuser -l "$TARGET_USER" -c "claude mcp list 2>/dev/null | grep -qi '^playwright' || claude mcp add --scope user playwright -- npx -y @playwright/mcp@latest" || log "WARN: playwright MCP registration failed (add it by hand — see README)"

# --- 10. Shell environment (login shells: SSH, VS Code Remote, etc.) ---
cat > /etc/profile.d/zz-dev-env.sh <<'EOF'
# Managed by provision.sh
export DOTNET_ROOT=/usr/share/dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1
# Go toolchain + Go-installed binaries; .NET; pipx/user-local bins
export PATH="/usr/local/go/bin:$DOTNET_ROOT:$HOME/.local/bin:$HOME/go/bin:$PATH"
EOF
chmod 0644 /etc/profile.d/zz-dev-env.sh

# --- 11. Agent browser guidance (~/.claude/CLAUDE.md, user-level, idempotent) ---
CLAUDE_MD="${USER_HOME}/.claude/CLAUDE.md"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 0755 "$(dirname "$CLAUDE_MD")"
if ! grep -q "headless VM" "$CLAUDE_MD" 2>/dev/null; then
    log "writing agent browser guidance to ${CLAUDE_MD}"
    cat >> "$CLAUDE_MD" <<'EOF'

## Browser / screenshots — this is a headless VM

This machine has NO desktop Chrome and NO Claude browser extension. Do not use
the Claude-in-Chrome tools and never report that you "can't take a screenshot."

For any browser task — screenshots, layout/alignment checks, clicking a
dropdown, confirming a page renders — use the Playwright MCP (headless Chromium)
against the app's URL. Chromium + deps are installed. If a site blocks headless,
run it headed under Xvfb (`xvfb-run`).
EOF
    chown "$TARGET_USER:$TARGET_USER" "$CLAUDE_MD"
fi

# --- 12. Automatic security updates ---
dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null 2>&1 || true

# --- Done ---
log "provisioning complete. installed:"
{
  echo "  node:   $(node -v 2>/dev/null || echo -)"
  echo "  dotnet: $(/usr/share/dotnet/dotnet --version 2>/dev/null || echo -)"
  echo "  python: $(python3 --version 2>&1 || echo -)"
  echo "  go:     $(/usr/local/go/bin/go version 2>/dev/null | awk '{print $3}' || echo -)"
  echo "  java:   $(java -version 2>&1 | head -1 || echo -)"
  echo "  docker: $(docker --version 2>/dev/null || echo -)"
} >&2 || true
log "next (manual): netbird up --setup-key=..., add your SSH key, gh auth login (see README)."
