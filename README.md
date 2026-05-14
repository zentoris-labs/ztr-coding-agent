# ztr-coding-agent

Docker image + tooling for running long-lived Claude Code agent containers on
any Linux host. Each agent has a stable identity in the form
`agent-<owner>-<NN>` (e.g. `agent-al-01` for Alice's first slot), its own
isolated `/workspace/`, and joins your **Tailscale** tailnet as its own node.
SSH access is standard sshd reachable only via the tailnet — Tailscale
identity gates network reach, then SSH password/key gates shell access. No
public ports, no internet-facing SSH.

The published image lives at **`ghcr.io/zentoris-labs/ztr-coding-agent`** (public).

## The 4-step deployment model

1. **Create a Linux host.** Ubuntu 24.04 with outbound internet access.
   No inbound ports required — Tailscale handles connectivity.
2. **SSH to the host and run the bootstrap there:**
   ```bash
   ssh root@<host>

   # Then on the host:
   export HOST_TS_AUTHKEY=tskey-auth-xxx
   curl -fsSL https://raw.githubusercontent.com/zentoris-labs/ztr-coding-agent/main/infra/bootstrap.sh | bash
   ```
   Installs Docker, sysbox-runc, Tailscale (joined to your tailnet), pre-pulls the image, and fetches `docker-compose.yml` + `.env.example` to `/opt/ztr-coding-agent/`.
3. **Write a per-host `docker-compose.yml`** listing the agents that machine
   hosts, plus per-developer `.env.<initials>` files with each owner's
   `TS_AUTHKEY` + tokens + SSH credentials. Lives on the host or in a private
   ops repo — not here. See the multi-agent example in
   [infra/README.md](infra/README.md).
4. **`docker compose up -d`** on the host. Each agent joins the tailnet as
   `agent-al-01`, `agent-bo-01`, etc. Connect from any tailnet client via
   `ssh agent@agent-al-01` (resolves via Tailscale MagicDNS).

Full walkthrough in [infra/README.md](infra/README.md).

## Layout

- `Dockerfile` — image definition (Ubuntu 24.04 + .NET 10 + Node 22 + Python 3.12 + Claude Code CLI + gh + Docker engine + Tailscale)
- `scripts/entrypoint.sh` — runtime setup baked into the image
- `docker-compose.yml` — single-agent template (sysbox-runc runtime baked in). Multi-agent example in [infra/README.md](infra/README.md).
- `config/claude/` — default Claude Code settings shipped in the image
- `.env.example` — documented env contract
- `.github/workflows/` — CI builds and publishes to GHCR
- `infra/bootstrap.sh` — host setup script (Docker + sysbox + Tailscale)
- `.claude/settings.json` — project-level Claude Code settings (for contributors editing *this* repo)

## In-container conventions

- Non-root user: **`agent`** (UID 1001), with passwordless sudo
- Workspace: `/workspace/` (named volume per agent)
- Claude Code settings live at `/home/agent/.claude/settings.json`
- **Inbound network:** standard sshd on container port 22, reachable ONLY via the tailnet (no public ports mapped). Tailscale identity gates network reach; SSH password/key gates shell access — two-layer defense.
- Env vars propagate into shell sessions via `/etc/environment` (pam_env)

## Status

Internal Zentoris tooling. Public repo + public image. Per-host compose state
is operator-managed and not committed here.
