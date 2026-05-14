# infra/

Host setup for machines that run `ztr-coding-agent` containers.

Manual host creation + one bootstrap script. No provisioning automation lives
here; host shapes vary too widely (Hetzner / office workstation / dedicated
server / EC2) to abstract usefully.

## The 4 steps

### 1. Create a Linux host

Any Ubuntu 24.04 box. Requirements:

- Reachable from your Tailscale clients (it can have a public IP or be on a
  private network — Tailscale handles connectivity either way)
- Outbound internet for `apt`, Docker pulls, Tailscale control plane
- Root access via SSH key (just for initial bootstrap — Tailscale SSH takes
  over for ongoing management)

For Hetzner Cloud:

```bash
hcloud server create \
    --name ztr-agent-host-01 \
    --type ccx23 \
    --image ubuntu-24.04 \
    --location nbg1 \
    --ssh-key <your-registered-key-name>
```

You don't need to open inbound SSH at the Hetzner firewall — once Tailscale's
up, all management traffic flows over the tailnet.

### 2. Run the bootstrap on the host

Get a Tailscale auth key (single-use, optionally tagged) from
[login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys).
Then:

```bash
ssh root@<host> "HOST_TS_AUTHKEY=tskey-auth-xxxxx bash -s" \
    < <(curl -fsSL https://raw.githubusercontent.com/zentoris-labs/ztr-coding-agent/main/infra/bootstrap.sh)
```

The script installs:

- Docker CE + Compose plugin
- `sysbox-runc` — registered as the Docker runtime that agent containers use
- Tailscale — joined to your tailnet with **Tailscale SSH enabled on the host**
  (so operator admin via `tailscale ssh root@<host>` works with identity auth)
- Pre-pulls `ghcr.io/zentoris-labs/ztr-coding-agent:latest`
- Fetches the current `docker-compose.yml` + `.env.example` from this repo
  into `/opt/ztr-coding-agent/` (existing files are left alone, so re-running
  the bootstrap won't clobber a customized compose)

Note the asymmetry: the *host* uses Tailscale SSH for admin (no SSH keys to
manage). The *agent containers* run plain sshd over the tailnet (because
Claude Code Desktop's SSH connector can't authenticate against Tailscale SSH
— see [#25661](https://github.com/anthropics/claude-code/issues/25661)).

After this point the host is on your tailnet. Subsequent SSH goes via
`tailscale ssh root@<hostname>` — no public ports needed.

Idempotent — safe to re-run to upgrade sysbox or refresh the image.

### 3. Customize the per-host `docker-compose.yml` + per-developer `.env.<initials>`

Bootstrap already fetched the single-agent template + `.env.example` into
`/opt/ztr-coding-agent/`. On the host, customize them:

```bash
cd /opt/ztr-coding-agent

# 3a. Create one .env file per developer who runs an agent on this host
cp .env.example .env.al               # for Alice
$EDITOR .env.al                       # fill in TS_AUTHKEY, GITHUB_TOKEN, ...

# 3b. Edit docker-compose.yml — replace every `xx` with the owner's initials.
#     For multiple developers, duplicate the service block + volume entries.
$EDITOR docker-compose.yml
```

**Naming convention:** each agent has the form `agent-<owner>-<NN>` where
`<owner>` is the 2–3 character initials of the developer who owns the slot
and `<NN>` is a 2-digit per-owner index. So Alice's first slot is
`agent-al-01`, her second is `agent-al-02`, Bob's first is `agent-bo-01`,
etc. The slot is the *owner's identity on this host*, not the host's identity.

For a host running multiple agents across developers, duplicate the service
block per agent. Each agent needs its own:

- `container_name` and `hostname` (e.g. `agent-al-01`, `agent-bo-01`)
- `AGENT_ID` env — matches the slot suffix (`"al-01"`, `"bo-01"`, ...)
- Volume prefix (`agent-al-01-workspace` etc.)
- `env_file` pointing at the owner's per-developer file: `.env.<initials>`
  (containing their `TS_AUTHKEY`, `GITHUB_TOKEN`, etc.)

Multi-agent example (3 developers — Alice, Bob, Carol):

```yaml
services:
  agent-al-01:
    image: ghcr.io/zentoris-labs/ztr-coding-agent:latest
    pull_policy: missing
    container_name: agent-al-01
    hostname: agent-al-01
    restart: unless-stopped
    runtime: sysbox-runc
    env_file: .env.al
    environment: { AGENT_ID: "al-01" }
    volumes:
      - agent-al-01-workspace:/workspace
      - agent-al-01-home:/home/agent
      - agent-al-01-ssh-keys:/etc/ssh/keys
      - agent-al-01-tailscale:/var/lib/tailscale

  agent-bo-01:
    # ... same shape, swap al → bo, .env.al → .env.bo

  agent-ca-01:
    # ... same shape, swap al → ca, .env.al → .env.ca

volumes:
  agent-al-01-workspace: {}
  agent-al-01-home: {}
  agent-al-01-ssh-keys: {}
  agent-al-01-tailscale: {}
  # ... matching entries for agent-bo-01 and agent-ca-01 ...
```

Each agent appears on your tailnet as its own machine (named after its
hostname). No port mapping — access is purely via the tailnet.

This per-host compose lives **on the host** at `/opt/ztr-coding-agent/`. It's
per-host operator state — not committed to this repo. If you want version
control, keep it in a private ops repo.

The per-developer `.env.<initials>` files (with `TS_AUTHKEY`, tokens, etc.)
belong alongside the compose on the host — gitignored, never committed.

### 4. Start the agents and SSH in

```bash
cd /opt/ztr-coding-agent
docker compose up -d
```

From any tailnet-connected client (your laptop, your office desktop, etc.):

```bash
ssh agent@agent-al-01      # MagicDNS resolves to the tailnet IP
```

Use whichever SSH credential is set in the agent's `.env.<initials>`:
`SSH_AUTHORIZED_KEYS` for key auth, or `SSH_PASSWORD` for password auth.
Both are fine here because the underlying network reach is already gated
by your Tailscale identity (and ACLs in your admin console).

Claude Code Desktop's SSH connector: point at hostname `agent-al-01`, user
`agent`. Use password auth (Desktop currently doesn't read IdentityFile
cleanly — see [#25661](https://github.com/anthropics/claude-code/issues/25661)).

## Upgrading sysbox

`SYSBOX_VERSION` is pinned at the top of [bootstrap.sh](bootstrap.sh). To bump:

1. Check [github.com/nestybox/sysbox/releases](https://github.com/nestybox/sysbox/releases)
2. Update `SYSBOX_VERSION`, commit, push
3. On existing hosts: re-run the bootstrap (idempotent)

## Why this shape

- **No public SSH ports** — agents are reachable only on the tailnet. No
  brute-force noise, no exposed sshd, no per-agent host-port assignments
  to track.
- **Two-layer auth** — Tailscale identity gates network reach (managed in
  the Tailscale admin console), then standard sshd (password or key) gates
  shell. Compromising one isn't enough.
- **Works with Claude Code Desktop** — standard sshd means the Desktop SSH
  connector authenticates normally (with password — IdentityFile is buggy
  in Desktop per [#25661](https://github.com/anthropics/claude-code/issues/25661)).
- **One image, one compose template** — no public-vs-private branching.
- **Host shape is operator-chosen** — anything Linux + Tailscale-reachable.
