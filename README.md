# ztr-coding-agent

Docker image + tooling for running long-lived Claude Code agent containers on a per-developer VM. Each agent joins your Tailscale tailnet as its own node (`agent-<initials>-<NN>`, e.g. `agent-ch-01`) and accepts SSH only over the tailnet — no public ports.

Image: **`ghcr.io/zentoris-labs/ztr-coding-agent`** (public).

## Architecture

**Per-host isolation:** each developer gets their own VM hosting their agents. The **VM is the security boundary** — agents on it run with `privileged: true` for nested Docker (Testcontainers etc.); they're all the same person's stuff so internal isolation isn't worth its cost.

**Cross-developer separation:** different VMs + Tailscale ACLs. Christof and Bob never share a VM.

**Two-layer access:**
1. **Tailscale identity** gates network reachability (only tailnet members reach the agent)
2. **SSH password** gates shell access (key auth isn't supported — Claude Code Desktop's connector can't read IdentityFile cleanly, [#25661](https://github.com/anthropics/claude-code/issues/25661))

Sizing (per developer):

| Agents | Hetzner type | ~Cost |
|---|---|---|
| 1–2 | CPX22 (3 vCPU, 4 GB) | ~€7/mo |
| 3+  | CPX32 (4 vCPU, 8 GB) | ~€13/mo |

## Prerequisites

- A Tailscale account — configure ACL + generate auth keys per **[docs/tailscale.md](docs/tailscale.md)**.
- A Linux host (Hetzner Cloud, office machine, EC2 — anything Ubuntu 24.04 with outbound internet).
- A GitHub fine-grained PAT (Contents r/w + PRs r/w on whatever repos the agent touches).
- (Optional) Anthropic API key — only if you want pay-per-token billing. Otherwise use a Claude Max/Pro subscription via `/login` inside each agent.

## Quick start

```bash
# 1. Provision a VM (Hetzner Cloud example)
hcloud server create --name ztr-agent-host-ch --type cpx32 \
  --image ubuntu-24.04 --location hel1 --ssh-key <your-key>

# 2. Bootstrap the host (installs Docker + Tailscale, fetches compose template)
ssh-keygen -R <ip>           # optional: clears stale known_hosts entry if Hetzner recycled the IP
ssh root@<ip>
curl -fsSL https://raw.githubusercontent.com/zentoris-labs/ztr-coding-agent/main/infra/bootstrap.sh | bash
# Paste the host Tailscale auth key when prompted

# 3. Configure
cd /opt/ztr-coding-agent
cp .env.example .env
nano .env                # set INITIALS, COMPOSE_PROFILES, TS_AUTHKEY, GITHUB_TOKEN, SSH_PASSWORD
chmod 600 .env

# 4. Start the agents
docker compose up -d

# 5. SSH in from your laptop
ssh-keygen -R agent-ch-01    # optional: clears stale known_hosts entry (same as step 2)
ssh agent@agent-ch-01        # password = SSH_PASSWORD; lands in ~/
```

First `claude` invocation prompts for `/login` (OAuth → Claude Max subscription). One-time per agent slot; persisted in the home volume.

**VS Code Remote-SSH** is the recommended editor for host config: `Ctrl+Shift+P` → "Remote-SSH: Connect to Host…" → `root@ztr-agent-host-<initials>` → open `/opt/ztr-coding-agent/`. Much nicer than nano over SSH for multi-line edits.

## How many agents?

`docker-compose.yml` predefines **20 slots** with cumulative profiles. `COMPOSE_PROFILES=N` in `.env` runs the first N:

```
COMPOSE_PROFILES=1     # just agent-01
COMPOSE_PROFILES=3     # agent-01..03
COMPOSE_PROFILES=all   # all 20
```

Change later → edit `.env` → `docker compose up -d`. Unused slots never create volumes.

## Daily use

| Action | Command |
|---|---|
| Bump agent count | Edit `COMPOSE_PROFILES` → `docker compose up -d` |
| Restart an agent | `docker compose restart agent-01` |
| Upgrade the image | `docker compose pull && docker compose up -d` |
| Tear down (keep state) | `docker compose down` |
| Tear down (wipe state) | `docker compose down -v` |
| Delete the host | `hcloud server delete ztr-agent-host-<initials>` |

## Onboarding a teammate

See **[docs/tailscale.md § Onboarding a teammate](docs/tailscale.md#3-onboarding-a-teammate)**. TL;DR: they provision their own VM; never co-tenant.

## Layout

```
Dockerfile                      # image: Ubuntu 24.04 + .NET 10 + Node 22 + Python 3.12 + Claude Code + gh + Docker + Tailscale + sshd
scripts/entrypoint.sh           # runtime: ssh keys, env propagation, git creds, tailscaled + sshd, optional dockerd
config/claude/settings.json     # baked Claude Code defaults
docker-compose.yml              # 20 agent slots (cumulative profile-gated) for one developer
.env.example                    # env contract
infra/bootstrap.sh              # host setup script (Docker + Tailscale)
docs/tailscale.md               # Tailscale ACL + auth keys + teammate onboarding
.github/workflows/              # CI → ghcr.io/zentoris-labs/ztr-coding-agent
AGENTS.md / CLAUDE.md           # instructions for AI agents working on this repo
```

## Status

Internal Zentoris tooling. Public repo + public image. Per-host operator state (the `.env`, the actual deployment) lives on the host, never committed.
