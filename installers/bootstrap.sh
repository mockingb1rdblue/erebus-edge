#!/usr/bin/env bash
# bootstrap.sh -- First-run setup wizard for erebus-edge (macOS / Linux).
#
# Self-contained -- no Python, no external deps beyond curl + cloudflared.
# All artifacts go to ../erebus-temp/ (repo stays clean).
#
# Usage:
#   ./bootstrap.sh --email user@example.com
#   ./bootstrap.sh --email a@x.com --email b@x.com
#   ./bootstrap.sh --redeploy
#   ./bootstrap.sh --skip-access --skip-tsnet
#   ./bootstrap.sh --build-tsnet
#   ./bootstrap.sh --domain myname.xyz

set -o pipefail

# ═══════════════════════════════════════════════════════════════════════════
#  Paths & constants
# ═══════════════════════════════════════════════════════════════════════════
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(cd "$REPO_ROOT/.." && pwd)/erebus-temp"
KEYS_DIR="$TEMP_DIR/keys"
BIN_DIR="$TEMP_DIR/bin"
CF_CFG_TXT="$TEMP_DIR/cf_config.txt"
CF_API="https://api.cloudflare.com/client/v4"
PORTAL_TOKEN_NAME="ssh-portal"
TUNNEL_NAME="home-ssh"
COMPAT_DATE="2025-12-01"

