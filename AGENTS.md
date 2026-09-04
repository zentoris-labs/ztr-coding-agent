# AGENTS.md

Instructions for AI coding agents (Claude Code, Cursor, Codex, etc.) working
on this repository. Read this first.

## ⚠️ This is a PUBLIC repository

Everything you commit is visible to anyone on the internet, indexed by search
engines, and unchangeable in history. Before any change, run the **commit gate**
at the bottom of this file.

## What this repo is — and isn't

**Is:** the setup for a **local Multipass VM** that runs Claude Code agents on a
developer's own machine, reachable over NetBird by hostname. The whole active
surface is small:

- `infra/provision.sh` — the **single, idempotent source of truth** for the VM
  toolchain (Node, .NET, Python, Go, Java, Docker, NetBird, Claude Code, gh,
  Playwright, dev CLIs). Runs at first boot and is re-run to update existing VMs.
  Pure toolchain — no secrets.
- `infra/multipass-cloud-init.yaml` — thin first-boot config that just fetches and
  runs `provision.sh`.
- `README.md` — the single end-to-end setup guide (launch, NetBird, SSH key, gh,
  clone, verify, updating the toolchain, troubleshooting).

**Security model:** the **VM is the trust boundary**. Docker runs natively inside
it and the agent is root-equivalent there — fine, because one developer owns the
box and there's nothing else on it to protect. NetBird is only the network + DNS
layer; SSH is plain OpenSSH + the developer's key.

**Is not:**
- Application code, business logic, or domain models — those live in private
  product repos. If you're tempted to port them here, you're in the wrong repo.
- A secrets store — no credentials, setup keys, or SSH keys belong in the tree.
- Per-host operator state — specific IPs, hostnames, developer names, repo lists,
  who-runs-where. Those live ON the host or in a private ops repo.
- Customer data or anything that could embarrass the project or its customers.

> **`obsolete/`** holds the previous **container-fleet** model (a GHCR image +
> `docker compose` of Tailscale-networked agent containers). It's retired and not
> wired into anything — don't extend it, and don't let its patterns leak back
> into the active setup. See [obsolete/README.md](obsolete/README.md).

## 🔒 Security boundaries — never commit any of this

**Hard prohibitions:**

| Category | Examples | Why |
|---|---|---|
| **Secrets** | API tokens (`GITHUB_TOKEN`, `ANTHROPIC_API_KEY`), passwords, SSH **private** keys, NetBird **setup keys**, OAuth secrets, DB URLs with creds | Public repo = world-readable forever |
| **Keys in the cloud-init** | A real `ssh_authorized_keys` value, a baked setup key — the cloud-init must stay **key-free** | It's the one committed, world-readable config |
| **Business logic** | Code copied from internal product repos, proprietary algorithms | Wrong repo. This is tooling. |
| **Per-host operator state** | Specific IPv4/IPv6 addresses, hostnames, developer-to-VM maps, cloud account IDs, `~/.ssh/config` entries | Belongs on the host or in private ops state |
| **Personal identifying info** | Developer real names (placeholder initials like `ch`/`al`/`bob` are fine), personal SSH **public** keys | Privacy and onboarding-leak concerns |
| **Customer / partner data** | Names, identifiers, config specific to a customer | Self-evident |

**Before every commit, mentally answer:**
1. "If a competitor / attacker reads this diff, can they do anything useful?" If yes → don't commit.
2. "Is anything in this diff specific to my deployment, my dev machine, or my team?" If yes → generalize or move it out.
3. "Does this contain anything that should be in a private ops repo or a vault?" If yes → put it there instead.

If you discover a secret already in git history, **stop**. Tell the human operator immediately. Rotation + history rewrite (force-push) is required; do not try to clean it up silently.

## Architecture overview

```
ztr-coding-agent/
├── infra/provision.sh                # idempotent toolchain installer — source of truth
├── infra/multipass-cloud-init.yaml   # first-boot config: fetches + runs provision.sh
├── README.md                         # the single VM setup guide
├── AGENTS.md / CLAUDE.md             # instructions for AI agents on this repo
├── .claude/settings.json             # project-level Claude Code settings (for contributors)
└── obsolete/                         # retired container-fleet model — reference only
```

