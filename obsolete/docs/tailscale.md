# Tailscale setup

One-time configuration. Each developer's tailnet identity drives both the
network gate (ACLs decide who can reach whose agents) and the auth keys
used by the bootstrap and the agent containers.

## 1. ACL policy

Open **[login.tailscale.com/admin/acls/file](https://login.tailscale.com/admin/acls/file)** and replace your policy with the template below (adjust `<your-email>` and `<your-initials>`).

```hujson
{
  "tagOwners": {
    "tag:agent-host":             ["autogroup:admin"],
    "tag:agent-<your-initials>":  ["<your-email>"],
    // One line per teammate (see "Onboarding a teammate" below)
  },

  "grants": [
    // Admins reach everything (ops/debugging override)
    { "src": ["autogroup:admin"], "dst": ["*"], "ip": ["*"] },

    // Members reach their own non-tagged devices (laptop ↔ phone)
    { "src": ["autogroup:member"], "dst": ["autogroup:self"], "ip": ["*"] },

    // Each developer reaches only their OWN tagged agents — strict isolation
    { "src": ["<your-email>"], "dst": ["tag:agent-<your-initials>"], "ip": ["*"] },
    // Per-teammate grants added here on onboarding
  ],

  "ssh": [
    // Personal devices (laptop ↔ phone)
    {
      "action": "check",
      "src":    ["autogroup:member"],
      "dst":    ["autogroup:self"],
      "users":  ["autogroup:nonroot", "root"]
    },
    // Admins: Tailscale SSH to host VMs (operator admin)
    {
      "action": "accept",
      "src":    ["autogroup:admin"],
      "dst":    ["tag:agent-host"],
      "users":  ["root", "autogroup:nonroot"]
    }
  ]
}
```

**Why this shape:**
- Each developer's `tag:agent-<initials>` is owned by their email — they can register devices into it via auth keys, nobody else can.
- The single `src → dst` grant per developer means **only that developer can reach their own agents** over the tailnet. Teammates can't even SSH-prompt at someone else's agent because the network isn't reachable.
- Tagged devices (`tag:agent-host`, `tag:agent-*`) have **zero outbound grants** — if a node's tailnet identity is stolen via container compromise, it's inert.
- Admins keep an override (`autogroup:admin → *`) so operators can debug others' setups when needed. This applies to the human user when authenticated as themselves, NOT to tagged devices.

## 2. Auth keys

Open **[login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys)**. Generate two:

| Purpose | Tag | Reusable | Lifetime |
|---|---|---|---|
| **Host VM** | `tag:agent-host` | single-use | 90d ok |
| **Agents** (1-20 slots) | `tag:agent-<your-initials>` | **REUSABLE** | 90d ok |

The host key is consumed during bootstrap. The agent key is shared across all your agent slots (reusable so multiple containers can register with it).

Tailscale only shows each key once — save them in your password manager.

## 3. Onboarding a teammate

Adding `bob@yourdomain.com` (initials `bob`):

1. Invite Bob to the tailnet (Tailscale admin → Users → Invite).
2. Add two lines to the ACL policy:
   ```hujson
   // In tagOwners:
   "tag:agent-bob": ["bob@yourdomain.com"],

   // In grants:
   { "src": ["bob@yourdomain.com"], "dst": ["tag:agent-bob"], "ip": ["*"] },
   ```
3. Bob generates his own auth keys (one `tag:agent-host` single-use, one `tag:agent-bob` reusable).
4. Bob provisions **his own** VM — never co-tenant. He runs the same `infra/bootstrap.sh` + sets `INITIALS=bob` in his `.env`.
5. Bob connects via `ssh agent@agent-bob-01`. ACL ensures other developers (including you) can't reach his agents.

## Verifying the lockdown

After setup, check that tagged devices have zero outbound tailnet grants:

```bash
# From your laptop, with tag:agent-ch:
ssh agent@agent-ch-01
tailscale ping agent-ch-02   # should FAIL — agents can't reach each other
```

If that ping succeeds, you have a stray broad grant in the ACL — search for `"src": ["*"]` or `"src": ["tag:agent-*"]` patterns and remove them.
