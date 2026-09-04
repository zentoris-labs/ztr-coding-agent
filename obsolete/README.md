# obsolete/ — retired container-fleet model

These files are the **previous** design: a GHCR Docker image plus
`docker compose` running up to 20 long-lived Claude Code agent **containers** on
a shared host, each joining a **Tailscale** tailnet and reachable over it via
sshd. Cross-developer separation came from per-developer VMs + Tailscale ACLs.

It has been **superseded** by the local single-VM model documented in the
top-level [README](../README.md): one Multipass VM per box, Docker running
natively inside it, NetBird for DNS/reachability, and plain key-based SSH.

Nothing here is wired into the active setup — kept only for reference and easy
revival. The `.github/workflows/` copy is intentionally out of the repo's active
`.github/` tree, so the image build no longer runs.

| File | Was |
|---|---|
| `Dockerfile` | The agent container image (Ubuntu + toolchain + Tailscale + sshd) |
| `docker-compose.yml` | 20 profile-gated agent slots for one developer |
| `.env.example` | Env contract for the compose stack |
| `scripts/entrypoint.sh` | Container PID 1: ssh keys, git creds, tailscaled + sshd, optional dockerd |
| `config/claude/settings.json` | Claude Code defaults baked into the image |
| `infra/bootstrap.sh` | Host bootstrap (Docker + Tailscale + pull image) |
| `infra/vm-dev-setup.sh` | Hyper-V / bare-VM provisioner (native Docker, mDNS) |
| `docs/tailscale.md` | Tailscale ACL + auth-key setup for the fleet |
| `.github/workflows/build-and-push.yml` | CI that built & pushed the GHCR image |
