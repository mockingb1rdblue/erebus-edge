# erebus-edge

Connect from a hostile corporate Windows environment to your home machine and
Tailscale network — no admin, no VPN, no IT ticket.

```
Work machine (no admin, corporate proxy)
  |
  |--> Browser --> ssh.SUB.workers.dev --> CF Access (email OTP)
  |     --> CF browser-rendered SSH terminal (no ttyd, no extra software)
  |     --> Short-lived SSH certificates (no static keys)
  |
  |--> CLI SSH --> cloudflared ProxyCommand --> CF Tunnel --> home SSH
  |
  `--> bin/tsnet.exe (userspace Tailscale, no admin)
        --> any Tailscale peer via DERP relay
```

**Why it works on corporate networks:** `*.workers.dev` is in `no_proxy` on most
managed Windows machines. Traffic goes direct to Cloudflare's edge without hitting the
corporate proxy or SSL inspection.

---

## Requirements

- Python 3.11+ (user install — no admin, from [python.org](https://python.org))
- A [Cloudflare account](https://dash.cloudflare.com/sign-up) (free tier is fine)
- `bin/cloudflared.exe` — download from [github.com/cloudflare/cloudflared/releases](https://github.com/cloudflare/cloudflared/releases), place in `bin/`

---

## Setup (one time)

### 1. Work machine

```
python bootstrap.py --email you@example.com
```

This opens your browser to log in to Cloudflare, then automatically:

- Creates a scoped API token
- Creates a Cloudflare Tunnel
- Deploys Workers: `ssh`, `portal`, `ts-relay`
- Sets up CF Zero Trust Access with email OTP
- Creates an SSH-type Access app (browser-rendered SSH terminal)
- Generates a short-lived certificate CA (no static SSH keys needed)
- Downloads portable Go and builds `bin/tsnet.exe` (userspace Tailscale)
- Saves config to `keys/portal_config.json`
- Prints the exact command to run on your home machine

Flags for re-running later:

| Flag | Purpose |
|------|---------|
| `--redeploy` | Re-deploy all Workers + rebuild tsnet |
| `--build-tsnet` | Only rebuild tsnet binary |
| `--skip-tsnet` | Skip Go download + build (CF Tunnel only) |
| `--skip-access` | Skip CF Zero Trust Access |

### 2. Home machine (any OS)

Copy the command printed by `bootstrap.py` and run it on your home machine.
It works on **Linux, macOS, and Windows** — only Python 3 needed.

```bash
python3 home_setup.py \
    --token <TUNNEL_TOKEN> \
    --ssh-host ssh.SUB.workers.dev \
    --ssh-ca-key 'ecdsa-sha2-nistp256 AAAA...'
```

What `home_setup.py` does:
- Downloads `cloudflared` if missing
- Runs `cloudflared service install` (native cross-platform service registration)
- Configures sshd to trust CF's SSH CA (enables short-lived certificates)
- Restarts sshd
- Verifies the tunnel is connected

No ttyd. No extra daemons. Just cloudflared + sshd.

---

## Daily use

### Option A — Browser SSH (CF Access)

Visit `https://ssh.SUB.workers.dev` in your browser.

1. Authenticate via email OTP (or configured identity provider)
2. Browser-rendered SSH terminal opens automatically
3. CF generates a short-lived certificate for your session — no SSH keys needed

### Option B — CLI SSH (CF Tunnel)

```bash
./connect.sh      # Git Bash / Mac / Linux
connect.bat       # Windows cmd
```

First run asks for your home username and SSH port, saves to `cf_config.txt`.

### Option C — Tailscale (tsnet)

Connect to any peer on your Tailscale network:

```
bin\tsnet.exe up          # connect + auth
bin\tsnet.exe status      # list peers
ssh -o "ProxyCommand=bin\tsnet.exe proxy %h %p" user@peer
```

> **Note:** tsnet requires `controlplane.tailscale.com` to be reachable. Networks
> with deep-packet inspection (DPI) that actively block Tailscale will prevent this.
> Use Options A/B (CF Tunnel) as the reliable fallback.

---

## Files

| File | Purpose |
|------|---------|
| `bootstrap.py` | First-run wizard — run this first |
| `home_setup.py` | Cross-platform home machine setup (Mac, Linux, Windows) |
| `config.py` | Shared config loader (`keys/portal_config.json`) |
| `connect.bat` / `connect.sh` | CLI SSH via CF Tunnel |
| `portal.bat` / `portal.py` | Python CLI portal (CF Tunnel + Tailscale) |
| `setup_cf_access.py` | CF Zero Trust Access + SSH CA setup |
| `deploy_portal_worker.py` | Re-deploy portal Worker |
| `deploy_ts_relay_worker.py` | Re-deploy Tailscale relay Worker |
| `cf_creds.py` | DPAPI-encrypted CF token storage |
| `tsnet-src/` | Go source for `bin/tsnet.exe` (built by bootstrap.py) |

`keys/` and `cf_config.txt` are gitignored — generated locally by `bootstrap.py`.

---

## Security

- **No static SSH keys** — CF generates short-lived certificates per session
- **Email OTP gate** — CF Access requires identity verification before SSH
- **Origin-side JWT validation** — cloudflared validates Access JWT on the home machine
- **DPAPI encryption** — CF API token encrypted at rest (tied to Windows login)
- **No admin required** — everything runs in userspace on the work machine
- All secrets in `keys/` (gitignored): CF token, tunnel token, SSH CA key, tsnet state

---

## Third-party tools

- **cloudflared** — [github.com/cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) — Apache 2.0
- **tailscale/tsnet** — [github.com/tailscale/tailscale](https://github.com/tailscale/tailscale) — BSD 3-Clause

Cloudflare Workers, Tunnels, and Access are subject to [Cloudflare's Terms of Service](https://www.cloudflare.com/terms/).
Tailscale services are subject to [Tailscale's Terms of Service](https://tailscale.com/terms).
