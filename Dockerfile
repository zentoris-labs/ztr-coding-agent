# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04

# --- Build args (override at build time, no secrets allowed) ---
ARG DOTNET_CHANNEL=10.0
ARG AGENT_UID=1001
ARG AGENT_GID=1001

# OCI labels — `image.source` links the GHCR package to this repo.
LABEL org.opencontainers.image.source="https://github.com/zentoris-labs/ztr-coding-agent" \
      org.opencontainers.image.description="Multi-agent Claude Code sandbox (Ubuntu 24.04 + .NET 10 + Node 22 + Python 3.12 + Claude Code CLI + gh + Tailscale SSH)" \
      org.opencontainers.image.licenses="proprietary"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC \
    EDITOR=nano \
    PAGER=less \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_ROOT=/usr/share/dotnet \
    PATH=/usr/share/dotnet:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# --- Base OS packages ---
# Core OS + developer toolbelt. Picked for "reflex" debugging: DNS, port
# probes, process/file inspection, DB clients. Skip cloud CLIs and extra
# language runtimes — those are project-specific and the agent can install
# them per-repo without bloating every image.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        gnupg \
        git \
        git-lfs \
        openssh-server \
        sudo \
        less \
        vim \
        nano \
        jq \
        yq \
        ripgrep \
        fd-find \
        tmux \
        htop \
        tree \
        tzdata \
        unzip \
        zip \
        build-essential \
        libicu74 \
        python3 \
        python3-venv \
        python3-pip \
        pipx \
        bash-completion \
        openssl \
        dnsutils \
        iputils-ping \
        netcat-openbsd \
        lsof \
        strace \
        postgresql-client \
        redis-tools \
    && rm -rf /var/lib/apt/lists/*

# --- Node 22 via NodeSource (needed for Claude Code CLI) ---
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- .NET via official dotnet-install.sh, channel-pinned ---
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh \
    && chmod +x /tmp/dotnet-install.sh \
    && /tmp/dotnet-install.sh --channel "${DOTNET_CHANNEL}" --install-dir /usr/share/dotnet \
    && rm /tmp/dotnet-install.sh \
    && ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet

# --- GitHub CLI (gh) from official apt repo ---
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# --- Docker engine + CLI (for Testcontainers etc.) ---
# Daemon is started by the entrypoint and listens on /var/run/docker.sock.
# Per-host isolation model: the *VM* is the trust boundary, so the container
# runs `privileged: true` in compose. That gives the in-container dockerd a
# plain rootful environment with no nested-namespace gymnastics. This is
# safe here because every agent on a given VM belongs to the same developer;
# cross-developer separation is enforced by running each developer on their
# own VM + Tailscale ACLs, not by sandboxing agents from each other.
#
# Storage: TWO things have to be true for nested Docker to work cleanly:
#
#   1. `/var/lib/docker` MUST be a named volume (see docker-compose.yml).
#      Without it, dockerd inherits the container's overlay rootfs and
#      overlay-on-overlay storage fails.
#
#   2. dockerd MUST use the classic overlay2 storage driver, NOT the
#      containerd image store (which is the docker-ce default since v28).
#      The containerd snapshotter stores layers under /var/lib/containerd
#      (still on overlay rootfs!) and reports as `Storage Driver: overlayfs`
#      with `driver-type: io.containerd.snapshotter.v1` — confusing because
#      it looks like a fix but actually undoes the volume mount. We force
#      overlay2 via /etc/docker/daemon.json below.
#
# Privileged unblocks capabilities, not storage. Both pieces are required.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && chmod a+r /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable" \
        > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
        iptables \
        iproute2 \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl disable docker.service docker.socket 2>/dev/null || true

# Force classic overlay2 storage driver — see comment block above for why.
# Picked up by dockerd at startup; entrypoint doesn't need to know about it.
RUN install -d -m 0755 /etc/docker \
    && printf '%s\n' \
        '{' \
        '  "features": {' \
        '    "containerd-snapshotter": false' \
        '  },' \
        '  "storage-driver": "overlay2"' \
        '}' \
        > /etc/docker/daemon.json

# --- Claude Code CLI (latest at build time; autoupdater enabled at runtime) ---
RUN npm install -g "@anthropic-ai/claude-code@latest"

# --- Non-root user `agent` ---
# Generic name: this is the user that runs Claude Code (or any other agent)
# inside the container. Don't bake the AI product name into the UNIX user.
RUN groupadd --gid "${AGENT_GID}" agent \
    && useradd --uid "${AGENT_UID}" --gid "${AGENT_GID}" \
        --create-home --shell /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/agent \
    && chmod 0440 /etc/sudoers.d/agent \
    && usermod -aG docker agent

# --- Tailscale (network overlay) ---
# tailscaled brings the container onto your tailnet so sshd is reachable
# only by tailnet members (no public ports needed). We deliberately do NOT
# enable Tailscale SSH (`--ssh` flag) because Claude Code Desktop's SSH
# connector can't authenticate against it (uses a bundled ssh2 lib that
# doesn't speak Tailscale's cert flow). Plain openssh-server over tailnet
# is the supported pattern; the two-layer model (Tailscale identity gates
# network reach, then SSH password/key gates shell) is the recommended
# security posture for this use case.
RUN curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
        > /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
        > /etc/apt/sources.list.d/tailscale.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

# --- SSH client default: never block on a host-key prompt ---
# `accept-new` trusts first-seen hosts but still rejects mismatches (downgrade
# protection). Without this, the first `git clone git@…` or `ssh other-agent`
# inside a non-interactive shell hangs forever on the host-key prompt that
# nothing is there to answer. /etc/ssh/ssh_config sources ssh_config.d/*.conf,
# and the user's ~/.ssh/config still wins per-host.
RUN install -d -m 0755 /etc/ssh/ssh_config.d \
    && printf 'Host *\n  StrictHostKeyChecking accept-new\n' \
        > /etc/ssh/ssh_config.d/10-agent-defaults.conf \
    && chmod 0644 /etc/ssh/ssh_config.d/10-agent-defaults.conf

# --- sshd: pubkey-only by default; password optionally enabled per-agent ---
# Host keys persisted via the agent-<owner>-<NN>-ssh-keys named volume so
# clients' known_hosts entries stay valid across rebuilds.
RUN mkdir -p /var/run/sshd /etc/ssh/keys \
    && mkdir -p /home/agent/.ssh \
    && chown agent:agent /home/agent/.ssh \
    && chmod 700 /home/agent/.ssh \
    && sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's|^#\?AuthorizedKeysFile.*|AuthorizedKeysFile .ssh/authorized_keys|' /etc/ssh/sshd_config \
    && sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/^#\?UsePAM.*/UsePAM yes/' /etc/ssh/sshd_config \
    && sed -i '/^HostKey /d' /etc/ssh/sshd_config \
    && printf '\nHostKey /etc/ssh/keys/ssh_host_ed25519_key\nHostKey /etc/ssh/keys/ssh_host_rsa_key\nHostKey /etc/ssh/keys/ssh_host_ecdsa_key\nKbdInteractiveAuthentication no\nAllowUsers agent\n' >> /etc/ssh/sshd_config

# --- Claude Code default settings ---
# Baked into /home/agent/.claude/settings.json so the first-run wizard is
# skipped. Because /home/agent is a named volume, the file is copied into
# the empty volume on first init; subsequent user edits via `/config` persist
# and win over re-builds. Re-creating the volume from scratch re-seeds.
# NB: pre-create the directory ourselves — using COPY --chmod alone applies
# the mode to the auto-created parent dir too, stripping the +x bit.
RUN install -d -o agent -g agent -m 0755 /home/agent/.claude
COPY --chown=1001:1001 --chmod=0644 config/claude/settings.json /home/agent/.claude/settings.json

# --- Entrypoint ---
COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /home/agent
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
