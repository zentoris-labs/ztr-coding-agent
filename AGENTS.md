# AGENTS.md

Instructions for AI coding agents (Claude Code, Cursor, Codex, etc.) working
on this repository. Read this first.

## ⚠️ This is a PUBLIC repository

Everything you commit is visible to anyone on the internet, indexed by search
engines, and unchangeable in history. Before any change, run the **commit gate**
at the bottom of this file.

## What this repo is — and isn't

**Is:**
- A Docker image definition (`Dockerfile`, `scripts/entrypoint.sh`, baked Claude Code defaults). Includes Tailscale + sshd so each agent container joins the tailnet and accepts SSH only over it.
- A host bootstrap script (`infra/bootstrap.sh`) that installs Docker + Tailscale on a Linux host
- Canonical compose template (`docker-compose.yml`) — defines 20 agent slots for one developer with cumulative Compose profiles (`COMPOSE_PROFILES=<N>` → run N agents); each runs `privileged: true`
- CI (`.github/workflows/build-and-push.yml`) that publishes the image to GHCR

**Security model:** **per-host isolation**. The VM is the trust boundary;
agents within a single VM share trust (all owned by one developer). Cross-
developer separation comes from running each developer on their own VM +
Tailscale ACLs — never co-tenant different people on one VM.

**Is not:**
- Application code, business logic, or domain models — those live in private product repos. If you're tempted to port them here, you're in the wrong repo.
- A secrets store — `.env` is gitignored; `.env.example` carries placeholders only.
- Per-host operator state — specific IPs, hostnames, port assignments, developer names, who-runs-where. Those live ON the host or in a private ops repo.
- Customer data, identifying information, or anything that could embarrass the project owner or its customers if disclosed.

## 🔒 Security boundaries — never commit any of this

**Hard prohibitions:**

