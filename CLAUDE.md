# CLAUDE.md — erebus-edge

Agent-facing context for working in this repo. For user-facing documentation,
see `README.md`.

## Project purpose

erebus-edge lets a user reach their home machine from a locked-down corporate
network with no admin rights, no VPN, and no IT ticket. All traffic rides
standard HTTPS through Cloudflare's edge — either as a browser-based web
terminal (ttyd behind a Cloudflare Tunnel) or as a traditional SSH session
routed through `cloudflared` / a `workers.dev` relay.

Each user deploys their own instance into their own Cloudflare account. The
repo is shared; URLs and credentials are not. All generated artifacts land in
`../erebus-temp/` (outside the git tree).

## Languages & tools

- **Bash** (`installers/*.sh`, `src/connect.sh`) — portable installers for
  macOS/Linux. Self-contained; no Python required at run time.
- **Batch / cmd** (`installers/*.bat`, `src/connect.bat`) — Windows
  counterparts for the same installers. Any feature added to a `.sh` installer
  must also land in its `.bat` sibling.
- **Python 3** (`src/*.py`) — legacy/reference implementations of the
  bootstrap wizard and Cloudflare setup (`bootstrap.py`, `cf_creds.py`,
  `config.py`, `setup_cf_access.py`, `deploy_ts_relay_worker.py`). The Bash/Bat
  installers are the shipping path; Python is kept as a reference and for
  full-fidelity CF API flows.
- **Go** (`tsnet/`) — optional userspace Tailscale binary. Connects to
  Tailscale with no admin rights and no WinTun driver, over plain HTTPS:443.
  Module is self-contained (`tsnet/go.mod`, `tsnet/go.sum`, `tsnet/main.go`).
- **Node.js** (`package.json`, `test/`) — only used for the Selenium-based
  smoke test. There is no production JS/TS code. `package.json`'s `test`
  script is still the default stub (`echo "Error: no test specified" && exit 1`).
- **Cloudflare** — Workers, Tunnels, Zero Trust Access, DNS. A free account
  with a domain on Cloudflare is the hard requirement for end users.
- **ttyd** — third-party web terminal. Installed by the home installer;
  LaunchDaemon plist in `installers/com.ttyd.terminal.plist`.

## Key directories

```
installers/   Shipping installers (bootstrap, home, work — .sh + .bat pairs)
              + com.ttyd.terminal.plist LaunchDaemon
              + installers/README.md
src/          Python reference implementations + connect.sh/.bat helpers
tsnet/        Optional Go userspace Tailscale binary
test/e2e/     Selenium smoke test (browser.setup.ts, smoke.test.ts)
docs/         BUILD_NOTES.md and docs/constitutions/
keys/         (gitignored runtime material — do not commit)
scripts/      (empty placeholder)
HOME_SETUP.md Historical home-machine setup notes
LICENSE       MIT
README.md     User-facing docs (authoritative for end-user flows)
```

`../erebus-temp/` (sibling of the repo, not tracked) holds per-user config,
tokens, and downloaded binaries.

## Common commands

Setup flows (the normal entry points):

```bash
# One-time bootstrap (any machine)
./installers/bootstrap.sh --email you@example.com    # mac/linux
installers\bootstrap.bat --email you@example.com     # windows

# Home machine
./installers/home_linux_mac.sh                       # mac/linux (pass --sudo for service install)
installers\home_windows.bat                          # windows

# Work machine
./installers/work_linux_mac.sh                       # mac/linux
installers\work_windows.bat --host ssh.yourdomain.com  # windows
```

Go (tsnet):

```bash
cd tsnet && go build ./...   # builds the tsnet binary
```

Python reference wizard:

```bash
python3 src/bootstrap.py           # full wizard
python3 src/bootstrap.py --redeploy
python3 src/bootstrap.py --skip-access
python3 src/bootstrap.py --skip-tsnet
```

E2E smoke test:

```bash
npm install
# test runner is selenium-webdriver; see test/e2e/smoke.test.ts for invocation
```

## Conventions

- **Installer parity** — every flag, message, and behavior in a `.sh`
  installer must be mirrored in the matching `.bat`. The README documents
  flags in a single table, so keep both in sync with that table.
- **No secrets in repo** — all account-specific material (tokens, tunnel IDs,
  portal config) lives in `../erebus-temp/`. `.gitignore` excludes `keys/`.
- **Localhost-only services** — ttyd binds to `127.0.0.1:7681`; the tunnel
  handles external exposure. The `-W` flag on ttyd is required for writable
  terminals.
- **Scoped CF API tokens** — bootstrap creates narrow-permission tokens; do
  not broaden these when editing the flow.
- **Userspace only on the work machine** — never add steps that require admin
  rights on the work side. `cloudflared` is downloaded to the user directory.
- **Default branch is `hee-haw`**, not `main`. Pushes and merges target
  `hee-haw`.

## Platform gotchas

- **macOS service install** uses a LaunchDaemon
  (`com.ttyd.terminal.plist`, `com.cloudflare.cloudflared`). Managed with
  `launchctl`. `ttyd` path in the plist is `/opt/homebrew/bin/ttyd` (Apple
  Silicon Homebrew).
- **Linux service install** uses whatever init the distro provides (the home
  installer detects it). Debian/Ubuntu gets ttyd via `apt`.
- **Windows** installers use `.bat` (cmd-compatible) — not PowerShell. Keep
  them runnable from both `cmd` and PowerShell.
- **Corporate DNS blocking** is expected. The work installer probes the
  custom domain and falls back to a `workers.dev` relay if resolution fails.
  Any change to the relay flow must keep this auto-detection path intact.
- **Cloudflare Zero Trust** setup can fail silently if the free plan isn't
  enabled on the account — bootstrap handles this, but manual edits to
  `setup_cf_access.py` must preserve the enablement check.
- **tsnet is optional** — `--skip-tsnet` must continue to work; the tunnel
  path is the primary flow.

## Things to be careful of

- Do not add runtime dependencies to the `.sh`/`.bat` installers (no Python,
  no Node). They must work on a fresh machine.
- Do not break the "share the repo, not the URL" invariant — any new config
  must be written to `../erebus-temp/`, not committed.
- Do not hardcode domains, tokens, emails, or tunnel IDs. Every such value is
  per-user and belongs in the temp config.
- Do not force-push or `--no-verify` — let hooks run.
- The Python code in `src/` is reference, not production, but do not delete
  it without a replacement path for the CF Access flow.
