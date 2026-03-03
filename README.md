# erebus-edge

Connect from a hostile corporate Windows environment to your home machine and
Tailscale network -- no admin, no VPN, no IT ticket.

```
Work machine (no admin, corporate proxy)
  |
  |--> Browser --> ssh.SUB.workers.dev --> CF Access (email OTP)
  |     --> CF browser-rendered SSH terminal
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

- Python 3.11+ (user install -- no admin, from [python.org](https://python.org))
- A [Cloudflare account](https://dash.cloudflare.com/sign-up) (free tier is fine)

---

## Setup (one time)

### 1. Run bootstrap on any machine with Python

```
python bootstrap.py --email you@example.com
```

This opens your browser to log in to Cloudflare, then automatically:

- Creates a scoped API token + CF Tunnel
- Deploys the SSH Worker
- Sets up CF Zero Trust Access (email OTP + browser SSH + short-lived certs)
- Optionally builds `bin/tsnet.exe` (userspace Tailscale)
- **Generates standalone installer scripts** in `keys/`

Flags:

| Flag | Purpose |
|------|---------|
| `--redeploy` | Re-deploy Workers + rebuild tsnet |
| `--build-tsnet` | Only rebuild tsnet binary |
| `--skip-tsnet` | Skip Go download + build |
| `--skip-access` | Skip CF Zero Trust Access |

### 2. Set up your home machine

Copy the installer that matches your home machine's OS from `keys/`:

| Home machine OS | File | How to run |
|-----------------|------|------------|
| Linux / Mac | `keys/home_linux_mac.sh` | `chmod +x home_linux_mac.sh && sudo ./home_linux_mac.sh` |
| Windows | `keys/home_windows.bat` | Right-click -> Run as Administrator |

These are standalone -- token + SSH CA key baked in, no arguments needed.

### 3. Set up your work machine

Copy the installer that matches your work machine's OS from `keys/`:

| Work machine OS | File | How to run |
|-----------------|------|------------|
| Linux / Mac | `keys/work_linux_mac.sh` | `chmod +x work_linux_mac.sh && ./work_linux_mac.sh` |
| Windows | `keys/work_windows.bat` | Double-click (no admin needed) |

Windows `.bat` files work even when GPO blocks PowerShell.

---

## Daily use

### Option A -- Browser SSH (CF Access)

Visit `https://ssh.SUB.workers.dev` in your browser.

1. Authenticate via email OTP
2. Browser-rendered SSH terminal opens automatically
3. CF generates a short-lived certificate for your session -- no SSH keys needed

### Option B -- CLI SSH (CF Tunnel)

```bash
./connect.sh      # Git Bash / Mac / Linux
connect.bat       # Windows cmd
```

First run asks for your home username and SSH port, saves to `cf_config.txt`.

### Option C -- Tailscale (tsnet)

Connect to any peer on your Tailscale network:

```
bin\tsnet.exe up          # connect + auth
bin\tsnet.exe status      # list peers
ssh -o "ProxyCommand=bin\tsnet.exe proxy %h %p" user@peer
```

> **Note:** tsnet requires `controlplane.tailscale.com` to be reachable. Networks
> with deep-packet inspection (DPI) that block Tailscale will prevent this.
> Use Options A/B (CF Tunnel) as the reliable fallback.

---

## Project structure

```
bootstrap.py              Main entry point -- run this first
connect.bat / connect.sh  CLI SSH via CF Tunnel (daily use)

lib/                      Internal modules (used by bootstrap.py)
  cf_creds.py               DPAPI-encrypted CF token storage
  config.py                 Config loader (keys/portal_config.json)
  setup_cf_access.py        CF Zero Trust Access + SSH CA setup
  deploy_ts_relay_worker.py Tailscale relay Worker deploy

tsnet/                    Go source for bin/tsnet.exe
  main.go
  go.mod

keys/                     Generated at runtime (gitignored)
  portal_config.json        Account IDs, subdomain, tunnel ID
  cf_creds.dpapi            DPAPI-encrypted CF API token
  home_linux_mac.sh         Home machine installer (Linux/Mac)
  home_windows.bat          Home machine installer (Windows)
  work_linux_mac.sh         Work machine installer (Linux/Mac)
  work_windows.bat          Work machine installer (Windows)
```

---

## Security

- **No static SSH keys** -- CF generates short-lived certificates per session
- **Email OTP gate** -- CF Access requires identity verification before SSH
- **Origin-side JWT validation** -- cloudflared validates Access JWT on the home machine
- **DPAPI encryption** -- CF API token encrypted at rest (tied to Windows login)
- **No admin required** -- everything runs in userspace on the work machine
- All secrets in `keys/` (gitignored)

---

## Third-party tools

- **cloudflared** -- [github.com/cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) -- Apache 2.0
- **tailscale/tsnet** -- [github.com/tailscale/tailscale](https://github.com/tailscale/tailscale) -- BSD 3-Clause

Cloudflare Workers, Tunnels, and Access are subject to [Cloudflare's Terms of Service](https://www.cloudflare.com/terms/).
Tailscale services are subject to [Tailscale's Terms of Service](https://tailscale.com/terms).
