# erebus-edge

SSH into your home machine from a locked-down corporate network.
No admin, no VPN, no IT ticket.

```
Work machine (no admin, corporate proxy)
  |
  |--> Browser --> ssh.yourdomain.com --> CF Access (email OTP)
  |     --> CF browser-rendered SSH terminal
  |     --> Short-lived SSH certificates (no static keys)
  |
  |--> CLI SSH --> cloudflared ProxyCommand --> CF Tunnel --> home SSH
  |
  `--> tsnet (userspace Tailscale, no admin)
        --> any Tailscale peer via DERP relay
```

**How it works:** Cloudflare Tunnel creates a persistent connection from your home
machine to CF's edge. A DNS CNAME (`ssh.yourdomain.com`) routes traffic through
CF Access (email OTP authentication) to the tunnel, which forwards to your local
SSH server. No port forwarding, no dynamic DNS, no static IP needed.

Every user deploys their **own** instance to their **own** Cloudflare account.
Share the repo/zip -- not the URL.

---

## Prerequisites

1. A **free** [Cloudflare account](https://dash.cloudflare.com/sign-up)
2. A **domain on Cloudflare** -- either:
   - Buy one through [CF Registrar](https://dash.cloudflare.com/?to=/:account/domains/register) (~$1/yr for .xyz)
   - Or add your own domain and point its nameservers to Cloudflare

That's it. No paid plan, no credit card required for basic setup.

The bootstrap wizard walks you through everything, including:
- Creating a CF API token (opens the dashboard with step-by-step instructions)
- Enabling Zero Trust (free plan, $0 charge)
- Setting up DNS, tunnel, and access policies

**Optional:** A [Tailscale account](https://login.tailscale.com/start) if you
want peer-to-peer connectivity (Option C below). Not needed for SSH.

---

## Quick start (from scratch)

### 1. Clone and run bootstrap

```bash
git clone https://github.com/YOUR_USER/erebus-edge.git
cd erebus-edge

# macOS / Linux
./installers/bootstrap.sh --email you@example.com

# Windows (cmd or PowerShell)
installers\bootstrap.bat --email you@example.com
```

The wizard will:
1. Open your browser to the CF Dashboard to create an API token
2. Print step-by-step instructions (which buttons to click, which permissions)
3. If Zero Trust isn't enabled, walk you through the free enrollment
4. Pick your domain (or guide you to register one)
5. Create everything automatically once you paste the token

Automatically sets up:

- Creates a scoped API token + CF Tunnel
- Creates DNS CNAME (`ssh.yourdomain.com` -> tunnel)
- Sets up CF Zero Trust Access (email OTP + browser SSH + short-lived certs)
- Deploys the Tailscale relay Worker (`ts-relay.SUB.workers.dev`)
- Optionally builds a `tsnet` binary (userspace Tailscale)

All artifacts go to `../erebus-temp/` -- the repo stays clean.

<details>
<summary>Bootstrap flags</summary>

| Flag | Purpose |
|------|---------|
| `--email EMAIL` | Email(s) to allow through CF Access (repeatable) |
| `--domain DOMAIN` | Domain to use (auto-selects if omitted) |
| `--cf-token TOKEN` | Pass CF API token directly (skip browser flow) |
| `--save-token` | Save token to Keychain/DPAPI/file |
| `--redeploy` | Re-run DNS + ingress + Access with existing config |
| `--build-tsnet` | Only rebuild tsnet binary |
| `--skip-tsnet` | Skip Go download + tsnet build |
| `--skip-access` | Skip CF Zero Trust Access setup |

</details>

### 2. Set up your home machine

If you ran bootstrap on the same machine, just run:

```bash
# macOS / Linux -- auto-reads token from ../erebus-temp/
./installers/home_linux_mac.sh

# Windows -- auto-reads token from ..\erebus-temp\
installers\home_windows.bat
```

If your home machine is a **different box**, copy the repo there (or just
`installers/` + `../erebus-temp/`) and run the same command.

The script asks whether you want **Quick start** (no sudo, foreground tunnel)
or **Boot service** (sudo/admin, auto-starts on boot). Pass `--sudo` /
`--no-sudo` (or `--admin` / `--no-admin` on Windows) to skip the prompt.

### 3. Set up your work machine

```bash
# macOS / Linux -- auto-reads SSH host from config
./installers/work_linux_mac.sh

