# ztr-coding-agent

Docker image + tooling for running long-lived Claude Code agent containers on
any Linux host. Each agent is a sysbox-isolated container that joins your
Tailscale tailnet as its own node (named `agent-<owner>-<NN>` — e.g.
`agent-al-01`) and accepts SSH only over the tailnet. No public ports.

The published image lives at **`ghcr.io/zentoris-labs/ztr-coding-agent`** (public).

---

## Quick mental model

```
your laptop on tailnet
        │
        ▼ ssh (over Tailscale) — MagicDNS resolves
agent-al-01.<tailnet>.ts.net:22
        │
   sshd in container
        │
shell as `agent` user, lands in /workspace/
```

Two-layer security:

1. **Tailscale identity** gates network reachability (only tailnet members can reach the agent)
2. **SSH password or key** gates shell access

No public SSH ports on the host. Brute-force isn't possible because the port isn't reachable from the open internet.

---

## Step-by-step setup

### Prerequisites

- A Tailscale account ([tailscale.com](https://tailscale.com) — free tier works)
- A Linux host (Hetzner Cloud, office machine, EC2 — anything with Ubuntu 24.04 and outbound internet)
- An SSH key registered with that host (for the *initial* bootstrap only; afterwards you use Tailscale SSH)
- An Anthropic API key ([console.anthropic.com](https://console.anthropic.com)) — for Claude Code inside the agent
- A GitHub Personal Access Token — for the agent's git operations

---

### Step 1 — Configure your Tailscale ACL policy (one-time)

Open **[login.tailscale.com/admin/acls/file](https://login.tailscale.com/admin/acls/file)** and replace your policy with this (adjusting `<your-email>` and `<your-initials>`):

```hujson
{
  "tagOwners": {
    "tag:agent-host":             ["autogroup:admin"],
    "tag:agent-<your-initials>":  ["<your-email>"],
    // One line per teammate (added on onboarding — see "Adding a teammate" below)
  },

  "grants": [
    // Admins reach everything (for ops/debugging)
    { "src": ["autogroup:admin"], "dst": ["*"], "ip": ["*"] },

    // Members reach their own non-tagged devices (laptop ↔ phone)
    { "src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"] },

    // Each developer reaches only their own tagged agents — strict isolation
    { "src": ["<your-email>"], "dst": ["tag:agent-<your-initials>"], "ip": ["*"] },
    // Add per-teammate grants here
  ],

  "ssh": [
    // Default: SSH to your own non-tagged devices (laptop ↔ phone)
    {
      "action": "check",
      "src":    ["autogroup:member"],
      "dst":    ["autogroup:self"],
      "users":  ["autogroup:nonroot", "root"],
    },
    // Admins: Tailscale SSH to host VMs
    {
      "action": "accept",
      "src":    ["autogroup:admin"],
      "dst":    ["tag:agent-host"],
      "users":  ["root", "autogroup:nonroot"],
    },
  ],
}
```

Click **Save**.

This policy gives you network-level isolation: each developer can only reach their *own* tagged agents over the tailnet. Admins keep an "ops override" reaching everything, useful for debugging others' setups.

#### Adding a teammate

When Bob joins (initials `bo`, email `bob@yourdomain.com`):

1. Invite Bob to the tailnet (Tailscale admin → Users → Invite).
2. Add two stanzas to the ACL policy:
   ```hujson
   // In tagOwners:
   "tag:agent-bo": ["bob@yourdomain.com"],

   // In grants:
   { "src": ["bob@yourdomain.com"], "dst": ["tag:agent-bo"], "ip": ["*"] },
   ```
3. Bob generates his own auth key at [admin/settings/keys](https://login.tailscale.com/admin/settings/keys) tagged `tag:agent-bo`.
4. Bob configures his agent on the shared host: copy `.env.example` to `.env.bo`, fill in his key + tokens, append a `agent-bo-01` service block to `docker-compose.yml`, `docker compose up -d agent-bo-01`.
5. Bob connects via `ssh agent@agent-bo-01`. Other developers can't reach Bob's agents (and vice versa).

---

### Step 2 — Generate two Tailscale auth keys

Open **[login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)**. Click **Generate auth key…** twice — once for the host, once for your first agent:

**Auth key #1 — for the host VM:**
- Description: `host` (or whatever)
- Reusable: ☐ off (single-use)
- Ephemeral: ☐ off (hosts are persistent)
- Pre-approved: ☑ on (if your tailnet requires device approval)
- Tags: **`tag:agent-host`**
- Click **Generate key** → copy the `tskey-auth-...` string. We'll call this **`HOST_TS_AUTHKEY`**.

**Auth key #2 — for your first agent container:**
- Description: `agent-<initials>-01`
- Reusable: ☐ off
- Ephemeral: ☐ off
- Tags: **`tag:agent-<your-initials>`**
- Generate → copy. We'll call this **`TS_AUTHKEY`**.

Tailscale only shows each key once. Save them in your password manager.

---

### Step 3 — Create a Linux host (Hetzner Cloud example)

Skip this step if you already have a Linux host ready (office workstation, EC2, etc.). Just make sure it has Ubuntu 24.04 and an SSH key you can connect with.

```bash
# Install hcloud CLI: https://github.com/hetznercloud/cli/releases
hcloud context create <your-project-name>   # paste your API token when prompted

# One-time: register your SSH public key with the Hetzner project
hcloud ssh-key create --name <key-name> --public-key-from-file ~/.ssh/id_ed25519.pub

# Provision the VM (CPX32 = 4 vCPU, 8 GB RAM, ~€17/mo. Adjust to taste.)
hcloud server create \
    --name ztr-agent-host-01 \
    --type cpx32 \
    --image ubuntu-24.04 \
    --location nbg1 \
    --ssh-key <key-name>
```

Note the IPv4 address it prints. We'll only use it once (next step) — afterwards all access is via Tailscale.

---

### Step 4 — Bootstrap the host

SSH in with your standard SSH key (the one you registered), then run the bootstrap on the host:

```bash
ssh root@<host-ip>

# Now on the host:
curl -fsSL https://raw.githubusercontent.com/zentoris-labs/ztr-coding-agent/main/infra/bootstrap.sh | bash
```

The script prompts (silently) for your Tailscale auth key from Step 2 —
paste it and hit Enter. The key isn't stored anywhere: not in env vars, not
in shell history, not in any file. Used once for the tailnet join, then dropped.

Takes about 2-3 minutes total. Watch for `[bootstrap] done.` at the end.

What this installs:
- Docker CE + Compose
- sysbox-runc (registered as a Docker runtime)
- Tailscale (joined to your tailnet with Tailscale SSH enabled on the host)
- Pre-pulls `ghcr.io/zentoris-labs/ztr-coding-agent:latest`
- Fetches `docker-compose.yml` and `.env.example` into `/opt/ztr-coding-agent/`

From here on, you can stop using public-IP SSH and use Tailscale SSH for the host:

```bash
tailscale ssh root@ztr-agent-host-01    # MagicDNS resolves the name
```

---

### Step 5 — Configure your first agent

Still on the host (now reachable via `tailscale ssh root@ztr-agent-host-01`):

```bash
cd /opt/ztr-coding-agent

# Make your per-developer env file (replace `xx` with your initials)
cp .env.example .env.xx
$EDITOR .env.xx
```

Fill in `.env.xx`:

```bash
# From auth key #2 in Step 2:
TS_AUTHKEY=tskey-auth-<paste-agent-key>

# Your GitHub fine-grained PAT — scopes: Contents r/w, Pull requests r/w
GITHUB_TOKEN=ghp_...

# Your Anthropic API key
ANTHROPIC_API_KEY=sk-ant-...

# Identity for commits/PRs the agent makes
GIT_AUTHOR_NAME=your-bot-name
GIT_AUTHOR_EMAIL=bot@yourdomain.com

# Public key(s) you'll use to SSH in (e.g. your laptop's id_ed25519.pub).
# Optional — use SSH_PASSWORD instead if your SSH client is finicky
# (Claude Code Desktop's connector currently is — see issue #25661).
SSH_AUTHORIZED_KEYS=ssh-ed25519 AAAA... your-laptop

# Optional — password for Claude Code Desktop's SSH connector
SSH_PASSWORD=

# Optional — enable in-container Docker (for Testcontainers etc.)
AGENT_ENABLE_DOCKER=1

# Optional — repos to auto-clone on first boot
AGENT_REPOS=
```

Then customize the compose file — replace every `xx` with your initials:

```bash
$EDITOR docker-compose.yml
```

Change:
- `agent-xx-01` → `agent-<your-initials>-01` (8 occurrences)
- `.env.xx` → `.env.<your-initials>`
- `AGENT_ID: "xx-01"` → `AGENT_ID: "<your-initials>-01"`

(Or use a quick `sed`: `sed -i 's/xx/<your-initials>/g' docker-compose.yml`)

---

### Step 6 — Start the agent

```bash
docker compose up -d
docker logs -f agent-<your-initials>-01
```

Wait for `Server listening on 0.0.0.0 port 22.` — the agent's now on your tailnet.

---

### Step 7 — Connect from your laptop

Make sure your laptop is on the same tailnet (install Tailscale if you haven't). Then:

```bash
ssh agent@agent-<your-initials>-01
```

MagicDNS resolves the hostname; SSH auths with your `SSH_AUTHORIZED_KEYS` (or password). You land in `/workspace/`.

Claude Code Desktop's SSH connector: host = `agent-<your-initials>-01`, user = `agent`, IdentityFile empty (use password from `SSH_PASSWORD`).

---

## Daily use

| Action | Command |
|---|---|
| Add another agent slot (yourself) | Duplicate the service + volume block in `docker-compose.yml` (incrementing `01` → `02`), generate a fresh `tag:agent-<you>` auth key, paste into a second `.env.xx` if you want different env per slot, then `docker compose up -d` |
| Onboard a new developer | Add their email + new tag to ACL policy, they generate their own keys, drop their `.env.<their-initials>` next to yours, append their service to compose |
| Restart an agent | `docker compose restart agent-xx-01` |
| Tear it down | `docker compose down` (keeps volumes) or `docker compose down -v` (wipes state) |
| Upgrade the image | `docker compose pull && docker compose up -d` |
| Tear down the host VM | `hcloud server delete ztr-agent-host-01` |

---

## Layout

- `Dockerfile` — image: Ubuntu 24.04 + .NET 10 + Node 22 + Python 3.12 + Claude Code + gh + Docker + Tailscale + sshd
- `scripts/entrypoint.sh` — runtime setup baked into the image
- `docker-compose.yml` — single-agent template (placeholder `xx`)
- `config/claude/` — default Claude Code settings shipped in the image
- `.env.example` — env contract; copy to `.env.<initials>` per developer on the host
- `.github/workflows/` — CI builds and publishes to GHCR
- `infra/bootstrap.sh` — host setup script (Docker + sysbox + Tailscale)
- `infra/README.md` — reference docs and multi-agent compose example
- `AGENTS.md` / `CLAUDE.md` — instructions for AI agents working on this repo

## Status

Internal Zentoris tooling. Public repo + public image. Per-host compose state
is operator-managed and not committed here.