**Deployment model** (manual, in [README.md](README.md)): one developer launches
one Multipass VM per box with the cloud-init, then adds credentials/keys by hand
after launch (NetBird join, SSH public key, `gh auth`). Everything that varies
per host/operator lives outside this repo.

## Conventions

- **In-VM user:** `ubuntu` (Multipass default), in the `docker` group. There is
  **no `claude` login inside the VM** — Claude Code runs on the *host* and drives
  the VM over SSH.
- **Networking:** NetBird for DNS + reachability only (no `--allow-server-ssh`).
  SSH is plain OpenSSH + the developer's **default** key (`~/.ssh/id_ed25519`);
  the public key is pushed to the VM post-launch, never baked into the image.
- **Line endings:** **LF everywhere**, enforced by `.gitattributes` — the
  cloud-init and any scripts run inside a Linux VM.
- **Commit attribution:** the project-level setting strips the
  `Co-Authored-By: Claude` trailer (see `.claude/settings.json`). Don't add it back.
- **Placeholders in examples:** initials `ch`/`al`/`bob`, `<org>/<repo>`,
  `XXXXXXXX-…` for setup keys — never real values.

## Common pitfalls — things to avoid

1. **Keep the cloud-init key-free and secret-free.** It's the one committed,
   world-readable config. SSH keys and setup keys are added by hand after launch.
2. **Don't conflate "image" and "operator state".** The cloud-init is uniform
   across deployments. Which VMs run, for which developers, with which keys — that's
   per-host operator state and doesn't belong in this repo.
3. **Don't reach for NetBird's identity-aware SSH (`--allow-server-ssh`).** It
   isn't transparent for Windows `ssh` clients; the model is NetBird-for-DNS + key
   auth. See the README troubleshooting section for the history.
4. **Don't extend `obsolete/`** or revive the container/Tailscale/`privileged`
   patterns. If a change seems to need them, you're probably in the wrong model.
5. **Don't add Pulumi / Terraform yet.** The manual flow handles a handful of
   local VMs cleanly.
6. **Don't hardcode specific repo names, hostnames, or developer identifiers.**

## Validating changes

There's no build. For a toolchain change:

- **Lint the script** — `shellcheck infra/provision.sh` (it's the main surface now).
- **Lint the YAML** (`cloud-init schema --config-file infra/multipass-cloud-init.yaml`
  if you have cloud-init locally, or any YAML linter).
- **Smoke test** by launching a throwaway VM:
  `multipass launch 24.04 --name ztr-smoke --cloud-init infra/multipass-cloud-init.yaml`,
  then `multipass exec ztr-smoke -- cloud-init status --wait` and spot-check the
  toolchain (`node -v`, `which claude`, `docker run --rm hello-world`). Delete it
  after: `multipass delete --purge ztr-smoke`.

## Commit gate (run before every commit)

```bash
# 1. Anything secret-shaped slipped in?
git diff --cached | grep -Ei '(token|secret|password|api[_-]?key|private[_-]?key|setup[_-]?key|BEGIN [A-Z]+ PRIVATE KEY)' \
    && echo "⚠️  suspicious lines — review before committing"

# 2. A real SSH public key baked into the cloud-init?
git diff --cached -- infra/ | grep -E 'ssh-(ed25519|rsa) AAAA' \
    && echo "⚠️  looks like a real SSH key — the cloud-init must stay key-free"

# 3. Specific IPv4 addresses (not in obvious placeholders / examples)?
git diff --cached | grep -E '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
    && echo "⚠️  IP addresses found — make sure they're placeholders"

# 4. Real names that shouldn't be in a public repo?
#    Replace the pattern below with names that shouldn't appear publicly.
NAME_REGEX='\b(yourname|teammate1|teammate2)\b'
git diff --cached | grep -Ei "$NAME_REGEX" \
    && echo "⚠️  potential identifying info"
```

These greps are heuristics, not a guarantee. The mental check (questions 1–3 in the security boundaries section above) is the actual gate. Use these as a tripwire.

## Pointers

- **Source:** [`github.com/zentoris-labs/ztr-coding-agent`](https://github.com/zentoris-labs/ztr-coding-agent) (public)
- **Claude Code docs:** [docs.claude.com/claude-code](https://docs.claude.com/claude-code/overview)
- **NetBird docs:** [docs.netbird.io](https://docs.netbird.io)
- **AGENTS.md convention:** [agents.md](https://agents.md)
