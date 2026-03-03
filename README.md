# erebus-edge

Connect from a hostile corporate Windows environment to your home machine and
Tailscale network — no admin, no VPN, no IT ticket.

```
Work machine (no admin, corporate proxy)
  │
  ├─► bin/tsnet.exe  (userspace Tailscale — no WinTun, no admin)
  │     ↓  HTTPS to ts-relay.SUB.workers.dev  (in no_proxy → bypasses everything)
  │     CF relay Worker proxies Tailscale control plane + DERP over WebSocket
  │     ↓  Tailscale DERP relay
  │     └─► any Tailscale peer: SSH, mosh, anything TCP
  │
  └─► cloudflared ProxyCommand → ssh.SUB.workers.dev → CF Tunnel → home SSH
      browser → term.SUB.workers.dev → CF Tunnel → ttyd (web terminal)
```

**Why it works on corporate networks:** `*.workers.dev` is in `no_proxy` on most
managed Windows machines. Traffic goes direct to Cloudflare's edge without hitting the
corporate proxy or SSL inspection. This applies to both the CF Tunnel SSH path AND the
Tailscale control plane / DERP relay.

---

## Requirements

- Python 3.11+ (user install — no admin, from [python.org](https://python.org))
- A [Cloudflare account](https://dash.cloudflare.com/sign-up) (free tier is fine)
- `bin/cloudflared.exe` — download from [github.com/cloudflare/cloudflared/releases](https://github.com/cloudflare/cloudflared/releases), place in `bin/`

---

## Setup (one time)

### 1. Work machine

```
python bootstrap.py
```

This opens your browser to log in to Cloudflare, then automatically:

- Creates a scoped API token (no manual copy-paste)
- Creates a Cloudflare Tunnel
- Deploys four Workers: `ssh`, `portal`, `term`, `ts-relay`
- Sets up CF Zero Trust Access with email OTP (optional)
- Downloads portable Go and builds `bin/tsnet.exe` (userspace Tailscale)
- Saves config to `keys/portal_config.json`

At the end, `bootstrap.py` prints the exact command to run on your home machine.

Flags for re-running later:

| Flag | Purpose |
|------|---------|
| `--redeploy` | Re-deploy all Workers + rebuild tsnet |
| `--build-tsnet` | Only rebuild tsnet binary |
| `--skip-tsnet` | Skip Go download + build (CF Tunnel only) |
| `--skip-access` | Skip CF Zero Trust Access |

### 2. Home machine (any OS)

Copy the command printed by `bootstrap.py` and run it on your home machine.
It works on **Linux, macOS, and Windows** — no dependencies beyond Python 3.

**Linux / macOS:**
```bash
python3 home_setup.py --token <TOKEN> \
    --portal-url https://portal.SUB.workers.dev \
    --term-url   https://term.SUB.workers.dev \
    --ssh-host   ssh.SUB.workers.dev
```

**Windows (PowerShell):**
```powershell
python home_setup.py --token <TOKEN> `
    --portal-url https://portal.SUB.workers.dev `
    --term-url   https://term.SUB.workers.dev `
    --ssh-host   ssh.SUB.workers.dev
```

**Linux only (bash, simpler):**
```bash
bash home_setup.sh <TOKEN>
```

What `home_setup.py` does:
- Downloads and installs `cloudflared` if missing
- Downloads and installs `ttyd` if missing (Mac/Linux only; no Windows binary available)
- Starts both services immediately
- Registers auto-start (launchd on Mac, systemd on Linux, Startup folder on Windows)
- Verifies the CF Tunnel endpoint is reachable

---

## Daily use

### Option A — Tailscale (tsnet)

Connect to any peer on your Tailscale network:

```
bin\tsnet.exe up          # connect + auth (opens browser or phone URL)
bin\tsnet.exe status      # list peers as JSON
```

SSH to a peer:
```
ssh -o "ProxyCommand=bin\tsnet.exe proxy %h %p" user@peer-hostname
```

Or add to `~/.ssh/config`:
```
Host *.ts.net
    ProxyCommand C:\path\to\bin\tsnet.exe proxy %h %p
```

On first run, Tailscale auth is required. A URL will be printed — open it in
your browser (use your phone if the desktop browser is blocked).

> **Note:** tsnet requires `controlplane.tailscale.com` to be reachable. Networks
> with deep-packet inspection (DPI) that actively block Tailscale will prevent this.
> Use Option B (CF Tunnel) as the reliable fallback.

### Option B — Browser portal (CF Tunnel)

```
https://portal.SUB.workers.dev
```

Log in with your CF API token → add endpoint (set Terminal URL to
`https://term.SUB.workers.dev`) → Connect.

### Option C — CLI SSH (CF Tunnel)

```bash
./connect.sh      # Git Bash / Mac / Linux
connect.bat       # Windows cmd
```

First run asks for your home username and SSH port, saves to `cf_config.txt`.

---

## Files

| File | Purpose |
|------|---------|
| `bootstrap.py` | First-run wizard — run this first |
| `config.py` | Shared config loader (`keys/portal_config.json`) |
| `connect.bat` / `connect.sh` | CLI SSH via CF Tunnel |
| `portal.bat` / `portal.py` | Python CLI portal (CF Tunnel + Tailscale) |
| `home_setup.py` | Cross-platform home machine setup (Mac, Linux, Windows) |
| `home_setup.sh` | Linux-only home machine setup (bash, simpler) |
| `deploy_portal_worker.py` | Re-deploy portal Worker |
| `deploy_term_worker.py` | Re-deploy terminal Worker |
| `deploy_ts_relay_worker.py` | Re-deploy Tailscale relay Worker |
| `setup_cf_access.py` | Re-configure CF Zero Trust Access |
| `cf_creds.py` | DPAPI-encrypted CF token storage |
| `tsnet-src/` | Go source for `bin/tsnet.exe` (built by bootstrap.py) |
| `bin/cloudflared.exe` | Cloudflare tunnel client (download separately, gitignored) |

`keys/` and `cf_config.txt` are gitignored — generated locally by `bootstrap.py`.
The tunnel token lives in `keys/portal_config.json` (gitignored) and is printed
by `bootstrap.py` so you can pass it to `home_setup.py` on your home machine.

---

## Security notes

- CF API token stored DPAPI-encrypted in `keys/cf_creds.dpapi` (tied to your Windows login)
- SSH key stored DPAPI-encrypted in `keys/home_key.dpapi` (CLI path), or in your CF Workers KV (portal path)
- Tunnel token stored in `keys/portal_config.json` (gitignored)
- Endpoint configs in your own Cloudflare Workers KV
- Tailscale auth state in `keys/tsnet-state/` (gitignored)
- `ttyd` binds to loopback only — only reachable via CF Tunnel
- CF Zero Trust Access (optional) adds OTP email gate before the web terminal
- `bin/go-toolchain/` and `bin/tsnet.exe` are gitignored

---

## Third-party tools

- **cloudflared** — [github.com/cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) — Apache 2.0
- **ttyd** — [github.com/tsl0922/ttyd](https://github.com/tsl0922/ttyd) — MIT
- **tailscale/tsnet** — [github.com/tailscale/tailscale](https://github.com/tailscale/tailscale) — BSD 3-Clause

Cloudflare Workers, Tunnels, and Access are subject to [Cloudflare's Terms of Service](https://www.cloudflare.com/terms/).
Tailscale services (coordination server, DERP relay) are subject to [Tailscale's Terms of Service](https://tailscale.com/terms).
