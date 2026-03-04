# Build notes: erebus-edge

Lessons learned building this project. Reference for future projects with
similar patterns (CLI wizards, CF Workers, cross-platform installers,
corporate network bypass tools).

---

## Architecture decisions

### Artifacts outside the repo

All generated files (keys, binaries, config) go to `../erebus-temp/` -- a
sibling directory outside the git repo. This keeps `git status` clean and
avoids accidentally committing secrets. The repo contains only source code
and installer scripts.

### Shell-based installers instead of Python

The original bootstrap was a 940-line Python script. Porting to bash/bat
removed the Python dependency entirely. Key advantages:
- Works on fresh machines with no package manager
- `.bat` files work even when GPO blocks PowerShell execution
- `curl -F` for multipart uploads is dramatically simpler than Python's
  manual boundary building
- macOS Keychain via `security` CLI is more secure than a file-based store

### Per-user deployment model

Every user deploys their own instance to their own CF account. There is no
shared server, no shared credentials, no central admin. Users share the
repo/zip, not the URL. This eliminates trust and billing concerns.

---

## Cloudflare API patterns

### Authentication flow

`cloudflared tunnel login` is NOT a general OAuth flow. It's a zone-specific
tunnel authorization that writes to `~/.cloudflared/cert.pem`. You cannot
use it to create API tokens.

The actual options for getting a CF API token are:
1. **Open the CF Dashboard** + paste token (recommended for most users)
2. **Paste an existing token** (for automation / CI)
3. **cloudflared tunnel login** (power users only, grants a broad cert)

The dashboard URL is `https://dash.cloudflare.com/profile/api-tokens`.
"Create Custom Token" button is at the **top** of the page, not the bottom.

### Required token permissions

Four permissions, all Account-scoped with Edit access:
- Cloudflare Tunnel
- Workers Scripts
- Workers KV Storage
- Zero Trust

### Zero Trust enrollment

Zero Trust must be explicitly enabled on the CF account before the Access
API works. The enrollment flow is:
1. Go to `https://one.dash.cloudflare.com`
2. Pick a team name (becomes `TEAM.cloudflareaccess.com`)
3. Select the Free plan
4. Add a payment method ($0 charge)
5. Click Purchase

If the API returns `access.api.error.not_enabled`, walk the user through
these steps and retry.

### Worker deployment via API

Workers are deployed via multipart form upload:

```bash
curl -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -F "metadata=@metadata.json;type=application/json" \
  -F "worker.js=@worker.js;type=application/javascript+module" \
  "https://api.cloudflare.com/client/v4/accounts/$ACCT/workers/scripts/$NAME"
```

The metadata JSON must include `"main_module": "worker.js"` and a
`compatibility_date`.

After upload, enable the workers.dev subdomain:
```bash
curl -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"enabled":true}' \
  "https://api.cloudflare.com/.../scripts/$NAME/subdomain"
```

The subdomain enable endpoint returns 409 if already enabled -- this is
not an error.

### Tunnel ingress configuration

Tunnel config is set via PUT to `/cfd_tunnel/$ID/configurations`:
```json
{
  "config": {
    "ingress": [
      {"hostname": "ssh.SUB.workers.dev", "service": "ssh://localhost:22"},
      {"service": "http_status:404"}
    ]
  }
}
```

The last rule must always be a catch-all with no hostname.

### SSH Access app type

For browser-rendered SSH, create an Access app with `"type": "ssh"`.
This type needs specific cookie settings:
```json
{
  "enable_binding_cookie": false,
  "http_only_cookie_attribute": false
}
```

The SSH CA (short-lived certificates) is generated per-app:
- GET `.../apps/$ID/ca` to check for existing
- POST `.../apps/$ID/ca` to generate

The returned `public_key` goes into the home machine's
`/etc/ssh/sshd_config` as `TrustedUserCAKeys`.

---

## Cross-platform patterns

### JSON parsing in bash

CF API returns JSON. Parsing options in bash:

