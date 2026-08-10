# Agent VM — post-launch runbook

Manual steps to take a **freshly launched Multipass agent VM** from "toolchain
only" to "ready to work". The VM image ([`infra/multipass-cloud-init.yaml`](../infra/multipass-cloud-init.yaml))
is pure toolchain and carries **no secrets** — everything credential-shaped is
added here, by hand, per VM.

> Placeholders: `<initials>` = developer initials (e.g. `ch`), `<NN>` = agent
> number (e.g. `04`), `<org>/<repo>` = a repository. The concrete repo list and
> real auth keys are **operator state — keep them in your ops notes, never in
> this public repo** (see [AGENTS.md](../AGENTS.md)).

All commands below run **inside the VM**. Get a shell first (from the host):

```bash
multipass exec ztr-agent-<initials>-<NN> -- bash -l
# or an interactive login shell:  multipass shell ztr-agent-<initials>-<NN>
```

---

## 1. Tailscale — join the tailnet

Use a **reusable** `tag:agent-<initials>` auth key generated in the admin
console (see [docs/tailscale.md § 2](tailscale.md#2-auth-keys)). `--ssh` turns on
Tailscale SSH so your host can reach in.

```bash
sudo tailscale up --ssh --auth-key=tskey-auth-XXXXXXXXXXXX
```

Prefer not to put the key on the command line? Drop it in a file and read from it:

```bash
sudo tailscale up --ssh --auth-key=file:/home/ubuntu/ts.key
```

Verify: `tailscale ip -4` prints a `100.x` address.

## 2. GitHub — authenticate `gh`

Use a scoped, expiring PAT (the agents use scopes `repo`, `read:org`,
`workflow`, plus package/user read as needed).

```bash
gh auth login --with-token < token.txt   # non-interactive
# or interactive:  gh auth login   → GitHub.com → HTTPS → paste a token
gh auth setup-git                         # wire gh in as the git credential helper
```

Verify: `gh auth status` shows the account with `Git operations protocol: https`.

## 3. Git identity — for commits

```bash
git config --global user.name  "<Your Name>"
git config --global user.email "<you@example.com>"
```

## 4. Clone the repos — standard layout `~/src/<org>/<repo>`

The VM mirrors the host layout: everything under `~/src/<org>/`. `gh repo clone`
uses the `gh` auth from step 2, so no extra credentials are needed.

```bash
mkdir -p ~/src/<org>
cd ~/src/<org>
gh repo clone <org>/<repo-a>
gh repo clone <org>/<repo-b>

# If a repo should sit on a non-default branch:
git -C <repo-a> checkout <branch>
```

> The actual set of repos (and their working branches) is deployment state —
> pull it from your ops notes, not from here.

## 5. Verify the box

```bash
node -v          # expect v24.x  (NOT distro v18 — see note below)
which claude     # /usr/bin/claude
tailscale ip -4  # 100.x tailnet address
gh auth status   # logged in, https
ls ~/src/*/*     # cloned repos present
```

There is **no `claude` login step**: Claude Code runs on your **host** and drives
the VM over (Tailscale) SSH, so the VM never needs its own authenticated Claude
session — only the toolchain and tailnet reachability.

---

## Note — NodeSource can silently fail during cloud-init

cloud-init `runcmd` failures do **not** fail the boot (`cloud-init status` still
says `done`). If the NodeSource step didn't take, the VM comes up with Ubuntu's
distro **node 18 and no npm**, so `claude` never installed. If step 5 shows node
v18 or `claude` missing, repair it:

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo bash -
sudo apt-get install -y nodejs
sudo npm install -g --allow-scripts=@anthropic-ai/claude-code @anthropic-ai/claude-code
```
