# erebus-edge

SSH into your home machine from a locked-down corporate network.
No admin, no VPN, no IT ticket.

```
Work machine (no admin, corporate proxy)
  |
  |--> Browser --> ssh.SUB.workers.dev --> CF Access (email OTP)
  |     --> CF browser-rendered SSH terminal
  |     --> Short-lived SSH certificates (no static keys)
  |
  |--> CLI SSH --> cloudflared ProxyCommand --> CF Tunnel --> home SSH
  |
  `--> tsnet (userspace Tailscale, no admin)
        --> any Tailscale peer via DERP relay
```

**Why it works on corporate networks:** `*.workers.dev` is on the `no_proxy`
list of most managed Windows machines. Traffic goes direct to Cloudflare's
edge without hitting the corporate proxy or SSL inspection.

Every user deploys their **own** instance to their **own** Cloudflare account.
Share the repo/zip -- not the URL.

---

## Quick start

### 1. Run bootstrap (any machine, no Python needed)

```bash
# macOS / Linux
./installers/bootstrap.sh --email you@example.com

# Windows (cmd or PowerShell)
installers\bootstrap.bat --email you@example.com
```

Opens your browser to create a Cloudflare API token, then automatically:

- Creates a scoped API token + CF Tunnel
- Deploys the SSH proxy Worker (`ssh.SUB.workers.dev`)
- Deploys the Tailscale relay Worker (`ts-relay.SUB.workers.dev`)
- Sets up CF Zero Trust Access (email OTP + browser SSH + short-lived certs)
- Optionally builds a `tsnet` binary (userspace Tailscale)

All artifacts go to `../erebus-temp/` -- the repo stays clean.

<details>
<summary>Bootstrap flags</summary>

| Flag | Purpose |
|------|---------|
| `--email EMAIL` | Email(s) to allow through CF Access (repeatable) |
| `--cf-token TOKEN` | Pass CF API token directly (skip browser flow) |
| `--save-token` | Save token to Keychain/DPAPI/file |
| `--redeploy` | Re-deploy Workers with existing config |
| `--build-tsnet` | Only rebuild tsnet binary |
| `--skip-tsnet` | Skip Go download + tsnet build |
| `--skip-access` | Skip CF Zero Trust Access setup |
| `--workers-only` | Skip tunnel/Access, just deploy Workers |

</details>

### 2. Set up your home machine

Bootstrap prints the exact command with your token. Copy-paste it.

```bash
# Default: interactive mode picker (no sudo needed)
./installers/home_linux_mac.sh --token <TOKEN> --ca-key "<KEY>" --ssh-host <HOST>

# Windows (as Administrator)
installers\home_windows.bat <TOKEN> "<CA_KEY>" <HOST>
```

The script asks whether you want **Quick start** (no sudo, foreground tunnel)
or **Full system setup** (sudo, auto-starts on boot). Pass `--sudo` or
`--no-sudo` to skip the prompt.

### 3. Set up your work machine

```bash
# macOS / Linux
./installers/work_linux_mac.sh --ssh-host <HOST>

# Windows (no admin needed)
installers\work_windows.bat <HOST>
```

Windows `.bat` files work even when GPO blocks PowerShell.
No secrets in the installer files -- tokens are passed as arguments at run time.

---

## Daily use

### Option A -- Browser SSH (CF Access)

Visit `https://ssh.SUB.workers.dev` in your browser.

1. Authenticate via email OTP
2. Browser-rendered SSH terminal opens automatically
3. CF generates a short-lived certificate for your session -- no SSH keys needed

### Option B -- CLI SSH (CF Tunnel)

```bash
src/connect.sh      # Git Bash / Mac / Linux
src\connect.bat     # Windows cmd
```

First run asks for your home username and SSH port, saves to `cf_config.txt`.

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
    portal_config.json        Account IDs, subdomain, tunnel ID, etc.
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
- **Scoped API tokens** -- bootstrap creates tokens with only the 4 required permissions

---

## Third-party tools

- **cloudflared** -- [github.com/cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) -- Apache 2.0
- **tailscale/tsnet** -- [github.com/tailscale/tailscale](https://github.com/tailscale/tailscale) -- BSD 3-Clause

Cloudflare Workers, Tunnels, and Access are subject to [Cloudflare's Terms of Service](https://www.cloudflare.com/terms/).
Tailscale services are subject to [Tailscale's Terms of Service](https://tailscale.com/terms).

---

## License

MIT -- see [LICENSE](LICENSE).