```bash
# Primary: python3 (available on macOS and most Linux)
json_get() {
  python3 -c "import json,sys; d=json.load(sys.stdin); print(d['key'])"
}

# Fallback: jq (if installed)
# Last resort: grep/sed for simple single-value extraction
```

Define a `json_py` helper that accepts arbitrary Python on JSON stdin:
```bash
json_py() {
  python3 -c "import json,sys
try: d=json.load(sys.stdin)
except: d={}
$1"
}
```

The `try/except` is critical -- without it, empty API responses crash the
parser.

### stdout/stderr separation in captured functions

**This is the #1 source of bugs in bash scripts that return values.**

When a function is called via `result=$(my_function)`, ALL stdout is
captured -- including `echo`, `printf`, and helper functions like `ok()`.
This pollutes the return value.

Fix: redirect all user-facing output to stderr (`>&2`) in any function
that is called via `$()`:

```bash
ensure_app() {
    ok "App exists: $id" >&2    # user sees this
    echo "$id"                   # caller captures this
}

app_id=$(ensure_app "host")     # clean -- only gets the ID
```

Functions that are NOT captured (called directly) don't need this.
Audit every function that is used in a `$()` context.

### Credential storage per platform

| Platform | Method | Store | Retrieve |
|----------|--------|-------|----------|
| macOS | Keychain | `security add-generic-password -a USER -s SERVICE -w TOKEN` | `security find-generic-password -a USER -s SERVICE -w` |
| Linux | File 0600 | `echo TOKEN > file && chmod 600 file` | `cat file` |
| Windows | DPAPI | PowerShell `[ProtectedData]::Protect()` | PowerShell `[ProtectedData]::Unprotect()` |

On macOS, `security add-generic-password` outputs verbose keychain info
to stdout. Redirect with `2>/dev/null`.

Delete before add (idempotent):
```bash
security delete-generic-password -a "$USER" -s "$SERVICE" 2>/dev/null || true
security add-generic-password -a "$USER" -s "$SERVICE" -w "$TOKEN" 2>/dev/null
```

### Worker JS generation in bash

Worker JS uses `${}` template literals which conflict with bash variable
expansion. Solution: use a no-expand heredoc + sed substitution:

```bash
WORKER_JS=$(cat << 'WORKEREOF'
const HOST = '__RELAY_HOST__';
export default {
  async fetch(request) {
    // ... ${url.pathname} is safe -- heredoc doesn't expand
  }
};
WORKEREOF
)
WORKER_JS=$(echo "$WORKER_JS" | sed "s|__RELAY_HOST__|$relay_host|g")
```

### Interactive vs non-interactive detection

Check if stdin is a terminal:
```bash
if [ -t 0 ]; then
    # Interactive: can prompt user
    read -r choice
else
    # Non-interactive (piped, CI, Claude Code Bash tool)
    # Use defaults or fail with instructions
fi
```

The Claude Code Bash tool is non-interactive -- `read` gets empty input,
`sudo` can't prompt for passwords. Design scripts to accept all inputs
via flags for automation.

### Default to safe mode

Installers that need root should default to the no-sudo path and offer
sudo as an upgrade:

```
Choose setup mode:

  [1] Quick start (default, no sudo needed)
      Installs to ~/.local/bin/, runs in foreground

  [2] Full system setup (requires sudo)
      Installs system-wide, registers as a service
```

Users who run with `sudo ./script.sh` get auto-detected via `$EUID -eq 0`.
The `--sudo` / `--no-sudo` flags skip the prompt entirely.

---

## Tailscale relay Worker

The ts-relay Worker proxies Tailscale traffic through `workers.dev`,
bypassing corporate networks that block Tailscale directly:

```
tsnet binary → ts-relay.SUB.workers.dev → controlplane.tailscale.com
                                         → DERP relay (WebSocket)
```

Routes:
- `/derpmap/default` -- custom DERP map with `ForceWebsocket: true`
- `/derp` -- WebSocket proxy to Tailscale DERP servers
- `/login*`, `/a/*` -- `login.tailscale.com` (auth flow)
- Everything else -- `controlplane.tailscale.com`