# Windows (no admin needed) -- auto-reads from config
installers\work_windows.bat
```

Or pass the host directly: `--ssh-host ssh.yourdomain.com`

Windows `.bat` files work even when GPO blocks PowerShell.
No secrets in the installer files -- tokens are passed as arguments at run time.

---

## Daily use

### Option A -- Browser SSH (CF Access)

Visit `https://ssh.yourdomain.com` in your browser.

1. Authenticate via email OTP
2. Browser-rendered SSH terminal opens automatically
3. CF generates a short-lived certificate for your session -- no SSH keys needed

You can also use the App Launcher at `https://TEAM.cloudflareaccess.com` to
see all your CF Access apps and launch SSH from there.

### Option B -- CLI SSH (CF Tunnel)

```bash
src/connect.sh      # Git Bash / Mac / Linux
src\connect.bat     # Windows cmd
```

Or directly: `ssh YOUR_USER@ssh.yourdomain.com`
(requires cloudflared installed -- the work installer handles this)

### Option C -- Tailscale (tsnet)

Connect to any peer on your Tailscale network:

```bash
tsnet up              # connect + auth
tsnet status          # list peers
ssh -o "ProxyCommand=tsnet proxy %h %p" user@peer
```

> **Note:** tsnet requires `controlplane.tailscale.com` to be reachable.
> The ts-relay Worker proxies this through `workers.dev` to bypass DPI,
> but some networks may still block it. Use Options A/B as the reliable fallback.

---

## Project structure

```
README.md / LICENSE         You are here

installers/                 Standalone installers (no Python, no secrets)
  bootstrap.sh                Bootstrap wizard (macOS/Linux)
  bootstrap.bat               Bootstrap wizard (Windows)
  home_linux_mac.sh           Home machine setup (Linux/Mac)
  home_windows.bat            Home machine setup (Windows)
  work_linux_mac.sh           Work machine setup (Linux/Mac)
  work_windows.bat            Work machine setup (Windows)

src/                        Python reference implementation (legacy)
  bootstrap.py                Original Python bootstrap wizard
  connect.bat / connect.sh    CLI SSH connect scripts
  cf_creds.py                 DPAPI credential store (Windows)
  config.py                   Config loader
  setup_cf_access.py          CF Zero Trust Access setup
  deploy_ts_relay_worker.py   Tailscale relay Worker deploy

tsnet/                      Go source for userspace Tailscale (optional)
  main.go
  go.mod

../erebus-temp/             Created by bootstrap (gitignored, outside repo)
  keys/
    portal_config.json        Account IDs, domain, tunnel ID, etc.
  bin/
    cloudflared               Downloaded if not in PATH
    tsnet                     Built from source (optional)
  cf_config.txt               Saved SSH settings
```

---

## Security

- **No static SSH keys** -- CF generates short-lived certificates per session
- **Email OTP gate** -- CF Access requires identity verification before SSH
- **Origin-side JWT validation** -- cloudflared validates Access JWT on the home machine
- **Per-platform credential storage** -- macOS Keychain, Linux file (0600), Windows DPAPI
- **No admin required** -- everything runs in userspace on the work machine
- **No secrets in repo** -- all artifacts go to `../erebus-temp/` (outside the repo)
- **Scoped API tokens** -- bootstrap creates tokens with only the required permissions
- **DNS-routed via CF proxy** -- traffic goes through CF's edge, never exposes your home IP

---

## Third-party tools

- **cloudflared** -- [github.com/cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) -- Apache 2.0
- **tailscale/tsnet** -- [github.com/tailscale/tailscale](https://github.com/tailscale/tailscale) -- BSD 3-Clause

Cloudflare Workers, Tunnels, and Access are subject to [Cloudflare's Terms of Service](https://www.cloudflare.com/terms/).
Tailscale services are subject to [Tailscale's Terms of Service](https://tailscale.com/terms).

---

## License

MIT -- see [LICENSE](LICENSE).
