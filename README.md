# erebus-edge

Access your home machine from a locked-down corporate network.
No admin privileges. No VPN. No IT ticket.

## What this does

You run a few scripts. After that, you open a URL in your work browser and get a
terminal on your home machine. Everything goes through Cloudflare's network over
standard HTTPS — it looks like normal web browsing to your corporate firewall.

```
Your work laptop                     Cloudflare                    Your home machine
  |                                                                       |
  |-- Chrome ──► workers.dev ──► CF edge ──► CF Tunnel ──► web terminal ──|
  |   (HTTPS)    (looks normal)   (encrypted)  (persistent)   (ttyd)      |
  |                                                                       |
  `-- or: ssh ──► cloudflared ──► workers.dev ──► CF Tunnel ──► sshd ────-'
      (optional CLI path, needs cloudflared installed)
```

**Two ways to connect:**
1. **Browser** (recommended) — just open a URL. No installs on the work machine.
2. **CLI SSH** — traditional `ssh` command, routed through Cloudflare. Needs a small binary.

**Each person deploys their own instance** to their own Cloudflare account.
Share the repo — not the URL.

---

## What you need before starting

1. A **free** [Cloudflare account](https://dash.cloudflare.com/sign-up) (no credit card)
2. A **domain on Cloudflare** — either:
   - Buy one through [CF Registrar](https://dash.cloudflare.com/?to=/:account/domains/register) (~$1/yr for `.xyz`)
   - Or add an existing domain and point its nameservers to Cloudflare
3. A **home machine** that stays on (Mac, Linux, or Windows)
4. **10 minutes**

The bootstrap wizard walks you through everything — including creating the API
token, enabling Zero Trust (free), and setting up DNS. You don't need to
understand Cloudflare to use this.

---

## Setup (3 steps)

### Step 1: Bootstrap (run once, on any machine)

```bash
git clone https://github.com/YOUR_USER/erebus-edge.git
cd erebus-edge

# macOS / Linux
./installers/bootstrap.sh --email you@example.com

# Windows (cmd or PowerShell)
installers\bootstrap.bat --email you@example.com
```

The `--email` is the address you'll use to log in (Cloudflare sends a one-time code).

**What happens:**
- Opens your browser to create a Cloudflare API token (with step-by-step instructions)
- Creates a tunnel, DNS record, and access policies automatically
- Saves all config to `../erebus-temp/` (outside the repo, never committed)

<details>
<summary><b>All bootstrap flags</b> (for power users)</summary>

| Flag | Purpose |
|------|---------|
| `--email EMAIL` | Email(s) for access (repeatable). Required. |
| `--domain DOMAIN` | Domain to use. Auto-selects if omitted. |
| `--cf-token TOKEN` | Provide API token directly (skip browser flow). |
| `--save-token` | Save token to macOS Keychain / Linux file / Windows DPAPI. |
| `--redeploy` | Re-run DNS + tunnel config with existing settings. |
| `--skip-access` | Skip Zero Trust Access setup. |
| `--skip-tsnet` | Skip optional Tailscale component. |

Fully automated example (no browser):
```bash
./bootstrap.sh --cf-token "YOUR_TOKEN" --save-token \
  --email you@example.com --domain yourdomain.com --skip-tsnet
```
</details>

### Step 2: Set up your home machine

On the machine you want to connect TO:

```bash
./installers/home_linux_mac.sh        # Mac or Linux
installers\home_windows.bat           # Windows
```

If bootstrap ran on a different machine, copy the repo + `../erebus-temp/` folder
to your home machine first.

**What it does:**
- Enables the SSH server (if not already on)
- Installs Cloudflare's tunnel agent (`cloudflared`)
- Installs and starts ttyd (the web terminal) automatically
- Starts the tunnel as a system service (survives reboots)

Pass `--sudo` to skip the interactive prompt and install as a boot service directly.

### Step 3: Set up your work machine

On the machine you connect FROM (your corporate laptop):

**Windows:**
```cmd
installers\work_windows.bat --host ssh.yourdomain.com
```

**Mac / Linux:**
```bash
./installers/work_linux_mac.sh
```

**What it does:**
- Downloads `cloudflared` to your user directory (no admin needed)
- Tests if your corporate network can resolve the custom domain
- If DNS is blocked: auto-detects and routes through a `workers.dev` relay
- Creates an SSH config entry so `ssh` just works

<details>
<summary><b>Corporate DNS blocked?</b> (the script handles this automatically)</summary>

Many corporate networks block DNS resolution for unknown domains. The work
installer detects this automatically:

1. Probes DNS for your custom domain
2. If it fails, looks for a `workers.dev` relay (deployed by bootstrap)
3. Routes all traffic through `workers.dev` instead — which corporate DNS allows

You can also pass the relay explicitly:
```cmd
work_windows.bat --host ssh.yourdomain.com --relay edge-sync.XXXX.workers.dev
```

For relay authentication (service token), pass `--id` and `--secret` or add
`service_token_id` and `service_token_secret` to your `portal_config.json`.
</details>

---

## Daily use

### Browser terminal (recommended)

Open this URL in any browser:

```
https://edge-sync.YOUR_SUBDOMAIN.workers.dev
```

You'll get a terminal. Log in with your home machine username and password.

> The browser terminal URL is printed at the end of bootstrap and the home installer.
> It looks like `https://edge-sync.YOUR_SUBDOMAIN.workers.dev`.

> **Why this is the best option for corporate networks:**
> - No software to install on the work machine
> - No `ssh` command, no PowerShell
> - Looks like a normal web page to your IT department
> - Works on any device with a browser (phone, tablet, Chromebook)