The custom DERP map creates a virtual region (ID 900) that points back
to the relay itself, forcing all DERP traffic through the WebSocket proxy.

### Connectivity pre-check

Before attempting the Go build for tsnet, test connectivity:
```bash
curl --connect-timeout 5 https://controlplane.tailscale.com/key?v=71
```

If this times out, warn the user and default to skip. tsnet won't work
if the control plane is unreachable, and the relay Worker won't help if
the build itself needs to download Go modules.

---

## UX lessons

### Step-by-step walkthrough for external setup

When the script needs the user to do something in an external UI (like
the CF Dashboard), print numbered step-by-step instructions with the
exact button names and locations. Don't say "go to the dashboard and
create a token" -- say:

```
  1. Click "Create Token"
  2. At the top, click "Get started" next to Custom Token
  3. Token name: ssh-portal
  4. Add these 4 permissions...
```

### Detect-and-guide, don't just fail

When an API returns an error that means "you haven't set this up yet"
(like Zero Trust not enabled), don't just print the error. Detect it,
explain what needs to happen, walk through the steps, wait for the user,
and retry:

```bash
if echo "$error" | grep -qi "not.enabled"; then
    print_setup_guide
    read -r  # wait for user
    retry_api_call
fi
```

### Never make users paste long tokens on the command line

Tunnel tokens (~200 chars) + SSH CA keys (~200 chars) = commands too
long for reliable terminal paste. Terminals wrap long lines and the
paste splits at the wrap point, truncating arguments. This is silent
and devastating -- the script runs with a bad token, "installs" the
service, reports success, but the service immediately crash-loops.

**Solution:** Write all config to a JSON file during bootstrap, and
have downstream scripts auto-read it:

```bash
# bootstrap writes to ../erebus-temp/keys/portal_config.json
# home installer auto-reads it -- no arguments needed:
./installers/home_linux_mac.sh
```

CLI flags still work and take precedence, but the zero-argument path
should be the default for same-machine setups.

### Verify services actually work, not just that they installed

`launchctl load` and `systemctl enable` succeed even if the service
immediately crashes. Always verify the process is actually healthy
after a delay:

```bash
sleep 5
if pgrep -x cloudflared &>/dev/null; then
    # Check logs for errors even though process is alive
    # (KeepAlive restarts it, so it may be crash-looping)
    if tail -3 /var/log/cloudflared/cloudflared.err | grep -qi "not valid"; then
        err "Service is crash-looping with bad token"
    else
        ok "Service is healthy"
    fi
fi
```

### macOS cloudflared service install doesn't accept tokens

The Homebrew version of `cloudflared service install` on macOS only
creates a user LaunchAgent for named tunnels with config files. It
does NOT accept a tunnel token argument (unlike the Linux version).

For remotely-managed tunnels with tokens, create a LaunchDaemon plist
manually:

```xml
<!-- /Library/LaunchDaemons/com.cloudflare.cloudflared.plist -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.cloudflared</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/cloudflared</string>
        <string>tunnel</string>
        <string>run</string>
        <string>--token</string>
        <string>YOUR_TOKEN_HERE</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
</dict>
</plist>
```

### macOS systemsetup needs sudo for reading too

`systemsetup -getremotelogin` requires root on modern macOS. Without
sudo, the command silently fails (exit 0, empty output), causing the
script to think SSH is disabled and try to enable it.

### Suppress brew auto-update in scripts

`brew install` triggers a full auto-update by default, producing 30+
lines of noise (new formulae, outdated formulae, download progress,
caveats). Suppress with:

```bash
HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
    brew install cloudflare/cloudflare/cloudflared >/dev/null 2>&1
```

### Every flag in --help

Every interactive prompt should have a corresponding CLI flag. Users who
run the script once interactively should be able to automate it fully
the second time by passing flags:

```bash
# Interactive first run
./bootstrap.sh --email me@example.com

# Fully automated re-run
./bootstrap.sh --cf-token "$TOKEN" --save-token --email me@example.com --skip-tsnet
```
