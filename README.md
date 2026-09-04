# ztr-coding-agent

Set up a **local [Multipass](https://multipass.run) VM** as a disposable
[Claude Code](https://claude.com/claude-code) dev box, reachable from your host
over [NetBird](https://netbird.io) by name (`ztr-agent-<initials>-<NN>`).

**The model:**

- **One VM per box, on your own machine.** Docker runs *natively* inside the VM;
  the default `ubuntu` user is in the `docker` group. The VM is the trust
  boundary — there's nothing else on it to protect from the agent.
- **NetBird is only the network + DNS layer.** It gives each VM a stable hostname
  that resolves from your host and an encrypted path to it. SSH itself is plain
  OpenSSH + your key — *not* NetBird's identity-aware SSH (that isn't transparent
  for Windows `ssh` clients).
- **Claude Code runs on your host** and drives the VM over SSH. There is **no
  `claude` login inside the VM** — only the toolchain + NetBird reachability.
- **The cloud-init ([`infra/multipass-cloud-init.yaml`](infra/multipass-cloud-init.yaml))
  is pure toolchain** — no secrets. Everything credential-shaped is added by hand
  after launch (below), so the file is safe to commit.

> The older **container-fleet** model (a GHCR image + `docker compose` running 20
> agent containers behind Tailscale) has been retired to [`obsolete/`](obsolete/).
> This README describes the current local-VM model only.

---

## Prerequisites

- **Multipass** on your host (`winget install Canonical.Multipass` on Windows).
- A **NetBird Cloud** account — [app.netbird.io](https://app.netbird.io).
- An **SSH keypair** on your host. Check / create the default one:

  ```powershell
  Test-Path $env:USERPROFILE\.ssh\id_ed25519.pub    # if False:
  ssh-keygen -t ed25519 -C "you@host"               # press Enter for no passphrase
  ```

  One keypair identifies *you* and is trusted by every VM — "multiple VMs" does
  **not** mean multiple keys. The default name (`id_ed25519`) means `ssh` finds it
  automatically, with no `IdentityFile`/`-i` to manage.

---

## Quick start

> Placeholders: `<initials>` = your initials (e.g. `ch`), `<NN>` = agent number
> (e.g. `01`), `<org>/<repo>` = a repository. Real repo lists and auth keys are
> **operator state — keep them in your ops notes, never in this public repo**
> (see [AGENTS.md](AGENTS.md)).

### 1. Launch the VM (run on the host)

```powershell
multipass launch 24.04 --name ztr-agent-<initials>-<NN> --cpus 4 --memory 8G --disk 60G --cloud-init infra/multipass-cloud-init.yaml
multipass exec ztr-agent-<initials>-<NN> -- cloud-init status --wait   # block until provisioning is done
```

### 2. Add your SSH key (run on the host)

Push your **public** key into the VM's `authorized_keys` — idempotent, and it
does all your VMs at once:

```powershell
$pub = (Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub -Raw).Trim()
$vms = (multipass list --format csv | ConvertFrom-Csv | Where-Object { $_.Name -like 'ztr-agent-*' }).Name
foreach ($vm in $vms) {
    multipass exec $vm -- bash -c "mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; grep -qxF '$pub' ~/.ssh/authorized_keys || printf '%s\n' '$pub' >> ~/.ssh/authorized_keys"
}
```

Optional convenience — add to `~/.ssh/config` on the host so you can drop the
`ubuntu@`:

```
Host ztr-agent-*
    User ubuntu
```

### 3. Join NetBird for DNS + reachability (run in the VM)

Get a shell (`multipass shell ztr-agent-<initials>-<NN>`), then join with a
**reusable** setup key (see [NetBird setup](#netbird-setup) for how to make one):

```bash
sudo netbird up --setup-key=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
netbird status      # Management: Connected, shows a NetBird IP (100.x)
```

Prefer to keep the key off the command line?

```bash
read -rs SETUP_KEY            # paste it; input is not echoed
sudo netbird up --setup-key="$SETUP_KEY"
unset SETUP_KEY
```

The VM now resolves as `ztr-agent-<initials>-<NN>` from your host, so
`ssh ubuntu@ztr-agent-<initials>-<NN>` logs you straight in with your key.

### 4. Authenticate `gh` (run in the VM)

Use a scoped, expiring PAT (scopes `repo`, `read:org`, `workflow`, plus
package/user read as needed):

```bash
gh auth login --with-token < token.txt   # non-interactive
# or interactive:  gh auth login  → GitHub.com → HTTPS → paste a token
gh auth setup-git                         # wire gh in as the git credential helper
```

### 5. Git identity (run in the VM)

```bash
git config --global user.name  "<Your Name>"
git config --global user.email "<you@example.com>"
```

### 6. Clone your repos (run in the VM)

Standard layout mirrors the host: everything under `~/src/<org>/`.

```bash
mkdir -p ~/src/<org> && cd ~/src/<org>
gh repo clone <org>/<repo-a>
git -C <repo-a> checkout <branch>   # if it should sit on a non-default branch
```

### 7. Verify

```bash
node -v          # expect v24.x  (NOT distro v18 — see Troubleshooting)
which claude     # /usr/bin/claude
netbird status   # Management: Connected, NetBird IP (100.x)
gh auth status   # logged in, https
ls ~/src/*/*     # cloned repos present
```

---

## NetBird setup

NetBird is used **only for DNS + reachability** here; SSH is key-based (step 2).

### Setup keys

[app.netbird.io](https://app.netbird.io) → **Setup Keys → Create Setup Key**:

| Field | Value |
|---|---|
| **Name** | `agent-<initials>` |
| **Reusable** | **Yes** — one key registers all your agent VMs |
| **Expiration** | 90d is fine; rotate on schedule |
| **Ephemeral** | optional — auto-removes a VM from the peer list once it's offline (handy for disposable boxes) |

NetBird shows the key once — save it in your password manager. This is the key
you paste into `netbird up --setup-key=…` in step 3.

For a **single developer**, that's all you need: NetBird Cloud's default policy
lets your own peers reach each other, and everything on the network is yours.

### Optional — isolating teammates on the same account

Skip unless more than one person shares the NetBird account.

1. **Kill the default allow-all.** A fresh network ships a **Default** policy
   allowing `All → All`. Disable or delete it, or everyone reaches everything.
2. **Peers → Groups:** create `agent-<initials>` (your VMs — set it as the setup
   key's *auto-assign group*) and `<initials>-devices` (your own laptop/phone).
3. **Access Control → Policies:** add `<initials>-access` allowing
   `<initials>-devices → agent-<initials>`.

With the default gone and no policy between agent groups, agents can't reach each
other and teammates can't reach yours. Each teammate provisions **their own** VMs
(never co-tenant) with their own setup key and group.

---

## Troubleshooting

### `node -v` shows v18, or `claude` is missing

cloud-init `runcmd` failures don't fail the boot (`cloud-init status` still says
`done`). If the NodeSource step didn't take, the VM comes up with Ubuntu's distro
node 18 and no npm, so `claude` never installed. Repair, in the VM:

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash -
sudo apt-get install -y nodejs
sudo npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code
```

### `REMOTE HOST IDENTIFICATION HAS CHANGED` after relaunching a VM

A fresh VM gets new SSH host keys, so your cached entry no longer matches. Remove
the stale one on the host (you're the *client*; don't regenerate anything):

```powershell
ssh-keygen -R ztr-agent-<initials>-<NN>
```

Then reconnect and accept the new key (verify the fingerprint against the VM via
`multipass shell … ` + `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` if in doubt).

### Migrating a VM that's still on Tailscale

Migrate **in place**, from a local console (`multipass shell <vm>`) — keep
Tailscale up until key-based SSH over NetBird is proven, and make sure your public
key is already in the VM's `authorized_keys` (step 2):

```bash
curl -fsSL https://pkgs.netbird.io/install.sh | sh     # idempotent; starts the netbird daemon
sudo netbird up --setup-key=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
netbird status
# confirm `ssh ubuntu@<hostname>` works over NetBird from the host, THEN:
sudo tailscale down && sudo tailscale logout
sudo apt-get remove -y tailscale                       # optional
```

NetBird and Tailscale coexist while both are up (separate interfaces `wt0` vs
`tailscale0`), which is what makes the keep-both-until-proven cutover safe.

---

## Layout

```
infra/multipass-cloud-init.yaml   # the VM image: pure toolchain (Node, .NET, Docker, Claude Code, gh, NetBird)
README.md                         # this file — the full VM setup guide
AGENTS.md / CLAUDE.md             # instructions for AI agents working on this repo
obsolete/                         # retired container-fleet model (Dockerfile, compose, entrypoint, CI, Tailscale docs)
```

## Trust model

The VM is the security boundary; your host is protected by the VM boundary. Inside
the VM the agent has Docker socket access (root-equivalent) — intended. So put
**only scoped, revocable credentials** in it (a repo-scoped git token, a
least-priv cloud role) — **never** your host admin sessions, and never log into an
admin console from inside the VM. See [AGENTS.md](AGENTS.md) for the full
conventions and the pre-commit gate.