### CLI SSH

```bash
ssh YOUR_USER@ssh.yourdomain.com
```

Requires `cloudflared` installed (Step 3 handles this). On corporate networks
where DNS is blocked, the SSH config routes through the `workers.dev` relay
automatically.

---

## What your corporate security sees

| Layer | What they see | Suspicious? |
|-------|--------------|-------------|
| DNS lookup | `edge-sync.XXXX.workers.dev` | No — standard Cloudflare dev domain |
| Network traffic | HTTPS to Cloudflare IP on port 443 | No — same as any website |
| Browser tab | "Edge Sync - Dashboard" | No — looks like a dev tool |
| EDR/endpoint | Chrome making HTTPS request | No — normal browsing |
| Process list | Only Chrome | No — no extra binaries |

**What they cannot see:** The terminal content, your keystrokes, the destination,
or that it's a shell session. Everything is encrypted end-to-end.

---

## Project structure

```
README.md                       This file
LICENSE                         MIT

installers/                     Self-contained scripts (no Python needed)
  bootstrap.sh / .bat             First-run wizard
  home_linux_mac.sh / .bat        Home machine setup
  work_linux_mac.sh / .bat        Work machine setup

src/                            Reference implementations (Python, legacy)
  bootstrap.py                    Original Python wizard
  connect.sh / .bat               CLI connect helpers
  deploy_ts_relay_worker.py       Worker deployment

tsnet/                          Optional: userspace Tailscale (Go)
  main.go / go.mod

docs/
  BUILD_NOTES.md                Architecture decisions & CF API patterns

../erebus-temp/                 Created by bootstrap (outside repo, gitignored)
  keys/portal_config.json        Your account config (tokens, IDs, domain)
  bin/                           Downloaded binaries
```

---

<details>
<summary><b>Manual ttyd setup (if automatic installation failed)</b></summary>

The home installer (`home_linux_mac.sh --sudo`) automatically installs and
configures ttyd. If that failed, you can set it up manually.

The browser terminal uses [ttyd](https://github.com/tsl0922/ttyd), a lightweight
tool that serves a shell over HTTP/WebSocket.

### Install ttyd

**macOS:**
```bash
brew install ttyd
```

**Linux (Debian/Ubuntu):**
```bash
sudo apt install ttyd
```

### Run it

```bash
# Quick test (foreground)
ttyd -W -p 7681 -i 127.0.0.1 /bin/zsh

# As a service (macOS LaunchDaemon)
sudo cp installers/com.ttyd.terminal.plist /Library/LaunchDaemons/
sudo launchctl load /Library/LaunchDaemons/com.ttyd.terminal.plist
```

**Important flags:**
- `-W` — **required** — enables write mode (without this, you can see output but can't type)
- `-i 127.0.0.1` — bind to localhost only (the tunnel handles external access)
- `-p 7681` — port (must match the tunnel ingress)

### Add to the tunnel

Add an ingress rule in your Cloudflare tunnel config pointing a hostname to
`http://localhost:7681`. The `edge-sync` Worker proxies browser requests to this
endpoint and CLI requests to the SSH tunnel.

<details>
<summary><b>ttyd LaunchDaemon plist</b></summary>

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ttyd.terminal</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/ttyd</string>
        <string>-W</string>
        <string>-p</string>
        <string>7681</string>
        <string>-i</string>
        <string>127.0.0.1</string>
        <string>/bin/zsh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/ttyd.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/ttyd.log</string>
</dict>
</plist>
```
</details>

</details>

---

## Security model

- **No static SSH keys** — Cloudflare generates short-lived certificates per session
- **Email OTP** — CF Access requires identity verification before granting access
- **Encrypted tunnel** — all traffic goes through CF's edge, your home IP is never exposed
- **No admin needed** — everything runs in userspace on the work machine
- **No secrets in repo** — all artifacts go to `../erebus-temp/` (outside the git tree)
- **Scoped API tokens** — bootstrap creates tokens with only the required permissions
- **Localhost-only services** — ttyd and the tunnel bind to `127.0.0.1`

---

## Troubleshooting

**"Connection refused" in browser terminal:**
- ttyd isn't running. Check: `pgrep -fl ttyd`
- Restart: `sudo launchctl kickstart -k system/com.ttyd.terminal`

**Can see the terminal but can't type:**
- ttyd was started without `-W` (writable) flag. Restart with `-W`.

**"websocket: bad handshake" from CLI SSH:**
- The `edge-sync` Worker may need redeployment. Re-run bootstrap with `--redeploy`.

**DNS doesn't resolve from work:**
- Expected on corporate networks. The work installer auto-detects this and routes
  through `workers.dev`. Re-run the work installer if needed.

**Tunnel not connecting:**
- Check: `sudo launchctl list | grep cloudflared`
- Restart: `sudo launchctl kickstart -k system/com.cloudflare.cloudflared`
- Logs: `cat /var/log/cloudflared/cloudflared.log`

**OTP email never arrives:**
- Check spam. CF sends from `noreply@notify.cloudflare.com`.

---

## Third-party tools

- **cloudflared** — [github.com/cloudflare/cloudflared](https://github.com/cloudflare/cloudflared) — Apache 2.0
- **ttyd** — [github.com/tsl0922/ttyd](https://github.com/tsl0922/ttyd) — MIT
- **tailscale/tsnet** — [github.com/tailscale/tailscale](https://github.com/tailscale/tailscale) — BSD 3-Clause (optional)

Cloudflare services subject to [Cloudflare's Terms](https://www.cloudflare.com/terms/).

---

## License

MIT — see [LICENSE](LICENSE).