# ── Colours ───────────────────────────────────────────────────────────────
G='\033[32m'; Y='\033[33m'; C='\033[36m'; R='\033[31m'
B='\033[1m';  D='\033[2m';  X='\033[0m'
ok()   { printf "  ${G}✓${X} %s\n" "$1"; }
warn() { printf "  ${Y}!${X} %s\n" "$1"; }
err()  { printf "  ${R}✗${X} %s\n" "$1"; }
hdr()  { local pad=$((52 - ${#1})); printf "\n${C}${B}── %s " "$1"; printf '─%.0s' $(seq 1 "$pad"); printf "${X}\n"; }

# ── Global state (set by step functions) ──────────────────────────────────
TOKEN=""
ACCT_ID=""
ACCT_NAME=""
SUBDOMAIN=""
TUNNEL_ID=""
TUNNEL_TOKEN=""
SSH_HOST=""
SSH_APP_AUD=""
SSH_CA_KEY=""
TEAM_NAME=""
ZONE_ID=""
DOMAIN=""
APP_HOST=""
SVC_TOKEN_ID=""
SVC_TOKEN_SECRET=""
EDGE_SYNC_URL=""
TSNET_OK=false

# ═══════════════════════════════════════════════════════════════════════════
#  JSON parsing (python3 preferred, jq fallback)
# ═══════════════════════════════════════════════════════════════════════════
_JSON_CMD=""
if command -v python3 &>/dev/null; then
    _JSON_CMD="python3"
elif command -v jq &>/dev/null; then
    _JSON_CMD="jq"
else
    echo "ERROR: python3 or jq is required for JSON parsing."
    echo "  macOS: xcode-select --install   (provides python3)"
    echo "  Linux: sudo apt install python3  (or jq)"
    exit 1
fi

# json_get PATH  — extract a value from JSON on stdin.
#   PATH uses dot/bracket notation: result[0].id, success, result.subdomain
json_get() {
    local path="$1"
    if [ "$_JSON_CMD" = "python3" ]; then
        python3 -c "
import json, sys, re
try:
    d = json.load(sys.stdin)
except: sys.exit(0)
for p in re.findall(r'\[(\d+)\]|\.?([^.\[]+)', sys.argv[1]):
    i, k = p
    try: d = d[int(i)] if i else d[k]
    except: d = None; break
if isinstance(d, bool): print(str(d).lower())
elif isinstance(d, (dict, list)): print(json.dumps(d))
elif d is not None: print(d)" "$path"
    else
        local jp="$path"
        [[ "$jp" != .* ]] && jp=".$jp"
        jq -r "$jp // empty" 2>/dev/null
    fi
}

# json_py CODE  — run arbitrary Python on JSON stdin (d = parsed object).
json_py() {
    python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except:
    d = {}
$1" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
#  Platform detection
# ═══════════════════════════════════════════════════════════════════════════
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"    # darwin / linux
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    arm64)   ARCH="arm64" ;;
    armv*)   ARCH="arm"   ;;
esac

# ═══════════════════════════════════════════════════════════════════════════
#  Credential store (macOS Keychain / Linux file 0600)
# ═══════════════════════════════════════════════════════════════════════════
_KC_SERVICE="erebus-edge-cf-token"

store_credential() {
    local tok="$1"
    if [ "$OS" = "darwin" ]; then
        security delete-generic-password -a "$USER" -s "$_KC_SERVICE" 2>/dev/null || true
        security add-generic-password -a "$USER" -s "$_KC_SERVICE" -w "$tok" 2>/dev/null
        ok "Token saved to macOS Keychain."
    else
        mkdir -p "$KEYS_DIR"
        printf '%s' "$tok" > "$KEYS_DIR/cf_token"
        chmod 600 "$KEYS_DIR/cf_token"
        ok "Token saved to $KEYS_DIR/cf_token (mode 0600)."
    fi
}

load_credential() {
    if [ "$OS" = "darwin" ]; then
        security find-generic-password -a "$USER" -s "$_KC_SERVICE" -w 2>/dev/null || true
    else
        [ -f "$KEYS_DIR/cf_token" ] && cat "$KEYS_DIR/cf_token" || true
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  cloudflared binary
# ═══════════════════════════════════════════════════════════════════════════
CLOUDFLARED=""

find_cloudflared() {
    # 1. Already found
    [ -n "$CLOUDFLARED" ] && [ -x "$CLOUDFLARED" ] && return 0
    # 2. System PATH
    if command -v cloudflared &>/dev/null; then
        CLOUDFLARED="$(command -v cloudflared)"
        ok "cloudflared in PATH: $CLOUDFLARED" >&2
        return 0
    fi
    # 3. Our bin dir
    if [ -x "$BIN_DIR/cloudflared" ]; then
        CLOUDFLARED="$BIN_DIR/cloudflared"
        ok "cloudflared: $CLOUDFLARED" >&2
        return 0
    fi
    return 1
}

download_cloudflared() {
    mkdir -p "$BIN_DIR"
    local url
    if [ "$OS" = "darwin" ]; then
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${ARCH}.tgz"
        printf "  Downloading cloudflared (macOS %s) ..." "$ARCH" >&2
        if curl -sL "$url" | tar xz -C "$BIN_DIR" 2>/dev/null; then
            chmod +x "$BIN_DIR/cloudflared"
            CLOUDFLARED="$BIN_DIR/cloudflared"
            printf " ${G}OK${X}\n" >&2
            return 0
        fi
    else
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
        printf "  Downloading cloudflared (Linux %s) ..." "$ARCH" >&2
        if curl -sL -o "$BIN_DIR/cloudflared" "$url" 2>/dev/null; then
            chmod +x "$BIN_DIR/cloudflared"
            CLOUDFLARED="$BIN_DIR/cloudflared"
            printf " ${G}OK${X}\n" >&2
            return 0
        fi
    fi
    printf " ${R}FAILED${X}\n" >&2
    return 1
}

ensure_cloudflared() {
    find_cloudflared && return 0
    warn "cloudflared not found. Downloading..." >&2
    download_cloudflared
}

# ═══════════════════════════════════════════════════════════════════════════
#  CF API helper
# ═══════════════════════════════════════════════════════════════════════════
cf_api() {
    local method="$1" path="$2"
    local data="${3:-}"
    local url="${CF_API}${path}"
    local result
    local -a args=(-sk -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json")
    [ "$method" != "GET" ] && args+=(-X "$method")
    [ -n "$data" ] && args+=(-d "$data")
    result=$(curl "${args[@]}" "$url" 2>/dev/null) || result='{"success":false,"errors":["curl failed"]}'
    echo "$result"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Config load / save  (portal_config.json)
# ═══════════════════════════════════════════════════════════════════════════
CFG_FILE="$KEYS_DIR/portal_config.json"

load_config() {
    [ -f "$CFG_FILE" ] && cat "$CFG_FILE" || echo '{}'
}

save_config() {
    # save_config '{"key":"val", ...}'  — merges into existing config
    local updates="$1"
    mkdir -p "$KEYS_DIR"
    if [ -f "$CFG_FILE" ]; then
        python3 -c "
import json, sys
with open(sys.argv[1]) as f: cfg = json.load(f)
cfg.update(json.loads(sys.argv[2]))
with open(sys.argv[1], 'w') as f: json.dump(cfg, f, indent=2)
" "$CFG_FILE" "$updates"
    else
        echo "$updates" | python3 -c "
import json, sys
cfg = json.load(sys.stdin)
with open(sys.argv[1], 'w') as f: json.dump(cfg, f, indent=2)
" "$CFG_FILE"
    fi
}

config_val() {
    # config_val KEY — read a key from portal_config.json
    load_config | json_get "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Worker JS generators
# ═══════════════════════════════════════════════════════════════════════════
generate_ts_relay_worker_js() {
    local relay_host="$1"
    cat << 'WORKEREOF' | sed "s|__RELAY_HOST__|${relay_host}|g"
// ts-relay Worker — proxies Tailscale through workers.dev
// *.workers.dev is in no_proxy on most corporate machines
const RELAY_HOST   = '__RELAY_HOST__';
const CONTROL_HOST = 'controlplane.tailscale.com';
const LOGIN_HOST   = 'login.tailscale.com';
const DERP_SERVERS = ['derp1.tailscale.com', 'derp2.tailscale.com', 'derp3.tailscale.com'];

export default {
  async fetch(request) {
    const url  = new URL(request.url);
    const path = url.pathname;

    if (path === '/derpmap/default') return derpMap();

    if (path === '/derp' || path.startsWith('/derp?')) {
      const upgrade = (request.headers.get('Upgrade') || '').toLowerCase();
      if (upgrade !== 'websocket')
        return new Response('DERP relay: WebSocket upgrade required', { status: 426 });
      return proxyDerp(request);
    }

    if (path.startsWith('/login') || path.startsWith('/a/') ||
        path.startsWith('/oauth') || path.startsWith('/oidc'))
      return proxyHTTP(request, LOGIN_HOST);

    return proxyHTTP(request, CONTROL_HOST);
  },
};

function derpMap() {
  return new Response(JSON.stringify({
    Version: 2,
    Regions: {
      900: {
        RegionID:   900,
        RegionCode: 'cf-relay',
        RegionName: 'Cloudflare Relay',
        Nodes: [{
          Name:           '900a',
          RegionID:       900,
          HostName:       RELAY_HOST,
          DERPPort:       443,
          STUNPort:       -1,
          ForceWebsocket: true,
        }],
      },
    },
  }), { headers: { 'Content-Type': 'application/json' } });
}

async function proxyHTTP(request, destHost) {
  const url  = new URL(request.url);
  const dest = `https://${destHost}${url.pathname}${url.search}`;
  const headers = new Headers();
  for (const [k, v] of request.headers)
    if (!/^(cf-|x-forwarded-|x-real-ip)/i.test(k)) headers.set(k, v);
  headers.set('Host', destHost);
  try {
    return await fetch(dest, {
      method:   request.method,
      headers,
      body:     ['GET', 'HEAD'].includes(request.method) ? undefined : request.body,
      redirect: 'follow',
    });
  } catch (e) {
    return new Response(`Relay error: ${e.message}`, { status: 502 });
  }
}

async function proxyDerp(request) {
  const pair = new WebSocketPair();
  const [client, server] = Object.values(pair);

  let upstream = null;
  for (const host of DERP_SERVERS) {
    try {
      const resp = await fetch(`https://${host}/derp`, {
        headers: { Upgrade: 'websocket', Connection: 'Upgrade' },
        method:  'GET',
      });
      if (resp.webSocket) { upstream = resp.webSocket; break; }
    } catch (_) {}
  }

  if (!upstream)
    return new Response('Could not reach Tailscale DERP server', { status: 502 });

  server.accept();
  upstream.accept();

  server.addEventListener('message',  e => { try { upstream.send(e.data); } catch (_) {} });
  upstream.addEventListener('message', e => { try { server.send(e.data);   } catch (_) {} });
  server.addEventListener('close',    e => { try { upstream.close(e.code, e.reason); } catch (_) {} });
  upstream.addEventListener('close',  e => { try { server.close(e.code, e.reason);  } catch (_) {} });
  server.addEventListener('error',  () => { try { upstream.close(); } catch (_) {} });
  upstream.addEventListener('error', () => { try { server.close();  } catch (_) {} });

  return new Response(null, { status: 101, webSocket: client });
}
WORKEREOF
}

# ═══════════════════════════════════════════════════════════════════════════
#  Deploy Worker helper (multipart upload via curl -F)
# ═══════════════════════════════════════════════════════════════════════════
deploy_worker() {
    local acct_id="$1" script_name="$2" worker_js="$3"
    local url="${CF_API}/accounts/${acct_id}/workers/scripts/${script_name}"
    local meta="{\"main_module\":\"worker.js\",\"compatibility_date\":\"${COMPAT_DATE}\",\"bindings\":[],\"logpush\":false}"

    local tmpdir
    tmpdir=$(mktemp -d)
    printf '%s' "$meta" > "$tmpdir/meta.json"
    printf '%s' "$worker_js" > "$tmpdir/worker.js"

    local result
    result=$(curl -sk -X PUT \
        -H "Authorization: Bearer $TOKEN" \
        -F "metadata=@$tmpdir/meta.json;type=application/json" \
        -F "worker.js=@$tmpdir/worker.js;type=application/javascript+module" \
        "$url" 2>/dev/null) || result='{"success":false}'

    rm -rf "$tmpdir"

    local success
    success=$(echo "$result" | json_get "success")
    if [ "$success" != "true" ]; then
        err "Worker '$script_name' deploy failed: $(echo "$result" | json_get 'errors')"
        return 1
    fi

    # Enable workers.dev subdomain
    cf_api POST "/accounts/${acct_id}/workers/scripts/${script_name}/subdomain" '{"enabled":true}' >/dev/null 2>&1 || true
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  Account picker (shared by auth + discover)
# ═══════════════════════════════════════════════════════════════════════════
pick_account() {
    # pick_account JSON — sets ACCT_ID, ACCT_NAME from accounts list JSON
    local accounts_json="$1"
    local count
    count=$(echo "$accounts_json" | json_py "
r = d.get('result', [])
print(len(r))")

    if [ "${count:-0}" = "0" ] || [ -z "$count" ]; then
        err "No CF accounts found. Check token permissions."
        return 1
    fi

    if [ "$count" = "1" ]; then
        ACCT_ID=$(echo "$accounts_json" | json_get "result[0].id")
        ACCT_NAME=$(echo "$accounts_json" | json_get "result[0].name")
        ok "Account: $ACCT_NAME"
        return 0
    fi

    printf "\n  ${B}Select account:${X}\n"
    echo "$accounts_json" | json_py "
for i, a in enumerate(d.get('result',[]), 1):
    print(f'  {i}  {a[\"name\"]}  ({a[\"id\"][:8]}...)')"
    printf "\n  Account [1]: "
    read -r choice
    choice="${choice:-1}"
    ACCT_ID=$(echo "$accounts_json" | json_py "print(d['result'][int(sys.argv[1])-1]['id'])" "$choice" 2>/dev/null)
    ACCT_NAME=$(echo "$accounts_json" | json_py "print(d['result'][int(sys.argv[1])-1]['name'])" "$choice" 2>/dev/null)
    [ -z "$ACCT_ID" ] && { ACCT_ID=$(echo "$accounts_json" | json_get "result[0].id"); ACCT_NAME=$(echo "$accounts_json" | json_get "result[0].name"); }
    return 0
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 1 — Authenticate with Cloudflare
# ═══════════════════════════════════════════════════════════════════════════
parse_cert_token() {
    local cert_path="$1"
    [ -f "$cert_path" ] || return 1
    # Extract from PEM SERVICE KEY block
    local b64 raw
    b64=$(sed -n '/-----BEGIN SERVICE KEY-----/,/-----END SERVICE KEY-----/p' "$cert_path" 2>/dev/null \
          | grep -v '^---' | tr -d '\n\r ')
    if [ -n "$b64" ]; then
        raw=$(echo "$b64" | base64 -d 2>/dev/null | tr -d '\0\n\r ')
        if [ -n "$raw" ]; then echo "$raw"; return 0; fi
    fi
    # Try sidecar JSON
    local json_path="${cert_path%.pem}.json"
    if [ -f "$json_path" ]; then
        local tok
        for key in APIToken api_token token; do
            tok=$(cat "$json_path" | json_get "$key")
            [ -n "$tok" ] && { echo "$tok"; return 0; }
        done
    fi
    return 1
}

browser_login() {
    # stdout is captured by caller — all user messages must go to stderr
    ensure_cloudflared || { warn "Cannot open browser login without cloudflared."; return 1; }
    # cloudflared writes cert.pem to ~/.cloudflared/ by default
    local cert_dir="$HOME/.cloudflared"
    local cert_path="$cert_dir/cert.pem"
    # Back up existing cert if present
    [ -f "$cert_path" ] && mv "$cert_path" "${cert_path}.bak" 2>/dev/null
    echo "" >&2
    printf "  ${B}Opening Cloudflare in your browser...${X}\n" >&2
    printf "  ${Y}ACTION REQUIRED:${X} In the browser window that just opened:\n" >&2
    printf "    1. Log in to Cloudflare (if not already)\n" >&2
    printf "    2. Select your account\n" >&2
    printf "    3. Click ${B}Authorize${X}\n" >&2
    printf "\n  ${D}Waiting for browser authorization (up to 5 minutes)...${X}\n\n" >&2
    "$CLOUDFLARED" tunnel login 2>&1 >&2 || true
    if [ ! -f "$cert_path" ]; then
        # Restore backup
        [ -f "${cert_path}.bak" ] && mv "${cert_path}.bak" "$cert_path" 2>/dev/null
        warn "Login did not complete (cert not written)." >&2
        return 1
    fi
    local tok
    tok=$(parse_cert_token "$cert_path")
    # Copy cert to our keys dir for reference, then restore any backup
    mkdir -p "$KEYS_DIR"
    cp "$cert_path" "$KEYS_DIR/cf_login.pem" 2>/dev/null
    rm -f "$cert_path"
    [ -f "${cert_path}.bak" ] && mv "${cert_path}.bak" "$cert_path" 2>/dev/null
    [ -n "$tok" ] && { echo "$tok"; return 0; }
    warn "Could not extract token from cert." >&2
    return 1
}

create_scoped_token() {
    # stdout is captured by caller — all user messages go to stderr
    local broad_token="$1" acct_id="$2"
    # Get permission groups
    local groups_resp
    groups_resp=$(curl -sk \
        -H "Authorization: Bearer $broad_token" \
        -H "Content-Type: application/json" \
        "${CF_API}/user/tokens/permission_groups" 2>/dev/null)
    local pg_acct pg_zone
    pg_acct=$(echo "$groups_resp" | json_py "
needed = ['Cloudflare Tunnel Edit','Workers Script Edit','Zero Trust Edit']
groups = [g for g in d.get('result',[]) if g.get('name') in needed]
import json; print(json.dumps([{'id':g['id']} for g in groups]))")
    pg_zone=$(echo "$groups_resp" | json_py "
needed = ['DNS Write']
groups = [g for g in d.get('result',[]) if g.get('name') in needed]
import json; print(json.dumps([{'id':g['id']} for g in groups]))")

    if [ -z "$pg_acct" ] || [ "$pg_acct" = "[]" ]; then
        warn "Could not resolve CF permission groups." >&2
        return 1
    fi

    # Check for existing portal tokens
    local tokens_resp
    tokens_resp=$(curl -sk \
        -H "Authorization: Bearer $broad_token" \
        -H "Content-Type: application/json" \
        "${CF_API}/user/tokens" 2>/dev/null)
    local existing_count
    existing_count=$(echo "$tokens_resp" | json_py "
ts = [t for t in d.get('result',[]) if t.get('name','').startswith('$PORTAL_TOKEN_NAME')]
print(len(ts))")

    _delete_portal_tokens() {
        echo "$tokens_resp" | json_py "
import urllib.request, json, ssl
ctx = ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
ts = [t for t in d.get('result',[]) if t.get('name','').startswith('$PORTAL_TOKEN_NAME')]
for t in ts:
    req = urllib.request.Request('${CF_API}/user/tokens/'+t['id'], method='DELETE')
    req.add_header('Authorization','Bearer $broad_token')
    req.add_header('Content-Type','application/json')
    try: urllib.request.urlopen(req, context=ctx)
    except: pass
print(len(ts))" >/dev/null
    }

    if [ "${existing_count:-0}" -gt 0 ] && [ -t 0 ]; then
        printf "\n  ${B}Found existing '${PORTAL_TOKEN_NAME}' token(s).${X}\n" >&2
        echo "$tokens_resp" | json_py "
ts = [t for t in d.get('result',[]) if t.get('name','').startswith('$PORTAL_TOKEN_NAME')]
for t in ts:
    exp = (t.get('expiration_date','') or 'no expiry')[:10]
    print(f'    . {t[\"name\"]:<30} {t.get(\"status\",\"\")}  exp: {exp}')" >&2
        printf "\n  ${D}CF never re-exposes token values after creation.${X}\n" >&2
        printf "\n  ${B}1${X}  Paste the existing token value  ${D}(if you still have it)${X}\n" >&2
        printf "  ${B}2${X}  Replace -- delete old token(s) and create a fresh one\n" >&2
        printf "  ${B}3${X}  Create additional token\n" >&2
        printf "\n  [1/2/3]: " >&2
        read -r ch
        case "$ch" in
            1)
                printf "  Paste token value: " >&2
                read -rs tok_val; echo "" >&2
                [ -n "$tok_val" ] && { echo "$tok_val"; return 0; }
                ;;
            2)
                _delete_portal_tokens
                ok "Deleted old portal token(s)." >&2
                ;;
        esac
    elif [ "${existing_count:-0}" -gt 0 ]; then
        # Non-interactive: auto-replace existing tokens
        _delete_portal_tokens
        ok "Replaced existing portal token(s)." >&2
    fi

    # Create scoped token
    printf "\n  Creating '${PORTAL_TOKEN_NAME}' token with permissions:\n" >&2
    printf "  ${D}. Cloudflare Tunnel Edit${X}\n" >&2
    printf "  ${D}. Workers Script Edit${X}\n" >&2
    printf "  ${D}. Zero Trust Edit${X}\n" >&2
    printf "  ${D}. DNS Write (zone-level)${X}\n" >&2

    local payload
    payload=$(python3 -c "
import json, sys
pg_acct = json.loads(sys.argv[1])
pg_zone = json.loads(sys.argv[2])
policies = [{
    'effect': 'allow',
    'resources': {'com.cloudflare.api.account.$acct_id': '*'},
    'permission_groups': pg_acct,
}]
if pg_zone:
    policies.append({
        'effect': 'allow',
        'resources': {'com.cloudflare.api.account.zone.*': '*'},
        'permission_groups': pg_zone,
    })
print(json.dumps({
    'name': '$PORTAL_TOKEN_NAME',
    'policies': policies,
}))" "$pg_acct" "$pg_zone")

    local result
    result=$(curl -sk -X POST \
        -H "Authorization: Bearer $broad_token" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${CF_API}/user/tokens" 2>/dev/null)

    local new_tok
    new_tok=$(echo "$result" | json_get "result.value")
    if [ -n "$new_tok" ]; then
        ok "'${PORTAL_TOKEN_NAME}' token created -- value captured automatically." >&2
        echo "$new_tok"
        return 0
    fi
    warn "Token creation failed." >&2
    return 1
}

_offer_save_token() {
    if [ "$ARG_SAVE_TOKEN" = "true" ]; then
        store_credential "$TOKEN"
        return
    fi
    printf "\n  ${B}Save credentials?${X}\n"
    if [ "$OS" = "darwin" ]; then
        printf "  ${B}1${X}  Yes -- macOS Keychain (encrypted, tied to this login)\n"
    else
        printf "  ${B}1${X}  Yes -- encrypted file in $KEYS_DIR\n"
    fi
    printf "  ${B}2${X}  No  -- session only\n"
    printf "\n  [1/2]: "
    read -r save_choice
    [ "$save_choice" != "2" ] && store_credential "$TOKEN"
}

_verify_token() {
    # _verify_token TOKEN — prints "yes" if token has valid accounts, "no" otherwise
    local tok="$1"
    local verify
    verify=$(curl -sk \
        -H "Authorization: Bearer $tok" \
        -H "Content-Type: application/json" \
        "${CF_API}/accounts" 2>/dev/null)
    echo "$verify" | json_py "print('yes' if len(d.get('result',[])) > 0 else 'no')"
}

_do_cloudflared_login() {
    # cloudflared tunnel login: zone-picker flow → scoped token.
    # Returns 0 on success (TOKEN is set), 1 on failure.
    printf "\n  ${Y}NOTE:${X} This grants a certificate with broad account access.\n" >&2
    printf "  ${D}The script will immediately create a scoped token with only${X}\n" >&2
    printf "  ${D}the required permissions, but the initial cert is overpowered.${X}\n\n" >&2
    local broad
    broad=$(browser_login)
    if [ -z "$broad" ]; then
        return 1
    fi
    # Get account so we can create scoped token
    local accts_resp
    accts_resp=$(curl -sk \
        -H "Authorization: Bearer $broad" \
        -H "Content-Type: application/json" \
        "${CF_API}/accounts" 2>/dev/null)
    if ! pick_account "$accts_resp"; then
        err "No accounts found with this login."
        return 1
    fi
    local scoped
    scoped=$(create_scoped_token "$broad" "$ACCT_ID")
    if [ -n "$scoped" ]; then
        TOKEN="$scoped"
    else
        warn "Could not create scoped token. Using broad login token."
        TOKEN="$broad"
    fi
    _offer_save_token
    return 0
}

_do_dashboard_auth() {
    # Open CF Dashboard API token page + print step-by-step instructions.
    local dashboard_url="https://dash.cloudflare.com/profile/api-tokens"
    printf "\n  ${B}Opening Cloudflare Dashboard...${X}\n\n"

    # Open browser
    if [ "$OS" = "darwin" ]; then
        open "$dashboard_url" 2>/dev/null
    elif command -v xdg-open &>/dev/null; then
        xdg-open "$dashboard_url" 2>/dev/null
    else
        printf "  ${Y}Could not open browser. Go to:${X}\n"
        printf "  ${C}%s${X}\n\n" "$dashboard_url"
    fi

    printf "  ${B}Create your API token — step by step:${X}\n\n"
    printf "  ${C}1.${X} Click ${B}Create Token${X}\n"
    printf "  ${C}2.${X} At the top, click ${B}Get started${X} next to Custom Token\n"
    printf "  ${C}3.${X} Token name: ${B}ssh-portal${X}\n"
    printf "  ${C}4.${X} Add these permissions (click ${B}+ Add more${X} for each):\n\n"
    printf "       ${D}Scope${X}      ${D}Resource${X}                    ${D}Access${X}\n"
    printf "       Account    Cloudflare Tunnel           Edit\n"
    printf "       Account    Workers Scripts              Edit\n"
    printf "       Account    Zero Trust                   Edit\n"
    printf "       Zone       DNS                          Edit\n\n"
    printf "  ${C}5.${X} Account Resources: ${B}All accounts${X} (or pick yours)\n"
    printf "  ${C}6.${X} Zone Resources: ${B}All zones${X} (or pick your domain)\n"
    printf "  ${C}7.${X} Click ${B}Continue to summary${X} -> ${B}Create Token${X}\n"
    printf "  ${C}8.${X} ${B}Copy the token${X} and paste it below\n"
    printf "     ${D}(CF only shows it once — copy it now!)${X}\n"

    printf "\n  Paste token: "
    read -rs tok; echo ""
    [ -z "$tok" ] && { err "No token provided."; exit 1; }
    TOKEN="$tok"
    if [ "$(_verify_token "$TOKEN")" != "yes" ]; then
        err "Token is invalid (no accounts found). Check permissions and try again."
        exit 1
    fi
    ok "Token verified."
    _offer_save_token
}

step_auth() {
    hdr "Step 1: Authenticate with Cloudflare"

    # --cf-token flag: direct token, skip all interactive auth
    if [ -n "$ARG_CF_TOKEN" ]; then
        TOKEN="$ARG_CF_TOKEN"
        if [ "$(_verify_token "$TOKEN")" != "yes" ]; then
            err "Provided --cf-token is invalid (no accounts found)."
            exit 1
        fi
        ok "Token verified via --cf-token."
        [ "$ARG_SAVE_TOKEN" = "true" ] && store_credential "$TOKEN"
        return
    fi

    # Try stored credential
    local stored
    stored=$(load_credential)
    if [ -n "$stored" ]; then
        if [ "$(_verify_token "$stored")" = "yes" ]; then
            ok "Using stored Cloudflare credentials."
            TOKEN="$stored"
            return
        fi
        warn "Stored token could not be verified -- re-authenticating."
    fi

    # Show auth options
    printf "\n  ${B}Authentication method:${X}\n\n"
    printf "  ${B}1${X}  Open CF Dashboard + paste token  ${G}(recommended)${X}\n"
    printf "     ${D}Opens the token creation page with step-by-step instructions.${X}\n"
    printf "     ${D}You create a token scoped to exactly the permissions needed.${X}\n\n"
    printf "  ${B}2${X}  Paste an existing API token\n"
    printf "     ${D}If you already created a token with the right permissions.${X}\n\n"
    printf "  ${B}3${X}  cloudflared tunnel login  ${D}(power users)${X}\n"
    printf "     ${D}Opens a zone selector. Grants a broad cert, then auto-creates${X}\n"
    printf "     ${D}a scoped token. Requires a domain on your CF account.${X}\n"

    # If running with flags (semi-automated), default to dashboard
    local method
    if [ ${#ARG_EMAILS[@]} -gt 0 ] || ! [ -t 0 ]; then
        method="1"
        printf "\n  ${G}-->  Using option 1 (dashboard + paste)${X}\n"
    else
        printf "\n  [1/2/3]: "
        read -r method
        method="${method:-1}"
    fi

    case "$method" in
        2)
            printf "\n  Paste your CF API token: "
            read -rs tok; echo ""
            [ -z "$tok" ] && { err "No token provided."; exit 1; }
            TOKEN="$tok"
            if [ "$(_verify_token "$TOKEN")" != "yes" ]; then
                err "Token is invalid. Check permissions."
                exit 1
            fi
            ok "Token verified."
            _offer_save_token
            ;;
        3)
            if ! _do_cloudflared_login; then
                warn "cloudflared login failed. Try option 1 instead."
                _do_dashboard_auth
            fi
            ;;
        *)
            _do_dashboard_auth
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 2 — Discover account + workers.dev subdomain
# ═══════════════════════════════════════════════════════════════════════════
step_discover() {
    hdr "Step 2: Discover account & workers.dev subdomain"
    local accts_resp
    accts_resp=$(cf_api GET "/accounts")
    if ! pick_account "$accts_resp"; then
        exit 1
    fi

    # Get workers.dev subdomain
    local sub_resp
    sub_resp=$(cf_api GET "/accounts/${ACCT_ID}/workers/subdomain")
    SUBDOMAIN=$(echo "$sub_resp" | json_get "result.subdomain")
    if [ -z "$SUBDOMAIN" ]; then
        warn "Could not fetch workers.dev subdomain automatically."
        printf "  Enter your workers.dev subdomain (e.g. 'alice'): "
        read -r SUBDOMAIN
    fi
    ok "workers.dev subdomain: ${SUBDOMAIN}.workers.dev"
    ok "Account: $ACCT_NAME (${ACCT_ID:0:8}...)"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 3 — Tunnel
# ═══════════════════════════════════════════════════════════════════════════
step_tunnel() {
    hdr "Step 3: CF Tunnel"
    local r
    r=$(cf_api GET "/accounts/${ACCT_ID}/cfd_tunnel?name=${TUNNEL_NAME}")

    # Find existing non-deleted tunnel
    local existing_id
    existing_id=$(echo "$r" | json_py "
r = d.get('result', [])
t = next((x for x in r if x.get('name') == '$TUNNEL_NAME' and not x.get('deleted_at')), None)
print(t['id'] if t else '')")

    if [ -n "$existing_id" ]; then
        TUNNEL_ID="$existing_id"
        ok "Found existing tunnel '${TUNNEL_NAME}': ${TUNNEL_ID:0:8}..."
        # Try to get token
        local tok_resp
        tok_resp=$(cf_api GET "/accounts/${ACCT_ID}/cfd_tunnel/${TUNNEL_ID}/token")
        TUNNEL_TOKEN=$(echo "$tok_resp" | json_get "result")
        return
    fi

    printf "  Creating tunnel '${TUNNEL_NAME}'...\n"
    local secret
    secret=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)
    local create_data
    create_data=$(python3 -c "import json; print(json.dumps({'name':'$TUNNEL_NAME','tunnel_secret':'$secret','config_src':'cloudflare'}))")
    r=$(cf_api POST "/accounts/${ACCT_ID}/cfd_tunnel" "$create_data")

    local success
    success=$(echo "$r" | json_get "success")
    if [ "$success" != "true" ]; then
        err "Failed to create tunnel: $(echo "$r" | json_get 'errors')"
        exit 1
    fi

    TUNNEL_ID=$(echo "$r" | json_get "result.id")
    TUNNEL_TOKEN=$(echo "$r" | json_get "result.token")
    ok "Tunnel '${TUNNEL_NAME}' created: ${TUNNEL_ID:0:8}..."

    # Retrieve token if not in creation response
    if [ -z "$TUNNEL_TOKEN" ]; then
        local tok_resp
        tok_resp=$(cf_api GET "/accounts/${ACCT_ID}/cfd_tunnel/${TUNNEL_ID}/token")
        TUNNEL_TOKEN=$(echo "$tok_resp" | json_get "result")
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 4 — Domain & DNS
# ═══════════════════════════════════════════════════════════════════════════
step_domain() {
    hdr "Step 4: Domain & DNS"

    # If --domain was passed, use it; otherwise try config
    if [ -n "$DOMAIN" ]; then
        ok "Using domain: $DOMAIN"
    else
        local cfg_domain
        cfg_domain=$(config_val 'domain')
        if [ -n "$cfg_domain" ]; then
            DOMAIN="$cfg_domain"
            ok "Domain from config: $DOMAIN"
        fi
    fi

    # List zones on the account
    local r
    r=$(cf_api GET "/zones?account.id=${ACCT_ID}&status=active&per_page=50")

    local zone_count
    zone_count=$(echo "$r" | json_py "print(len(d.get('result',[])))")

    if [ "${zone_count:-0}" = "0" ] || [ -z "$zone_count" ]; then
        printf "\n"
        err "No domains found on this Cloudflare account."
        printf "\n"
        printf "  ${B}You need a domain on Cloudflare to route SSH traffic.${X}\n"
        printf "  This is the one prerequisite beyond a free CF account.\n\n"
        printf "  ${C}Cheapest option (~\$1/year):${X}\n"
        printf "    1. Go to ${B}https://dash.cloudflare.com/?to=/:account/domains/register${X}\n"
        printf "    2. Search for a cheap domain (e.g. yourname.xyz)\n"
        printf "    3. Buy it -- CF Registrar charges at-cost, no markup\n\n"
        printf "  ${C}Or bring your own domain:${X}\n"
        printf "    1. Go to ${B}https://dash.cloudflare.com/?to=/:account/add-site${X}\n"
        printf "    2. Add your domain and follow the nameserver instructions\n"
        printf "    3. Wait for the domain to become active (usually minutes)\n\n"
        printf "  Then re-run this bootstrap.\n"
        exit 1
    fi

    if [ -z "$DOMAIN" ]; then
        if [ "$zone_count" = "1" ]; then
            DOMAIN=$(echo "$r" | json_get "result[0].name")
            ZONE_ID=$(echo "$r" | json_get "result[0].id")
            ok "Auto-selected domain: $DOMAIN (only zone on account)"
        elif ! [ -t 0 ]; then
            # Non-interactive: auto-select first domain
            DOMAIN=$(echo "$r" | json_get "result[0].name")
            ZONE_ID=$(echo "$r" | json_get "result[0].id")
            ok "Auto-selected domain: $DOMAIN (non-interactive mode)"
        else
            printf "\n  ${B}Select a domain for SSH access:${X}\n"
            echo "$r" | json_py "
for i, z in enumerate(d.get('result',[]), 1):
    print(f'  {i}  {z[\"name\"]}')"
            printf "\n  Domain [1]: "
            read -r choice
            choice="${choice:-1}"
            DOMAIN=$(echo "$r" | json_py "print(d['result'][int(sys.argv[1])-1]['name'])" "$choice" 2>/dev/null)
            ZONE_ID=$(echo "$r" | json_py "print(d['result'][int(sys.argv[1])-1]['id'])" "$choice" 2>/dev/null)
            [ -z "$DOMAIN" ] && { DOMAIN=$(echo "$r" | json_get "result[0].name"); ZONE_ID=$(echo "$r" | json_get "result[0].id"); }
        fi
    fi

    # Get zone ID if not yet set
    if [ -z "$ZONE_ID" ]; then
        ZONE_ID=$(echo "$r" | json_py "
z = next((z for z in d.get('result',[]) if z.get('name')=='$DOMAIN'), None)
print(z['id'] if z else '')")
    fi

    if [ -z "$ZONE_ID" ]; then
        err "Could not find zone ID for domain '$DOMAIN'."
        err "Make sure the domain is added to your CF account and is active."
        exit 1
    fi

    SSH_HOST="ssh.${DOMAIN}"
    ok "SSH hostname: $SSH_HOST"

    APP_HOST="app.${DOMAIN}"
    ok "App hostname: $APP_HOST"

    # Create DNS CNAME: ssh.domain -> TUNNEL_ID.cfargotunnel.com (proxied)
    local dns_r
    dns_r=$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=CNAME&name=${SSH_HOST}")
    local existing_dns
    existing_dns=$(echo "$dns_r" | json_py "
recs = d.get('result',[])
rec = next((r for r in recs if r.get('name')=='$SSH_HOST'), None)
print(rec['id'] if rec else '')")

    local cname_target="${TUNNEL_ID}.cfargotunnel.com"

    if [ -n "$existing_dns" ]; then
        # Update existing record to point to current tunnel
        cf_api PUT "/zones/${ZONE_ID}/dns_records/${existing_dns}" \
            "{\"type\":\"CNAME\",\"name\":\"ssh\",\"content\":\"${cname_target}\",\"proxied\":true}" >/dev/null
        ok "DNS CNAME updated: $SSH_HOST -> $cname_target (proxied)"
    else
        local dns_payload="{\"type\":\"CNAME\",\"name\":\"ssh\",\"content\":\"${cname_target}\",\"proxied\":true}"
        local dns_result
        dns_result=$(cf_api POST "/zones/${ZONE_ID}/dns_records" "$dns_payload")
        local success
        success=$(echo "$dns_result" | json_get "success")
        if [ "$success" = "true" ]; then
            ok "DNS CNAME created: $SSH_HOST -> $cname_target (proxied)"
        else
            warn "DNS record creation failed: $(echo "$dns_result" | json_get 'errors')"
            warn "You may need to add DNS Edit permission to your API token."
            warn "Create it manually: CNAME  ssh  ->  ${cname_target}  (proxied/orange cloud)"
        fi
    fi

    # Create DNS CNAME: app.domain -> TUNNEL_ID.cfargotunnel.com (proxied)
    local app_dns_r
    app_dns_r=$(cf_api GET "/zones/${ZONE_ID}/dns_records?type=CNAME&name=${APP_HOST}")
    local existing_app_dns
    existing_app_dns=$(echo "$app_dns_r" | json_py "
recs = d.get('result',[])
rec = next((r for r in recs if r.get('name')=='$APP_HOST'), None)
print(rec['id'] if rec else '')")

    if [ -n "$existing_app_dns" ]; then
        # Update existing record to point to current tunnel
        cf_api PUT "/zones/${ZONE_ID}/dns_records/${existing_app_dns}" \
            "{\"type\":\"CNAME\",\"name\":\"app\",\"content\":\"${cname_target}\",\"proxied\":true}" >/dev/null
        ok "DNS CNAME updated: $APP_HOST -> $cname_target (proxied)"
    else
        local app_dns_payload="{\"type\":\"CNAME\",\"name\":\"app\",\"content\":\"${cname_target}\",\"proxied\":true}"
        local app_dns_result
        app_dns_result=$(cf_api POST "/zones/${ZONE_ID}/dns_records" "$app_dns_payload")
        local success
        success=$(echo "$app_dns_result" | json_get "success")
        if [ "$success" = "true" ]; then
            ok "DNS CNAME created: $APP_HOST -> $cname_target (proxied)"
        else
            warn "DNS record creation failed: $(echo "$app_dns_result" | json_get 'errors')"
            warn "You may need to add DNS Edit permission to your API token."
            warn "Create it manually: CNAME  app  ->  ${cname_target}  (proxied/orange cloud)"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 5 — Tunnel ingress
# ═══════════════════════════════════════════════════════════════════════════
step_ingress() {
    hdr "Step 5: Tunnel ingress rules"
    local cfg_url="/accounts/${ACCT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations"

    local r
    r=$(cf_api GET "$cfg_url")

    # Check if SSH ingress already exists
    local has_ssh
    has_ssh=$(echo "$r" | json_py "
ingress = d.get('result',{}).get('config',{}).get('ingress',[])
ssh_rule = next((x for x in ingress if isinstance(x,dict) and x.get('hostname')=='$SSH_HOST'), None)
print('yes' if ssh_rule else 'no')")

    # Load Access config if available
    local cfg_ssh_aud cfg_team
    cfg_ssh_aud=$(config_val "ssh_app_aud")
    cfg_team=$(config_val "team_name")

    if [ "$has_ssh" = "yes" ]; then
        local has_access
        has_access=$(echo "$r" | json_py "
ingress = d.get('result',{}).get('config',{}).get('ingress',[])
ssh_rule = next((x for x in ingress if isinstance(x,dict) and x.get('hostname')=='$SSH_HOST'), None)
print('yes' if ssh_rule and ssh_rule.get('originRequest',{}).get('access') else 'no')")
        if [ "$has_access" = "yes" ] || [ -z "$cfg_ssh_aud" ]; then
            ok "Tunnel ingress already configured."
            return
        fi
        printf "  Upgrading ingress with Access JWT validation...\n"
    fi

    # Build ingress rules
    local ingress_json
    if [ -n "$cfg_ssh_aud" ] && [ -n "$cfg_team" ]; then
        ingress_json=$(python3 -c "
import json
rules = [
    {'hostname': '$APP_HOST', 'service': 'http://localhost:7681'},
    {'hostname': '$SSH_HOST', 'service': 'ssh://localhost:22',
     'originRequest': {'access': {'required': True, 'teamName': '$cfg_team', 'audTag': ['$cfg_ssh_aud']}}},
    {'service': 'http_status:404'}
]
print(json.dumps({'config': {'ingress': rules}}))")
    else
        ingress_json=$(python3 -c "
import json
rules = [
    {'hostname': '$APP_HOST', 'service': 'http://localhost:7681'},
    {'hostname': '$SSH_HOST', 'service': 'ssh://localhost:22'},
    {'service': 'http_status:404'}
]
print(json.dumps({'config': {'ingress': rules}}))")
    fi

    local r2
    r2=$(cf_api PUT "$cfg_url" "$ingress_json")
    local success
    success=$(echo "$r2" | json_get "success")
    if [ "$success" = "true" ]; then
        ok "Ingress set: $APP_HOST -> http://localhost:7681"
        ok "Ingress set: $SSH_HOST -> ssh://localhost:22"
        [ -n "$cfg_ssh_aud" ] && ok "Access JWT validation enabled (team: $cfg_team)"
        ok "cloudflared on the home machine will pick this up automatically."
    else
        warn "Ingress update failed: $(echo "$r2" | json_get 'errors')"
        warn "You may need to update your cloudflared config manually."
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 6 — CF Access (Zero Trust)
# ═══════════════════════════════════════════════════════════════════════════
ensure_org() {
    local r
    r=$(cf_api GET "/accounts/${ACCT_ID}/access/organizations")
    local has_org
    has_org=$(echo "$r" | json_py "print('yes' if d.get('success') and d.get('result') else 'no')")
    if [ "$has_org" = "yes" ]; then
        TEAM_NAME=$(echo "$r" | json_py "
ad = d.get('result',{}).get('auth_domain','')
print(ad.replace('.cloudflareaccess.com',''))")
        ok "Zero Trust org exists (team: $TEAM_NAME)"
        return 0
    fi

    printf "  Creating Zero Trust organization...\n"
    local org_name="${ACCT_NAME:-erebus}"
    org_name=$(echo "$org_name" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    local payload
    payload=$(python3 -c "
import json; print(json.dumps({
    'name': '$org_name',
    'auth_domain': '${org_name}.cloudflareaccess.com',
    'login_design': {},
    'is_ui_read_only': False
}))")
    r=$(cf_api PUT "/accounts/${ACCT_ID}/access/organizations" "$payload")
    local success
    success=$(echo "$r" | json_get "success")
    if [ "$success" = "true" ]; then
        TEAM_NAME="$org_name"
        ok "Created Zero Trust org: $org_name"
        return 0
    fi
    # Check if Access is not enabled yet
    local err_str
    err_str=$(echo "$r" | json_py "
errs = d.get('errors', [])
print(' '.join(str(e.get('message','')) if isinstance(e,dict) else str(e) for e in errs))")
    if echo "$err_str" | grep -qi "not.enabled\|not_enabled"; then
        _zt_enrollment_guide
        return $?
    fi

    warn "Zero Trust org setup failed: $(echo "$r" | json_get 'errors')"
    return 1
}

# ── Zero Trust enrollment walkthrough ─────────────────────────────────────────
_zt_enrollment_guide() {
    printf "\n"
    warn "Zero Trust is not enabled on this Cloudflare account yet."
    printf "  You need to enroll in Zero Trust (free plan available).\n\n"
    printf "  ${B}How to enable Zero Trust — step by step:${X}\n\n"
    printf "  ${C}1.${X} Go to ${B}https://one.dash.cloudflare.com${X}\n"
    printf "     (or in the CF Dashboard sidebar, click ${B}Zero Trust${X})\n"
    printf "  ${C}2.${X} Pick a ${B}team name${X} (subdomain for your auth portal)\n"
    printf "     Example: ${C}erebus-edge${X} -> erebus-edge.cloudflareaccess.com\n"
    printf "  ${C}3.${X} Select the ${B}Free${X} plan (covers everything we need)\n"
    printf "  ${C}4.${X} Add a payment method (you will ${B}not be charged${X} — \$0)\n"
    printf "  ${C}5.${X} Click ${B}Purchase${X} on the review page\n"
    printf "  ${C}6.${X} You should see ${B}\"Successfully updated plan\"${X}\n\n"

    # If running non-interactively, just fail with instructions
    if [ ! -t 0 ]; then
        printf "  Re-run this script after completing the steps above.\n"
        return 1
    fi

    printf "  ${Y}Press Enter after you've completed these steps (or 'q' to skip)...${X} "
    local reply
    read -r reply
    if [ "$reply" = "q" ] || [ "$reply" = "Q" ]; then
        return 1
    fi

    # Retry org creation
    printf "  Retrying Zero Trust setup...\n"
    local r
    r=$(cf_api GET "/accounts/${ACCT_ID}/access/organizations")
    local has_org
    has_org=$(echo "$r" | json_py "print('yes' if d.get('success') and d.get('result') else 'no')")
    if [ "$has_org" = "yes" ]; then
        TEAM_NAME=$(echo "$r" | json_py "
ad = d.get('result',{}).get('auth_domain','')
print(ad.replace('.cloudflareaccess.com',''))")
        ok "Zero Trust org exists (team: $TEAM_NAME)"
        return 0
    fi

    # Try creating
    local org_name="${ACCT_NAME:-erebus}"
    org_name=$(echo "$org_name" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    local payload
    payload=$(python3 -c "
import json; print(json.dumps({
    'name': '$org_name',
    'auth_domain': '${org_name}.cloudflareaccess.com',
    'login_design': {},
    'is_ui_read_only': False
}))")
    r=$(cf_api PUT "/accounts/${ACCT_ID}/access/organizations" "$payload")
    local success
    success=$(echo "$r" | json_get "success")
    if [ "$success" = "true" ]; then
        TEAM_NAME="$org_name"
        ok "Created Zero Trust org: $org_name"
        return 0
    fi

    warn "Zero Trust org setup still failed: $(echo "$r" | json_get 'errors')"
    printf "  Try visiting https://one.dash.cloudflare.com and ensure enrollment completed.\n"
    return 1
}

ensure_otp_idp() {
    local r
    r=$(cf_api GET "/accounts/${ACCT_ID}/access/identity_providers")
    local has_otp
    has_otp=$(echo "$r" | json_py "
otp = next((i for i in d.get('result',[]) if i.get('type')=='onetimepin'), None)
print('yes' if otp else 'no')")
    if [ "$has_otp" = "yes" ]; then
        ok "Email OTP identity provider already exists."
        return
    fi
    printf "  Adding email OTP identity provider...\n"
    r=$(cf_api POST "/accounts/${ACCT_ID}/access/identity_providers" \
        '{"name":"Email OTP","type":"onetimepin","config":{}}')
    local success
    success=$(echo "$r" | json_get "success")
    [ "$success" = "true" ] && ok "Created email OTP IDP." || warn "Could not create OTP IDP."
}

ensure_app() {
    local hostname="$1" name="$2" app_type="${3:-ssh}" session_duration="${4:-24h}"

    # Check existing
    local r
    r=$(cf_api GET "/accounts/${ACCT_ID}/access/apps")
    local existing
    existing=$(echo "$r" | json_py "
app = next((a for a in d.get('result',[]) if a.get('domain')=='$hostname'), None)
if app: print(app['id'] + '|' + app.get('aud',''))
else: print('')")

    if [ -n "$existing" ]; then
        local app_id="${existing%%|*}"
        SSH_APP_AUD="${existing##*|}"
        ok "Access app '$name' already exists: $app_id" >&2
        echo "$app_id"
        return 0
    fi

    printf "  Creating Access app for $hostname (type: $app_type) ...\n" >&2
    local payload
    payload=$(python3 -c "
import json; d = {
    'name': '$name', 'domain': '$hostname', 'type': '$app_type',
    'session_duration': '$session_duration', 'allowed_idps': [],
    'auto_redirect_to_identity': True, 'app_launcher_visible': True,
}
if '$app_type' == 'ssh':
    d['enable_binding_cookie'] = False
    d['http_only_cookie_attribute'] = False
else:
    d['http_only_cookie_attribute'] = True
    d['same_site_cookie_attribute'] = 'lax'
print(json.dumps(d))")

    r=$(cf_api POST "/accounts/${ACCT_ID}/access/apps" "$payload")
    local success
    success=$(echo "$r" | json_get "success")
    if [ "$success" = "true" ]; then
        local app_id
        app_id=$(echo "$r" | json_get "result.id")
        SSH_APP_AUD=$(echo "$r" | json_get "result.aud")
        ok "Created Access app: $app_id" >&2
        echo "$app_id"
        return 0
    fi
    warn "Could not create Access app: $(echo "$r" | json_get 'errors')" >&2
    return 1
}

ensure_policy() {
    local app_id="$1"
    shift
    local emails=("$@")

    # Check existing
    local r
    r=$(cf_api GET "/accounts/${ACCT_ID}/access/apps/${app_id}/policies")
    local has_policy
    has_policy=$(echo "$r" | json_py "print('yes' if d.get('success') and d.get('result') else 'no')")
    if [ "$has_policy" = "yes" ]; then
        ok "Access policies already exist for app $app_id"
        return
    fi

    printf "  Creating email Allow policy for ${#emails[@]} email(s)...\n"
    local email_rules
    email_rules=$(python3 -c "
import json, sys
emails = sys.argv[1:]
rules = [{'email': {'email': e}} for e in emails]
print(json.dumps(rules))" "${emails[@]}")

    local payload
    payload="{\"name\":\"Allow authorised users\",\"decision\":\"allow\",\"include\":${email_rules},\"require\":[],\"exclude\":[],\"precedence\":1}"

    r=$(cf_api POST "/accounts/${ACCT_ID}/access/apps/${app_id}/policies" "$payload")
    local success
    success=$(echo "$r" | json_get "success")
    [ "$success" = "true" ] && ok "Policy created." || warn "Could not create policy."
}

ensure_ssh_ca() {
    local app_id="$1"
    # Try existing
    local r
    r=$(cf_api GET "/accounts/${ACCT_ID}/access/apps/${app_id}/ca")
    local pub_key
    pub_key=$(echo "$r" | json_get "result.public_key")
    if [ -n "$pub_key" ]; then
        ok "SSH CA already exists."
        SSH_CA_KEY="$pub_key"
        return 0
    fi
    printf "  Generating short-lived SSH certificate CA...\n"
    r=$(cf_api POST "/accounts/${ACCT_ID}/access/apps/${app_id}/ca")
    pub_key=$(echo "$r" | json_get "result.public_key")
    if [ -n "$pub_key" ]; then
        ok "SSH CA generated."
        SSH_CA_KEY="$pub_key"
        return 0
    fi
    warn "Could not generate SSH CA."
    return 1
}

step_access() {
    local -a emails=("$@")
    hdr "Step 6: CF Zero Trust Access (OTP email + browser SSH + short-lived certs)"

    if [ ${#emails[@]} -eq 0 ]; then
        printf "  ${D}Skipped (no emails provided).${X}\n"
        return
    fi

    if ! ensure_org; then
        warn "Zero Trust org setup failed. Skipping Access policies."
        warn "Make sure token has 'Zero Trust Edit' permission."
        return
    fi

    ensure_otp_idp

    # SSH app
    local ssh_app_id
    ssh_app_id=$(ensure_app "$SSH_HOST" "SSH Browser Terminal" "ssh" "24h")
    if [ -n "$ssh_app_id" ]; then
        ensure_policy "$ssh_app_id" "${emails[@]}"
        if ensure_ssh_ca "$ssh_app_id"; then
            save_config "{\"ssh_ca_public_key\":\"${SSH_CA_KEY}\",\"ssh_app_aud\":\"${SSH_APP_AUD}\",\"team_name\":\"${TEAM_NAME}\"}"
            ok "SSH short-lived certificate CA generated and saved"
        fi
    fi

    # Browser Terminal app (self_hosted, not ssh)
    if [ -n "$APP_HOST" ]; then
        local app_app_id
        app_app_id=$(ensure_app "$APP_HOST" "Browser Terminal" "self_hosted" "24h")
        if [ -n "$app_app_id" ]; then
            ensure_policy "$app_app_id" "${emails[@]}"
            # Add service token non_identity policy for Worker access
            if [ -n "$SVC_TOKEN_ID" ]; then
                local svc_r
                svc_r=$(cf_api GET "/accounts/${ACCT_ID}/access/apps/${app_app_id}/policies")
                local has_svc_policy
                has_svc_policy=$(echo "$svc_r" | json_py "
policies = d.get('result',[])
print('yes' if any(p.get('name')=='Service Token Access' for p in policies) else 'no')")
                if [ "$has_svc_policy" != "yes" ]; then
                    printf "  Creating service token non_identity policy...\n"
                    local svc_payload
                    svc_payload="{\"name\":\"Service Token Access\",\"decision\":\"non_identity\",\"include\":[{\"service_token\":{\"token_id\":\"${SVC_TOKEN_ID}\"}}],\"require\":[],\"exclude\":[],\"precedence\":2}"
                    local svc_result
                    svc_result=$(cf_api POST "/accounts/${ACCT_ID}/access/apps/${app_app_id}/policies" "$svc_payload")
                    local success
                    success=$(echo "$svc_result" | json_get "success")
                    [ "$success" = "true" ] && ok "Service token policy created." || warn "Could not create service token policy."
                else
                    ok "Service token policy already exists."
                fi
            fi
        fi
    fi

    ok "CF Access configured."
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 7 — Deploy ts-relay Worker
# ═══════════════════════════════════════════════════════════════════════════
step_ts_relay() {
    hdr "Step 7: Deploy ts-relay Worker (Tailscale bypass)"
    local relay_host="ts-relay.${SUBDOMAIN}.workers.dev"
    local relay_url="https://${relay_host}"

    local js
    js=$(generate_ts_relay_worker_js "$relay_host")

    printf "  Deploying 'ts-relay' Worker ... "
    if deploy_worker "$ACCT_ID" "ts-relay" "$js"; then
        printf "${G}OK${X}  ->  ${relay_url}\n"
        ok "Tailscale control plane + DERP proxied through workers.dev"
        save_config "{\"ts_relay_url\":\"${relay_url}\"}"
    else
        printf "${R}FAILED${X}\n"
        warn "ts-relay deploy failed."
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 8 — Deploy edge-sync Worker (browser terminal + tunnel proxy)
# ═══════════════════════════════════════════════════════════════════════════
generate_edge_sync_worker_js() {
    local app_host="$1" ssh_host="$2" svc_id="$3" svc_secret="$4"
    cat << 'EDGESYNCEOF' | sed \
        -e "s|__APP_HOST__|${app_host}|g" \
        -e "s|__SSH_HOST__|${ssh_host}|g" \
        -e "s|__SVC_TOKEN_ID__|${svc_id}|g" \
        -e "s|__SVC_TOKEN_SECRET__|${svc_secret}|g"
// edge-sync Worker — browser terminal + tunnel proxy
const APP_HOST       = '__APP_HOST__';
const SSH_HOST       = '__SSH_HOST__';
const SVC_TOKEN_ID   = '__SVC_TOKEN_ID__';
const SVC_TOKEN_SEC  = '__SVC_TOKEN_SECRET__';

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const ua  = (request.headers.get('User-Agent') || '');
    const isCloudflareDaemon = ua.includes('cloudflared') || ua.includes('Go-http-client');

    // Route cloudflared requests to SSH tunnel
    const targetHost = isCloudflareDaemon ? SSH_HOST : APP_HOST;
    const dest = new URL(request.url);
    dest.hostname = targetHost;
    dest.port = '';
    dest.protocol = 'https:';

    const headers = new Headers(request.headers);
    headers.set('Host', targetHost);
    headers.set('CF-Access-Client-Id', SVC_TOKEN_ID);
    headers.set('CF-Access-Client-Secret', SVC_TOKEN_SEC);

    const resp = await fetch(dest.toString(), {
      method:  request.method,
      headers,
      body:    ['GET', 'HEAD'].includes(request.method) ? undefined : request.body,
      redirect: 'manual',
    });

    // Pass WebSocket upgrades through directly
    if (resp.webSocket) return resp;

    // Rewrite redirects to stay on the Worker domain
    if ([301, 302, 303, 307, 308].includes(resp.status)) {
      const loc = resp.headers.get('Location');
      if (loc) {
        const locUrl = new URL(loc, dest.toString());
        if (locUrl.hostname === targetHost) {
          locUrl.hostname = url.hostname;
          locUrl.protocol = url.protocol;
          const newHeaders = new Headers(resp.headers);
          newHeaders.set('Location', locUrl.toString());
          return new Response(resp.body, {
            status: resp.status,
            statusText: resp.statusText,
            headers: newHeaders,
          });
        }
      }
    }

    // Rewrite HTML: title + inject paste button
    const ct = (resp.headers.get('Content-Type') || '');
    if (ct.includes('text/html')) {
      let body = await resp.text();
      body = body.replace(/ttyd - Terminal/g, 'Edge Sync - Dashboard');
      body = body.replace(/ttyd/gi, 'app');
      const pasteUI = '<div id="eb-ui" style="position:fixed;top:8px;right:8px;z-index:9999"><button onclick="ebOpen()" style="background:#333;color:#ccc;border:1px solid #555;border-radius:4px;padding:4px 10px;font-size:12px;cursor:pointer;font-family:monospace" title="Paste text into terminal">📝 Text</button></div><script>function ebSend(t){if(!t)return;if(window.term&&window.term.paste){window.term.paste(t)}else if(window.term&&window.term.input){window.term.input(t)}}function ebOpen(){var o=document.createElement("div");o.style.cssText="position:fixed;inset:0;background:rgba(0,0,0,0.7);z-index:9999";var ta=document.createElement("textarea");ta.style.cssText="position:fixed;top:50%;left:50%;transform:translate(-50%,-50%);width:60%;height:40%;z-index:10000;background:#1e1e1e;color:#0f0;border:2px solid #555;border-radius:8px;padding:12px;font-family:monospace;font-size:14px;resize:none";ta.placeholder="Paste or type here, then click Send";var b=document.createElement("button");b.textContent="Send to terminal";b.style.cssText="position:fixed;top:calc(50% + 22%);left:50%;transform:translateX(-50%);z-index:10001;background:#2a6;color:#fff;border:none;border-radius:4px;padding:8px 20px;cursor:pointer;font-size:14px";var cl=function(){o.remove();ta.remove();b.remove()};o.onclick=cl;b.onclick=function(){if(ta.value)ebSend(ta.value);cl()};ta.addEventListener("keydown",function(e){if(e.key==="Escape")cl()});document.body.append(o,ta,b);ta.focus()}(function f(){if(window.term)return;try{var el=document.querySelector(".xterm");if(el&&el._core){window.term=el._core._terminal||el._core;return}}catch(e){}setTimeout(f,1000)})();</script>';
      body = body.replace('</body>', pasteUI + '</body>');
      const newHeaders = new Headers(resp.headers);
      newHeaders.delete('Content-Length');
      return new Response(body, {
        status: resp.status,
        statusText: resp.statusText,
        headers: newHeaders,
      });
    }

    return resp;
  },
};
EDGESYNCEOF
}

step_edge_sync() {
    hdr "Step 8: Deploy edge-sync Worker (browser terminal proxy)"

    # ── Create CF Access service token ────────────────────────────────
    printf "  Checking for existing service token...\n"
    local r
    r=$(cf_api GET "/accounts/${ACCT_ID}/access/service_tokens")
    local existing_token
    existing_token=$(echo "$r" | json_py "
st = next((t for t in d.get('result',[]) if t.get('name')=='edge-sync-worker'), None)
print(st['client_id'] if st else '')")

    if [ -n "$existing_token" ]; then
        SVC_TOKEN_ID="$existing_token"
        ok "Service token 'edge-sync-worker' already exists (client_id: ${SVC_TOKEN_ID:0:8}...)"
        # Try to load secret from config (CF only returns it on creation)
        if [ -z "$SVC_TOKEN_SECRET" ]; then
            SVC_TOKEN_SECRET=$(config_val "service_token_secret")
        fi
        if [ -z "$SVC_TOKEN_SECRET" ]; then
            warn "Service token secret not in config -- cannot update. Delete and re-create if needed."
        fi
    else
        printf "  Creating service token 'edge-sync-worker'...\n"
        local st_payload='{"name":"edge-sync-worker","duration":"8760h"}'
        local st_resp
        st_resp=$(cf_api POST "/accounts/${ACCT_ID}/access/service_tokens" "$st_payload")
        local success
        success=$(echo "$st_resp" | json_get "success")
        if [ "$success" = "true" ]; then
            SVC_TOKEN_ID=$(echo "$st_resp" | json_get "result.client_id")
            SVC_TOKEN_SECRET=$(echo "$st_resp" | json_get "result.client_secret")
            ok "Service token created (client_id: ${SVC_TOKEN_ID:0:8}...)"
        else
            warn "Service token creation failed: $(echo "$st_resp" | json_get 'errors')"
            warn "edge-sync Worker will not have service token auth."
        fi
    fi

    # ── Generate and deploy Worker ────────────────────────────────────
    local js
    js=$(generate_edge_sync_worker_js "$APP_HOST" "$SSH_HOST" "$SVC_TOKEN_ID" "$SVC_TOKEN_SECRET")

    printf "  Deploying 'edge-sync' Worker ... "
    EDGE_SYNC_URL="https://edge-sync.${SUBDOMAIN}.workers.dev"
    if deploy_worker "$ACCT_ID" "edge-sync" "$js"; then
        printf "${G}OK${X}  ->  ${EDGE_SYNC_URL}\n"
        ok "Browser terminal proxied through workers.dev"
        save_config "{\"edge_sync_url\":\"${EDGE_SYNC_URL}\",\"service_token_id\":\"${SVC_TOKEN_ID}\",\"service_token_secret\":\"${SVC_TOKEN_SECRET}\"}"
    else
        printf "${R}FAILED${X}\n"
        warn "edge-sync deploy failed."
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 9 — Build tsnet binary
# ═══════════════════════════════════════════════════════════════════════════
get_latest_go_info() {
    # Prints: VERSION SHA256
    local releases
    releases=$(curl -sk "https://go.dev/dl/?mode=json" 2>/dev/null)
    if [ -n "$releases" ]; then
        local go_os="$OS"
        [ "$go_os" = "darwin" ] && go_os="darwin"
        python3 -c "
import json, sys
releases = json.loads(sys.argv[1])
for rel in releases:
    if rel.get('stable') and rel.get('version','').startswith('go'):
        ver = rel['version'][2:]
        for f in rel.get('files', []):
            if f.get('os') == '$go_os' and f.get('arch') == '$ARCH' and f.get('kind') == 'archive':
                print(ver, f.get('sha256', ''))
                sys.exit(0)
        print(ver, '')
        sys.exit(0)
print('1.22.3', '')" "$releases" 2>/dev/null || echo "1.22.3 "
    else
        warn "Could not fetch Go release info." >&2
        echo "1.22.3 "
    fi
}

download_go_toolchain() {
    # stdout is captured by caller — all user messages go to stderr
    # Returns path to go binary on stdout, or empty on failure
    local local_go="$BIN_DIR/go-toolchain/bin/go"
    if [ -x "$local_go" ]; then
        ok "Go toolchain already present." >&2
        echo "$local_go"
        return 0
    fi

    # System Go
    if command -v go &>/dev/null; then
        local go_ver
        go_ver=$(go version 2>/dev/null)
        ok "System Go: $go_ver" >&2
        echo "go"
        return 0
    fi

    # Download portable Go
    local info
    info=$(get_latest_go_info)
    local go_ver="${info%% *}"
    local go_sha="${info##* }"

    local go_url="https://go.dev/dl/go${go_ver}.${OS}-${ARCH}.tar.gz"
    local go_archive="$BIN_DIR/go${go_ver}.${OS}-${ARCH}.tar.gz"
    mkdir -p "$BIN_DIR"

    printf "  Downloading Go %s (~130 MB) ...\n" "$go_ver" >&2
    printf "  ${D}%s${X}\n" "$go_url" >&2
    if ! curl -sL -o "$go_archive" "$go_url" 2>/dev/null; then
        warn "Go download failed." >&2
        warn "Install Go manually from https://go.dev/dl/ and re-run: $0 --build-tsnet" >&2
        rm -f "$go_archive"
        return 1
    fi

    # Verify SHA256
    if [ -n "$go_sha" ]; then
        local actual
        if command -v shasum &>/dev/null; then
            actual=$(shasum -a 256 "$go_archive" | awk '{print $1}')
        else
            actual=$(sha256sum "$go_archive" | awk '{print $1}')
        fi
        if [ "$actual" != "$go_sha" ]; then
            err "Go archive SHA256 mismatch -- download may be corrupted." >&2
            err "  expected: $go_sha" >&2
            err "  got:      $actual" >&2
            rm -f "$go_archive"
            return 1
        fi
        ok "SHA256 verified." >&2
    fi

    printf "  Extracting ...\n" >&2
    if ! tar xzf "$go_archive" -C "$BIN_DIR" 2>/dev/null; then
        warn "Extraction failed." >&2
        rm -f "$go_archive"
        return 1
    fi
    mv "$BIN_DIR/go" "$BIN_DIR/go-toolchain" 2>/dev/null || true
    rm -f "$go_archive"

    local go_bin="$BIN_DIR/go-toolchain/bin/go"
    if [ ! -x "$go_bin" ]; then
        err "Go binary not found after extraction." >&2
        return 1
    fi
    local ver_check
    ver_check=$("$go_bin" version 2>/dev/null) || { err "Go binary failed self-test." >&2; return 1; }
    ok "Go toolchain: $ver_check" >&2
    echo "$go_bin"
}

build_tsnet() {
    local go_exe="$1"
    local tsnet_src="$REPO_ROOT/tsnet"
    local tsnet_bin="$BIN_DIR/tsnet"

    [ -f "$tsnet_src/main.go" ] || { warn "tsnet/main.go not found. Cannot build."; return 1; }

    export GONOSUMDB="*"
    export GOFLAGS="-mod=mod"

    printf "  Fetching latest tailscale.com (this may take a few minutes)...\n"
    "$go_exe" get tailscale.com@latest 2>/dev/null || warn "go get failed (building with pinned version)."

    printf "  Running go mod tidy ...\n"
    if ! "$go_exe" mod tidy 2>/dev/null; then
        warn "go mod tidy failed."
        return 1
    fi

    printf "  Building tsnet (first build ~2-3 min, subsequent builds faster)...\n"
    if ! "$go_exe" build -ldflags "-s -w" -o "$tsnet_bin" . 2>&1; then
        err "Build failed."
        return 1
    fi

    ok "tsnet built: $tsnet_bin"
    return 0
}

step_build_tsnet() {
    hdr "Step 8: Build tsnet binary (userspace Tailscale)"

    # Connectivity pre-check
    printf "  Checking Tailscale control plane connectivity...\n"
    if ! curl --connect-timeout 5 -sk "https://controlplane.tailscale.com/key?v=71" >/dev/null 2>&1; then
        warn "Tailscale control plane unreachable (likely corporate firewall)"
        warn "tsnet build will likely fail. CF Tunnel SSH is the recommended path."
        if [ -n "$ARG_CF_TOKEN" ]; then
            # Non-interactive: auto-skip
            ok "Skipping tsnet build (non-interactive, control plane unreachable)."
            return 1
        fi
        echo ""
        printf "  ${B}1${X}  Skip tsnet (recommended)\n"
        printf "  ${B}2${X}  Try anyway\n"
        printf "\n  [1/2]: "
        read -r choice
        [ "$choice" != "2" ] && { ok "Skipping tsnet build."; return 1; }
    fi

    local go_exe
    go_exe=$(download_go_toolchain)
    if [ -z "$go_exe" ]; then
        warn "Skipping tsnet build. Run later: $0 --build-tsnet"
        return 1
    fi

    local tsnet_dir="$REPO_ROOT/tsnet"
    (cd "$tsnet_dir" && build_tsnet "$go_exe")
}

# ═══════════════════════════════════════════════════════════════════════════
#  Save config + cf_config.txt
# ═══════════════════════════════════════════════════════════════════════════
step_save() {
    hdr "Saving configuration"

    local cfg_json
    cfg_json=$(python3 -c "
import json
cfg = {
    'account_id': '$ACCT_ID',
    'subdomain':  '$SUBDOMAIN',
    'tunnel_id':  '$TUNNEL_ID',
    'ssh_host':   '$SSH_HOST',
    'app_host':   '$APP_HOST',
    'domain':     '$DOMAIN',
    'zone_id':    '$ZONE_ID',
}
if '$TUNNEL_TOKEN':
    cfg['tunnel_token'] = '$TUNNEL_TOKEN'
if '$EDGE_SYNC_URL':
    cfg['edge_sync_url'] = '$EDGE_SYNC_URL'
if '$SVC_TOKEN_ID':
    cfg['service_token_id'] = '$SVC_TOKEN_ID'
if '$SVC_TOKEN_SECRET':
    cfg['service_token_secret'] = '$SVC_TOKEN_SECRET'
print(json.dumps(cfg))")

    save_config "$cfg_json"
    ok "Config saved to $CFG_FILE"

    # Write cf_config.txt
    mkdir -p "$TEMP_DIR"
    local cfg_lines=()
    if [ -f "$CF_CFG_TXT" ]; then
        while IFS= read -r line; do
            local key="${line%%=*}"
            [ "$key" != "CF_HOST" ] && cfg_lines+=("$line")
        done < "$CF_CFG_TXT"
    fi
    cfg_lines+=("CF_HOST=${SSH_HOST}")
    printf '%s\n' "${cfg_lines[@]}" > "$CF_CFG_TXT"
    ok "cf_config.txt updated: CF_HOST=${SSH_HOST}"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Summary
# ═══════════════════════════════════════════════════════════════════════════
print_summary() {
    local -a emails=("$@")

    # Reload config to get latest values
    local tunnel_tok ssh_ca_key team_name
    tunnel_tok=$(config_val "tunnel_token")
    ssh_ca_key=$(config_val "ssh_ca_public_key")
    team_name=$(config_val "team_name")
    [ -z "$team_name" ] && team_name="$TEAM_NAME"

    printf "\n%s\n" "$(printf '═%.0s' $(seq 1 58))"
    printf "  ${G}${B}Bootstrap complete!${X}\n"
    printf "%s\n" "$(printf '═%.0s' $(seq 1 58))"
    local edge_sync_url
    edge_sync_url=$(config_val "edge_sync_url")
    [ -z "$edge_sync_url" ] && [ -n "$EDGE_SYNC_URL" ] && edge_sync_url="$EDGE_SYNC_URL"

    printf "\n  Your endpoints:\n"
    printf "    Browser SSH : ${C}https://${SSH_HOST}${X}\n"
    if [ -n "$edge_sync_url" ]; then
        printf "    ${G}${B}Browser Terminal : ${C}${edge_sync_url}${X}\n"
        printf "    ${D}(open from your work machine -- no setup needed)${X}\n"
    fi
    if [ -n "$team_name" ]; then
        printf "    App Launcher: ${C}https://${team_name}.cloudflareaccess.com${X}\n"
    fi
    printf "    CLI SSH     : ${C}ssh YOUR_USER@${SSH_HOST}${X}\n"
    printf "    TS relay    : ${C}https://ts-relay.${SUBDOMAIN}.workers.dev${X}  (Tailscale bypass)\n\n"
    printf "    Domain      : ${DOMAIN}\n\n"

    if [ ${#emails[@]} -gt 0 ] && [ -n "${emails[0]}" ]; then
        printf "  CF Access (OTP email): %s\n" "$(IFS=', '; echo "${emails[*]}")"
    fi
    [ -n "$ssh_ca_key" ] && printf "  Short-lived SSH certs: ${G}ENABLED${X}\n"
    echo ""

    local tsnet_note
    if [ "$TSNET_OK" = "true" ]; then
        tsnet_note="  ${G}[ok]${X} tsnet built -- run:  ${BIN_DIR}/tsnet up"
    else
        tsnet_note="  ${Y}[!!]${X} tsnet not built. Run later:  $0 --build-tsnet"
    fi

    printf "  ${G}${B}What to do next:${X}\n\n"
    printf "  ${C}STEP 1 -- Set up your HOME machine${X} (the one you SSH into)\n\n"
    printf "    ${Y}If this IS your home machine:${X}\n"
    printf "      ./installers/home_linux_mac.sh\n\n"
    printf "    ${Y}If your home machine is a different box:${X}\n"
    printf "    Copy the repo (or just installers/ + ../erebus-temp/) there, then:\n\n"
    printf "    ${Y}Linux / Mac:${X}\n"
    printf "      ./installers/home_linux_mac.sh\n"
    printf "    ${Y}Windows:${X}\n"
    printf "      installers\\\\home_windows.bat\n\n"
    printf "    ${D}Auto-reads token, SSH CA key, and host from ../erebus-temp/.${X}\n"
    printf "    ${D}Asks: Quick start (no root) or Full system setup (sudo/admin).${X}\n"
    printf "    ${D}Or pass --sudo/--no-sudo (--admin/--no-admin on Windows).${X}\n\n"
    printf "  ${C}STEP 2 -- Set up your WORK machine${X} (the one you connect from)\n"
    printf "  Copy installers/ + ../erebus-temp/ to your work machine, then run:\n\n"
    printf "    ${Y}Linux / Mac:${X}\n"
    printf "      chmod +x work_linux_mac.sh && ./work_linux_mac.sh\n\n"
    printf "    ${Y}Windows (no admin needed):${X}\n"
    printf "      work_windows.bat\n\n"
    printf "    ${D}Auto-reads SSH host from config. Or pass: --ssh-host %s${X}\n" "$SSH_HOST"
    printf "    ${D}Windows .bat files work even when GPO blocks PowerShell.${X}\n\n"
    printf "  ${C}STEP 3 -- Connect${X}\n"
    printf "    Browser : https://%s  (email OTP -> browser SSH terminal)\n" "$SSH_HOST"
    if [ -n "$team_name" ]; then
        printf "    Launcher: https://%s.cloudflareaccess.com  (all your apps)\n" "$team_name"
    fi
    printf "    CLI     : ssh YOUR_USER@%s\n\n" "$SSH_HOST"
    printf "  Tailscale (optional, works independently):\n"
    printf "%b\n" "$tsnet_note"
    printf "     Peers:  %s/tsnet status\n" "$BIN_DIR"
    printf "     SSH:    ssh -o \"ProxyCommand=%s/tsnet proxy %%h %%p\" user@peer\n\n" "$BIN_DIR"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Argument parsing
# ═══════════════════════════════════════════════════════════════════════════
ARG_REDEPLOY=false
ARG_SKIP_ACCESS=false
ARG_SKIP_TSNET=false
ARG_BUILD_TSNET=false
ARG_CF_TOKEN=""
ARG_SAVE_TOKEN=false
ARG_DOMAIN=""
ARG_EMAILS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --redeploy)     ARG_REDEPLOY=true ;;
        --skip-access)  ARG_SKIP_ACCESS=true ;;
        --skip-tsnet)   ARG_SKIP_TSNET=true ;;
        --build-tsnet)  ARG_BUILD_TSNET=true ;;
        --cf-token)     shift; ARG_CF_TOKEN="$1" ;;
        --save-token)   ARG_SAVE_TOKEN=true ;;
        --domain)       shift; ARG_DOMAIN="$1" ;;
        --email)        shift; ARG_EMAILS+=("$1") ;;
        -h|--help)
            cat <<'HELPEOF'
Usage: bootstrap.sh [OPTIONS]

SSH Portal bootstrap wizard. Sets up CF Tunnel, DNS, Access, the
edge-sync Worker (browser terminal relay), and optionally tsnet
on your Cloudflare account.

PREREQUISITE: A domain on your Cloudflare account (even a $1/yr .xyz).
              The wizard guides you through this if you don't have one yet.

OUTPUT: After completion, your browser terminal URL is printed:
          https://edge-sync.YOUR_SUBDOMAIN.workers.dev
        Open it from any browser — no install needed on the work machine.
        Config is saved to ../erebus-temp/keys/portal_config.json.

Authentication (choose one, or interactive menu):
  (default)           Opens CF Dashboard with step-by-step instructions to
                      create a token with the required permissions.
                      RECOMMENDED — minimal permissions, most secure.
  --cf-token TOKEN    Pre-made CF API token (fully non-interactive, no browser).
                      Token needs: Cloudflare Tunnel Edit, Workers Scripts Edit,
                      Zero Trust Edit, Zone DNS Edit
  --save-token        Auto-save token to macOS Keychain or Linux file (no prompt)

  Interactive mode also offers:
    Option 2: Paste an existing token (no browser)
    Option 3: cloudflared tunnel login (power users, requires a domain on CF)

Access control:
  --email EMAIL       Email for CF Access OTP policy (repeatable)
                      If omitted and --skip-access is not set, prompts interactively
                      (skipped automatically when using --cf-token)

Domain:
  --domain DOMAIN     Domain to use for SSH hostname (e.g. yourdomain.com)
                      If omitted, auto-selects or prompts from your CF zones.

Modes:
  --redeploy          Re-run DNS + ingress + Access with existing config
  --build-tsnet       Only rebuild the tsnet binary (skip everything else)

Skip flags:
  --skip-access       Skip CF Zero Trust Access setup
  --skip-tsnet        Skip tsnet binary build

Other:
  -h, --help          Show this help

Examples:
  # Interactive (recommended for first run — opens browser for auth):
  ./bootstrap.sh --email user@example.com

  # With a specific domain:
  ./bootstrap.sh --email user@example.com --domain myname.xyz

  # Fully automated (requires pre-made token):
  ./bootstrap.sh --cf-token "YOUR_TOKEN" --save-token \
    --email user@example.com --domain myname.xyz --skip-tsnet

Artifacts are written to ../erebus-temp/ (repo stays clean).
HELPEOF
            exit 0
            ;;
        *)
            err "Unknown option: $1"
            exit 1
            ;;
    esac
    shift
done

# ═══════════════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════════════
main() {
    printf "\n${C}${B}  +==========================================+\n"
    printf "  |       SSH Portal -- Bootstrap Wizard     |\n"
    printf "  +==========================================+${X}\n\n"
    printf "  Each user deploys their OWN instance with their OWN CF account.\n"
    printf "  Share the repo/zip -- not the URL.\n\n"

    mkdir -p "$KEYS_DIR" "$BIN_DIR"

    # ── Build-tsnet-only mode ─────────────────────────────────────────
    if [ "$ARG_BUILD_TSNET" = "true" ]; then
        if step_build_tsnet; then
            ok "tsnet ready. Run:  ${BIN_DIR}/tsnet up"
        fi
        return
    fi

    # ── Redeploy mode ─────────────────────────────────────────────────
    if [ "$ARG_REDEPLOY" = "true" ]; then
        ACCT_ID=$(config_val "account_id")
        SUBDOMAIN=$(config_val "subdomain")
        TUNNEL_ID=$(config_val "tunnel_id")
        DOMAIN=$(config_val "domain")
        ZONE_ID=$(config_val "zone_id")
        SSH_HOST=$(config_val "ssh_host")

        local missing=()
        [ -z "$ACCT_ID" ]   && missing+=("account_id")
        [ -z "$SUBDOMAIN" ] && missing+=("subdomain")
        [ -z "$TUNNEL_ID" ] && missing+=("tunnel_id")
        if [ ${#missing[@]} -gt 0 ]; then
            err "Config incomplete -- missing: ${missing[*]}"
            err "Run full bootstrap first: $0"
            exit 1
        fi

        step_auth
        [ -n "$ARG_DOMAIN" ] && DOMAIN="$ARG_DOMAIN"
        APP_HOST=$(config_val "app_host")
        step_domain
        step_ingress
        step_ts_relay
        step_edge_sync
        if [ "$ARG_SKIP_TSNET" != "true" ]; then
            step_build_tsnet && TSNET_OK=true
        fi
        step_save
        print_summary
        return
    fi

    # ── Full wizard ───────────────────────────────────────────────────
    [ -n "$ARG_DOMAIN" ] && DOMAIN="$ARG_DOMAIN"

    step_auth
    step_discover
    step_tunnel
    step_domain

    # Save config early so --redeploy works even if later steps fail
    step_save

    step_ingress

    # ts-relay Worker (still on workers.dev -- works fine for Tailscale)
    step_ts_relay

    # edge-sync Worker (browser terminal proxy through workers.dev)
    step_edge_sync

    # CF Access: collect emails
    local -a emails=("${ARG_EMAILS[@]}")
    if [ "$ARG_SKIP_ACCESS" != "true" ] && [ ${#emails[@]} -eq 0 ] && [ -z "$ARG_CF_TOKEN" ]; then
        # Only prompt interactively if not using --cf-token (non-interactive mode)
        printf "\n  ${B}CF Zero Trust Access${X} protects the terminal (shell on home machine).\n"
        printf "  Enter email addresses to allow. Press Enter with no input to skip.\n"
        while true; do
            printf "  Email (or Enter to skip): "
            read -r e
            e=$(echo "$e" | tr '[:upper:]' '[:lower:]' | xargs)
            [ -z "$e" ] && break
            emails+=("$e")
        done
    fi

    if [ ${#emails[@]} -gt 0 ] && [ "$ARG_SKIP_ACCESS" != "true" ]; then
        step_access "${emails[@]}"
    fi

    # Build tsnet
    if [ "$ARG_SKIP_TSNET" != "true" ]; then
        step_build_tsnet && TSNET_OK=true
    fi

    print_summary "${emails[@]}"
}

main