| Category | Examples | Why |
|---|---|---|
| **Secrets** | API tokens (`GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, etc.), passwords, SSH **private** keys, OAuth client secrets, database URLs with credentials, signing keys, anything from `.env` | Public repo = world-readable forever |
| **Business logic** | Code copied from internal product repos, proprietary algorithms, customer-specific workflows | Wrong repo. This is tooling. |
| **Per-host operator state** | Specific IPv4/IPv6 addresses, hostnames, port-to-developer maps, specific cloud account IDs, ssh `~/.ssh/config` entries | Belongs on the host or in private ops state |
| **Personal identifying info** | Developer real names in code (placeholder initials like `ch`/`al`/`bob` are fine for examples), email addresses other than generic role addresses, personal SSH **public** keys | Privacy and onboarding-leak concerns |
| **Customer / partner data** | Names, identifiers, configuration specific to a customer | Self-evident |
| **Vendor-specific defaults** | "Generate token at this URL with these scopes for **our** org" — make examples generic | Doesn't generalize, leaks deployment shape |

**Before every commit, mentally answer:**
1. "If a competitor / attacker reads this diff, can they do anything useful?" If yes → don't commit.
2. "Is anything in this diff specific to my deployment, my dev machine, or my team?" If yes → generalize or move it out of the repo.
3. "Does this contain anything that should be in `.env`, in a private ops repo, or in a vault?" If yes → put it there instead.

If you discover a secret already in git history, **stop**. Tell the human operator immediately. Rotation + history rewrite (force-push) is required; do not try to clean it up silently.

## Architecture overview

```
ztr-coding-agent/
├── Dockerfile                       # image: Ubuntu 24.04 + .NET 10 + Node 22 + Python 3.12 + Claude Code + gh + Docker + Tailscale + sshd
├── scripts/entrypoint.sh            # runtime: SSH host keys, authorized_keys, env propagation, git creds, optional Docker, optional repo clones, tailscaled + sshd
├── config/claude/settings.json      # baked Claude Code defaults (model, effort, telemetry off)
├── docker-compose.yml               # 20 agent slots (cumulative profile-gated) for one developer; `privileged: true` baked in
├── .env.example                     # full env contract — every variable documented
├── infra/bootstrap.sh               # idempotent host setup (Docker CE + Tailscale)
├── docs/tailscale.md                # Tailscale ACL + auth keys (one-time setup)
├── docs/agent-vm-setup.md           # Multipass agent VM post-launch runbook (Tailscale, gh, repo clone)
├── .github/workflows/build-and-push.yml  # CI → ghcr.io/zentoris-labs/ztr-coding-agent
├── .claude/settings.json            # project-level Claude Code settings (for contributors)
└── README.md                        # project overview
```

**Deployment model** (manual, in [README.md](README.md)):
1. Operator creates a Linux VM **per developer** (CPX22 for ≤2 agents, CPX32 for 3+)
2. Operator runs `infra/bootstrap.sh` on the VM (installs Docker + Tailscale)
3. Operator drops a single `.env` on the VM (copy of `.env.example`) with `INITIALS=<theirs>`, `COMPOSE_PROFILES=<N>` (cumulative count of agents to run), and secrets; `docker-compose.yml` defines 20 slots with `${INITIALS}` interpolation — no further edits required
4. `docker compose up -d`; each agent joins the tailnet; access via `ssh agent@agent-<initials>-<NN>` (resolves via Tailscale MagicDNS)

The image is the same for every deployment; everything that varies per host/operator/agent lives outside this repo.

## Conventions

- **In-container user:** `agent` (UID/GID 1001). Passwordless sudo, member of `docker` group. **NOT** `claude` — the username is generic; Claude Code happens to run as that user.
- **Workspace:** `/home/agent/` (per-agent named volume; auto-cloned repos land here as subdirs)
- **Claude Code settings location:** `/home/agent/.claude/settings.json` (Claude Code's own convention, baked from `config/claude/settings.json`)
- **SSH access:** standard sshd on container port 22, reachable ONLY via Tailscale (each agent joins the tailnet as `agent-<owner>-<NN>`). No public ports mapped on the host. Two-layer security: Tailscale identity gates network reach; SSH password/key gates shell. Password auth (`SSH_PASSWORD`) is acceptable here because the network layer is already authenticated — it would NOT be acceptable on a public-internet sshd.
- **Line endings:** **LF everywhere**, enforced by `.gitattributes`. Shell scripts and Dockerfile break if saved as CRLF inside a Linux container.
- **Commit attribution:** project-level setting strips the `Co-Authored-By: Claude` trailer (see `.claude/settings.json`). Don't add it back.
- **Image source:** `ghcr.io/zentoris-labs/ztr-coding-agent:latest`. Public. `pull_policy: missing` lets a local `docker compose build` override the published image for dev.

## Common pitfalls — things to avoid

1. **Don't depend on private-repo URL fetches.** The repo is public; if it ever flips private, GitHub `raw.githubusercontent.com` URLs 404 anonymously. If you're tempted to embed a PAT to work around this, you're solving the wrong problem.
2. **Don't conflate "image" and "operator state".** The image is uniform across all deployments. Which agents run, on which ports, for which developers, with which secrets — that's per-host operator state. Doesn't belong in this repo.
3. **Don't try to isolate agents from each other within a VM.** The model is per-host isolation: one developer per VM, agents inside run `privileged: true` because the VM is already the trust boundary. If you find yourself reaching for sysbox-runc, gVisor, or per-agent user namespaces, you're solving a problem that doesn't exist in this model. Different developers go on different VMs, full stop.
4. **Don't add Pulumi / Terraform / OpenTofu yet.** Manual flow + bootstrap script handles 1–3 hosts cleanly. Real IaC is justified when drift detection, multi-environment promotion, or per-developer self-service becomes valuable (~10+ hosts).
5. **Don't reintroduce per-agent permanent branches.** Each agent has its own home volume (`/home/agent/`); per-task feature branches are the model. The old `agent-<owner>-<NN>`-permanent-branch sketch was scrapped.
6. **Don't hardcode specific repo names, hostnames, or developer identifiers in examples.** Use placeholder initials (`ch` / `al` / `bob`).

## Build / test loop

- **Local rebuild:** `docker compose build`
- **Quick smoke test:** `docker compose up -d` then `docker logs agent-xx-01` — expect the entrypoint stages + `tailnet hostname: agent-xx-01`.
- **Full validation:** requires a Linux host (or WSL2) where `privileged: true` actually works for the in-container dockerd. Hetzner Ubuntu 24.04 + this repo's bootstrap is the canonical setup.
- **CI:** every push to `main` triggers `.github/workflows/build-and-push.yml`. Watch with `gh run watch`. Green build = canonical confirmation.

## When you make changes

For any non-trivial change:

1. **`docker compose build`** locally and read entrypoint logs from `docker logs agent-xx-01` to confirm nothing regressed.
2. **Hunt for stale `claude` user references** — `grep -rn '\bclaude\b' .` should only return:
   - Claude Code product references in comments (`# Claude Code`)
   - Package name (`@anthropic-ai/claude-code`)
   - Settings file locations (`.claude/settings.json`, `config/claude/`)
   - Model name (`claude-opus-4-7[1m]`)
   - This file (AGENTS.md) and CLAUDE.md
3. **Verify no Zentoris-specific defaults leaked** — check `.env.example` and any new example files for org-specific values.
4. **If the Dockerfile / entrypoint changed**, push and watch GitHub Actions. A red CI build means don't merge.

## Commit gate (run before every commit)

```bash
# 1. Anything secret-shaped slipped in?
git diff --cached | grep -Ei '(token|secret|password|api[_-]?key|private[_-]?key|BEGIN [A-Z]+ PRIVATE KEY)' \
    && echo "⚠️  suspicious lines — review before committing"

# 2. Specific IPv4 addresses (not in obvious placeholders / examples)?
git diff --cached | grep -E '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
    && echo "⚠️  IP addresses found — make sure they're placeholders"

# 3. Real names that shouldn't be in a public repo?
#    Replace the pattern below with the names of contributors who shouldn't
#    appear in a public commit (e.g. real first names, internal handles).
NAME_REGEX='\b(yourname|teammate1|teammate2)\b'
git diff --cached | grep -Ei "$NAME_REGEX" \
    && echo "⚠️  potential identifying info"
```

These greps are heuristics, not a guarantee. The mental check (questions 1–3 in the security boundaries section above) is the actual gate. Use these as a tripwire.

## Pointers

- **Image:** `ghcr.io/zentoris-labs/ztr-coding-agent` (public)
- **Source:** [`github.com/zentoris-labs/ztr-coding-agent`](https://github.com/zentoris-labs/ztr-coding-agent) (public)
- **Claude Code docs:** [docs.claude.com/claude-code](https://docs.claude.com/claude-code/overview)
- **AGENTS.md convention:** [agents.md](https://agents.md)
