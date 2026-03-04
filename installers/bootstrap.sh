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
#   ./bootstrap.sh --workers-only

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
COMPAT_DATE="2024-09-23"

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
KV_NS_ID=""
SSH_HOST=""
SSH_APP_AUD=""
SSH_CA_KEY=""
TEAM_NAME=""
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
d = json.load(sys.stdin)
$1"
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
        security add-generic-password -a "$USER" -s "$_KC_SERVICE" -w "$tok"
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
        ok "cloudflared in PATH: $CLOUDFLARED"
        return 0
    fi
    # 3. Our bin dir
    if [ -x "$BIN_DIR/cloudflared" ]; then
        CLOUDFLARED="$BIN_DIR/cloudflared"
        ok "cloudflared: $CLOUDFLARED"
        return 0
    fi
    return 1
}

download_cloudflared() {
    mkdir -p "$BIN_DIR"
    local url
    if [ "$OS" = "darwin" ]; then
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${ARCH}.tgz"
        printf "  Downloading cloudflared (macOS %s) ..." "$ARCH"
        if curl -sL "$url" | tar xz -C "$BIN_DIR" 2>/dev/null; then
            chmod +x "$BIN_DIR/cloudflared"
            CLOUDFLARED="$BIN_DIR/cloudflared"
            printf " ${G}OK${X}\n"
            return 0
        fi
    else
        url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}"
        printf "  Downloading cloudflared (Linux %s) ..." "$ARCH"
        if curl -sL -o "$BIN_DIR/cloudflared" "$url" 2>/dev/null; then
            chmod +x "$BIN_DIR/cloudflared"
            CLOUDFLARED="$BIN_DIR/cloudflared"
            printf " ${G}OK${X}\n"
            return 0
        fi
    fi
    printf " ${R}FAILED${X}\n"
    return 1
}

ensure_cloudflared() {
    find_cloudflared && return 0
    warn "cloudflared not found. Downloading..."
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
    if [ "$method" = "GET" ]; then
        result=$(curl -sk \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            "$url" 2>/dev/null) || result='{"success":false,"errors":["curl failed"]}'
    elif [ -n "$data" ]; then
        result=$(curl -sk -X "$method" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            -d "$data" "$url" 2>/dev/null) || result='{"success":false,"errors":["curl failed"]}'
    else
        result=$(curl -sk -X "$method" \
            -H "Authorization: Bearer $TOKEN" \
            -H "Content-Type: application/json" \
            "$url" 2>/dev/null) || result='{"success":false,"errors":["curl failed"]}'
    fi
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
generate_ssh_worker_js() {
    local tunnel_id="$1" ssh_host="$2"
    cat << 'WORKEREOF' | sed "s|__TUNNEL_ID__|${tunnel_id}|g; s|__SSH_HOST__|${ssh_host}|g"
// SSH proxy Worker: forwards cloudflared SSH traffic to the CF Tunnel.
const TUNNEL   = '__TUNNEL_ID__.cfargotunnel.com';
const SSH_HOST = '__SSH_HOST__';
export default {
  async fetch(request) {
    const url  = new URL(request.url);
    const dest = new URL(url.pathname + url.search, `https://${TUNNEL}`);
    const headers = new Headers();
    for (const [k, v] of request.headers) {
      if (/^(cf-|x-forwarded-|x-real-ip)/i.test(k)) continue;
      headers.set(k, v);
    }
    headers.set('Host', SSH_HOST);
    return fetch(dest.toString(), {
      method: request.method, headers,
      body: ['GET','HEAD'].includes(request.method) ? undefined : request.body,
    });
  }
};
WORKEREOF
}

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

    if [ "$count" = "0" ] || [ -z "$count" ]; then
        err "No CF accounts found. Check token permissions."
        exit 1
    fi

    if [ "$count" = "1" ]; then
        ACCT_ID=$(echo "$accounts_json" | json_get "result[0].id")
        ACCT_NAME=$(echo "$accounts_json" | json_get "result[0].name")
        ok "Account: $ACCT_NAME"
        return
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
    ensure_cloudflared || { warn "Cannot open browser login without cloudflared."; return 1; }
    mkdir -p "$KEYS_DIR"
    local cert_path="$KEYS_DIR/cf_login.pem"
    rm -f "$cert_path"
    echo ""
    echo "  Opening Cloudflare in your browser..."
    printf "  ${D}Log in, select your account, and click Authorize.${X}\n\n"
    "$CLOUDFLARED" tunnel login --origincert="$cert_path" 2>/dev/null || true
    [ -f "$cert_path" ] || { warn "Login did not complete (cert not written)."; return 1; }
    local tok
    tok=$(parse_cert_token "$cert_path")
    rm -f "$cert_path"
    [ -n "$tok" ] && { echo "$tok"; return 0; }
    warn "Could not extract token from cert."
    return 1
}

create_scoped_token() {
    local broad_token="$1" acct_id="$2"
    # Get permission groups
    local groups_resp
    groups_resp=$(curl -sk \
        -H "Authorization: Bearer $broad_token" \
        -H "Content-Type: application/json" \
        "${CF_API}/user/tokens/permission_groups" 2>/dev/null)
    local pg_json
    pg_json=$(echo "$groups_resp" | json_py "
needed = ['Cloudflare Tunnel Edit','Workers Script Edit','Workers KV Storage Edit','Zero Trust Edit']
groups = [g for g in d.get('result',[]) if g.get('name') in needed]
import json; print(json.dumps([{'id':g['id']} for g in groups]))")

    if [ -z "$pg_json" ] || [ "$pg_json" = "[]" ]; then
        warn "Could not resolve CF permission groups."
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

    if [ "${existing_count:-0}" -gt 0 ]; then
        printf "\n  ${B}Found existing '${PORTAL_TOKEN_NAME}' token(s).${X}\n"
        echo "$tokens_resp" | json_py "
ts = [t for t in d.get('result',[]) if t.get('name','').startswith('$PORTAL_TOKEN_NAME')]
for t in ts:
    exp = (t.get('expiration_date','') or 'no expiry')[:10]
    print(f'    . {t[\"name\"]:<30} {t.get(\"status\",\"\")}  exp: {exp}')"
        printf "\n  ${D}CF never re-exposes token values after creation.${X}\n"
        printf "\n  ${B}1${X}  Paste the existing token value  ${D}(if you still have it)${X}\n"
        printf "  ${B}2${X}  Replace -- delete old token(s) and create a fresh one\n"
        printf "  ${B}3${X}  Create additional token\n"
        printf "\n  [1/2/3]: "
        read -r ch
        case "$ch" in
            1)
                printf "  Paste token value: "
                read -rs tok_val; echo ""
                [ -n "$tok_val" ] && { echo "$tok_val"; return 0; }
                ;;
            2)
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
                ok "Deleted old portal token(s)."
                ;;
        esac
    fi

    # Create scoped token
    printf "\n  Creating '${PORTAL_TOKEN_NAME}' token with permissions:\n"
    printf "  ${D}. Cloudflare Tunnel Edit${X}\n"
    printf "  ${D}. Workers Script Edit${X}\n"
    printf "  ${D}. Workers KV Storage Edit${X}\n"
    printf "  ${D}. Zero Trust Edit${X}\n"

    local payload
    payload=$(python3 -c "
import json, sys
pg = json.loads(sys.argv[1])
print(json.dumps({
    'name': '$PORTAL_TOKEN_NAME',
    'policies': [{
        'effect': 'allow',
        'resources': {'com.cloudflare.api.account.$acct_id': '*'},
        'permission_groups': pg,
    }],
}))" "$pg_json")

    local result
    result=$(curl -sk -X POST \
        -H "Authorization: Bearer $broad_token" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${CF_API}/user/tokens" 2>/dev/null)

    local new_tok
    new_tok=$(echo "$result" | json_get "result.value")
    if [ -n "$new_tok" ]; then
        ok "'${PORTAL_TOKEN_NAME}' token created -- value captured automatically."
        echo "$new_tok"
        return 0
    fi
    warn "Token creation failed."
    return 1
}

step_auth() {
    hdr "Step 1: Authenticate with Cloudflare"

    # Try stored credential
    local stored
    stored=$(load_credential)
    if [ -n "$stored" ]; then
        local verify
        verify=$(curl -sk \
            -H "Authorization: Bearer $stored" \
            -H "Content-Type: application/json" \
            "${CF_API}/accounts" 2>/dev/null)
        local has_accts
        has_accts=$(echo "$verify" | json_py "print(len(d.get('result',[])) > 0)")
        if [ "$has_accts" = "True" ]; then
            ok "Using stored Cloudflare credentials."
            TOKEN="$stored"
            return
        fi
        warn "Stored token could not be verified -- re-authenticating."
    fi

    printf "\n  ${B}Authentication method:${X}\n"
    printf "  ${B}1${X}  Browser OAuth  ${D}(recommended -- opens Cloudflare in browser)${X}\n"
    printf "  ${B}2${X}  Paste API token  ${D}(from CF Dashboard -> My Profile -> API Tokens)${X}\n"
    printf "\n  [1/2]: "
    read -r method

    if [ "$method" != "2" ]; then
        local broad
        broad=$(browser_login)
        if [ -n "$broad" ]; then
            # Get account so we can create scoped token
            local accts_resp
            accts_resp=$(curl -sk \
                -H "Authorization: Bearer $broad" \
                -H "Content-Type: application/json" \
                "${CF_API}/accounts" 2>/dev/null)
            pick_account "$accts_resp"
            local scoped
            scoped=$(create_scoped_token "$broad" "$ACCT_ID")
            if [ -n "$scoped" ]; then
                TOKEN="$scoped"
            else
                warn "Could not create scoped token. Using broad login token."
                TOKEN="$broad"
            fi
            # Offer to save
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
            return
        fi
        warn "Browser login failed. Falling back to manual token."
    fi

    # Manual paste
    printf "\n  Dashboard -> My Profile -> API Tokens -> Create Token\n"
    printf "  Permissions: Cloudflare Tunnel Edit, Workers Script Edit,\n"
    printf "               Workers KV Storage Edit, Zero Trust Edit\n"
    printf "\n  Paste token: "
    read -rs tok; echo ""
    [ -z "$tok" ] && { err "No token provided."; exit 1; }
    TOKEN="$tok"
    printf "\n  ${B}Save credentials?${X}\n"
    if [ "$OS" = "darwin" ]; then
        printf "  ${B}1${X}  Yes -- macOS Keychain\n"
    else
        printf "  ${B}1${X}  Yes -- encrypted file\n"
    fi
    printf "  ${B}2${X}  No  -- session only\n"
    printf "\n  [1/2]: "
    read -r save_choice
    [ "$save_choice" != "2" ] && store_credential "$TOKEN"
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 2 — Discover account + workers.dev subdomain
# ═══════════════════════════════════════════════════════════════════════════
step_discover() {
    hdr "Step 2: Discover account & workers.dev subdomain"
    local accts_resp
    accts_resp=$(cf_api GET "/accounts")
    pick_account "$accts_resp"

    # Get workers.dev subdomain
    local sub_resp
    sub_resp=$(cf_api GET "/accounts/${ACCT_ID}/workers/subdomain")
    SUBDOMAIN=$(echo "$sub_resp" | json_get "result.subdomain")
    if [ -z "$SUBDOMAIN" ]; then
        warn "Could not fetch workers.dev subdomain automatically."
        printf "  Enter your workers.dev subdomain (e.g. 'alice'): "
        read -r SUBDOMAIN
    fi
    SSH_HOST="ssh.${SUBDOMAIN}.workers.dev"
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
#  Step 4 — KV namespace
# ═══════════════════════════════════════════════════════════════════════════
step_kv() {
    hdr "Step 4: KV Namespace (ssh-portal)"
    local r
    r=$(cf_api GET "/accounts/${ACCT_ID}/storage/kv/namespaces")
    local existing_id
    existing_id=$(echo "$r" | json_py "
ns = next((n for n in d.get('result',[]) if n.get('title')=='ssh-portal'), None)
print(ns['id'] if ns else '')")

    if [ -n "$existing_id" ]; then
        KV_NS_ID="$existing_id"
        ok "Found existing KV namespace: ${KV_NS_ID:0:8}..."
        return
    fi

    r=$(cf_api POST "/accounts/${ACCT_ID}/storage/kv/namespaces" '{"title":"ssh-portal"}')
    local success
    success=$(echo "$r" | json_get "success")
    if [ "$success" != "true" ]; then
        err "Failed to create KV namespace: $(echo "$r" | json_get 'errors')"
        exit 1
    fi
    KV_NS_ID=$(echo "$r" | json_get "result.id")
    ok "Created KV namespace: ${KV_NS_ID:0:8}..."
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 5 — Deploy SSH Worker
# ═══════════════════════════════════════════════════════════════════════════
step_workers() {
    hdr "Step 5: Deploy SSH Worker"
    SSH_HOST="ssh.${SUBDOMAIN}.workers.dev"

    local js
    js=$(generate_ssh_worker_js "$TUNNEL_ID" "$SSH_HOST")

    printf "  Deploying 'ssh' Worker ... "
    if deploy_worker "$ACCT_ID" "ssh" "$js"; then
        printf "${G}OK${X}  ->  https://${SSH_HOST}\n"
    else
        printf "${R}FAILED${X}\n"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 6 — Tunnel ingress
# ═══════════════════════════════════════════════════════════════════════════
step_ingress() {
    hdr "Step 6: Tunnel ingress rules"
    SSH_HOST="ssh.${SUBDOMAIN}.workers.dev"
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
    {'hostname': '$SSH_HOST', 'service': 'ssh://localhost:22',
     'originRequest': {'access': {'required': True, 'teamName': '$cfg_team', 'audTag': ['$cfg_ssh_aud']}}},
    {'service': 'http_status:404'}
]
print(json.dumps({'config': {'ingress': rules}}))")
    else
        ingress_json='{"config":{"ingress":[{"hostname":"'"$SSH_HOST"'","service":"ssh://localhost:22"},{"service":"http_status:404"}]}}'
    fi

    local r2
    r2=$(cf_api PUT "$cfg_url" "$ingress_json")
    local success
    success=$(echo "$r2" | json_get "success")
    if [ "$success" = "true" ]; then
        ok "Ingress set: $SSH_HOST -> ssh://localhost:22"
        [ -n "$cfg_ssh_aud" ] && ok "Access JWT validation enabled (team: $cfg_team)"
        ok "cloudflared on the home machine will pick this up automatically."
    else
        warn "Ingress update failed: $(echo "$r2" | json_get 'errors')"
        warn "You may need to update your cloudflared config manually."
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 7 — CF Access (Zero Trust)
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
    warn "Zero Trust org setup failed: $(echo "$r" | json_get 'errors')"
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
        ok "Access app '$name' already exists: $app_id"
        echo "$app_id"
        return 0
    fi

    printf "  Creating Access app for $hostname (type: $app_type) ...\n"
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
        ok "Created Access app: $app_id"
        echo "$app_id"
        return 0
    fi
    warn "Could not create Access app: $(echo "$r" | json_get 'errors')"
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
    hdr "Step 7: CF Zero Trust Access (OTP email + browser SSH + short-lived certs)"

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
    SSH_HOST="ssh.${SUBDOMAIN}.workers.dev"
    local ssh_app_id
    ssh_app_id=$(ensure_app "$SSH_HOST" "SSH Browser Terminal" "ssh" "24h")
    if [ -n "$ssh_app_id" ]; then
        ensure_policy "$ssh_app_id" "${emails[@]}"
        if ensure_ssh_ca "$ssh_app_id"; then
            save_config "{\"ssh_ca_public_key\":\"${SSH_CA_KEY}\",\"ssh_app_aud\":\"${SSH_APP_AUD}\",\"team_name\":\"${TEAM_NAME}\"}"
            ok "SSH short-lived certificate CA generated and saved"
        fi
    fi

    ok "CF Access configured."
}

# ═══════════════════════════════════════════════════════════════════════════
#  Step 8 — Deploy ts-relay Worker
# ═══════════════════════════════════════════════════════════════════════════
step_ts_relay() {
    hdr "Step 8: Deploy ts-relay Worker (Tailscale bypass)"
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
        warn "Could not fetch Go release info."
        echo "1.22.3 "
    fi
}

download_go_toolchain() {
    # Returns path to go binary, or empty on failure
    local local_go="$BIN_DIR/go-toolchain/bin/go"
    if [ -x "$local_go" ]; then
        ok "Go toolchain already present."
        echo "$local_go"
        return 0
    fi

    # System Go
    if command -v go &>/dev/null; then
        local go_ver
        go_ver=$(go version 2>/dev/null)
        ok "System Go: $go_ver"
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

    printf "  Downloading Go %s (~130 MB) ...\n" "$go_ver"
    printf "  ${D}%s${X}\n" "$go_url"
    if ! curl -sL -o "$go_archive" "$go_url" 2>/dev/null; then
        warn "Go download failed."
        warn "Install Go manually from https://go.dev/dl/ and re-run: $0 --build-tsnet"
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
            err "Go archive SHA256 mismatch -- download may be corrupted."
            err "  expected: $go_sha"
            err "  got:      $actual"
            rm -f "$go_archive"
            return 1
        fi
        ok "SHA256 verified."
    fi

    printf "  Extracting ...\n"
    if ! tar xzf "$go_archive" -C "$BIN_DIR" 2>/dev/null; then
        warn "Extraction failed."
        rm -f "$go_archive"
        return 1
    fi
    mv "$BIN_DIR/go" "$BIN_DIR/go-toolchain" 2>/dev/null || true
    rm -f "$go_archive"

    local go_bin="$BIN_DIR/go-toolchain/bin/go"
    if [ ! -x "$go_bin" ]; then
        err "Go binary not found after extraction."
        return 1
    fi
    local ver_check
    ver_check=$("$go_bin" version 2>/dev/null) || { err "Go binary failed self-test."; return 1; }
    ok "Go toolchain: $ver_check"
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
    hdr "Step 9: Build tsnet binary (userspace Tailscale)"

    # Connectivity pre-check
    printf "  Checking Tailscale control plane connectivity...\n"
    if ! curl --connect-timeout 5 -sk "https://controlplane.tailscale.com/key?v=71" >/dev/null 2>&1; then
        warn "Tailscale control plane unreachable (likely corporate firewall)"
        warn "tsnet build will likely fail. CF Tunnel SSH is the recommended path."
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
    SSH_HOST="ssh.${SUBDOMAIN}.workers.dev"

    local cfg_json
    cfg_json=$(python3 -c "
import json
cfg = {
    'account_id': '$ACCT_ID',
    'subdomain':  '$SUBDOMAIN',
    'tunnel_id':  '$TUNNEL_ID',
    'kv_ns_id':   '$KV_NS_ID',
    'ssh_host':   '$SSH_HOST',
}
if '$TUNNEL_TOKEN':
    cfg['tunnel_token'] = '$TUNNEL_TOKEN'
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
    SSH_HOST="ssh.${SUBDOMAIN}.workers.dev"

    # Reload config to get latest values
    local tunnel_tok ssh_ca_key
    tunnel_tok=$(config_val "tunnel_token")
    ssh_ca_key=$(config_val "ssh_ca_public_key")

    printf "\n%s\n" "$(printf '═%.0s' $(seq 1 58))"
    printf "  ${G}${B}Bootstrap complete!${X}\n"
    printf "%s\n" "$(printf '═%.0s' $(seq 1 58))"
    printf "\n  Your endpoints:\n"
    printf "    Browser SSH : ${C}https://${SSH_HOST}${X}  (CF Access login)\n"
    printf "    TS relay    : ${C}https://ts-relay.${SUBDOMAIN}.workers.dev${X}  (Tailscale bypass)\n\n"

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

    # Build home installer args
    local home_args="--token ${tunnel_tok}"
    [ -n "$ssh_ca_key" ] && home_args="${home_args} --ca-key \"${ssh_ca_key}\""
    home_args="${home_args} --ssh-host ${SSH_HOST}"

    printf "  ${G}${B}What to do next:${X}\n\n"
    printf "  ${C}STEP 1 -- Set up your HOME machine${X} (the one you SSH into)\n"
    printf "  Copy installers/ to your home machine, then run:\n\n"
    printf "    ${Y}Linux / Mac:${X}\n"
    printf "      chmod +x home_linux_mac.sh\n"
    printf "      sudo ./home_linux_mac.sh %s\n\n" "$home_args"
    printf "    ${Y}Windows (as Administrator):${X}\n"
    printf "      home_windows.bat %s \"%s\" %s\n\n" "$tunnel_tok" "$ssh_ca_key" "$SSH_HOST"
    printf "  ${C}STEP 2 -- Set up your WORK machine${X} (the one you connect from)\n"
    printf "  Copy installers/ to your work machine, then run:\n\n"
    printf "    ${Y}Linux / Mac:${X}\n"
    printf "      chmod +x work_linux_mac.sh && ./work_linux_mac.sh --ssh-host %s\n\n" "$SSH_HOST"
    printf "    ${Y}Windows (no admin needed):${X}\n"
    printf "      work_windows.bat %s\n\n" "$SSH_HOST"
    printf "  Windows .bat files work even when GPO blocks PowerShell.\n\n"
    printf "  ${C}STEP 3 -- Connect${X}\n"
    printf "    Browser : https://%s  (email OTP login)\n" "$SSH_HOST"
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
ARG_WORKERS_ONLY=false
ARG_EMAILS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --redeploy)     ARG_REDEPLOY=true ;;
        --skip-access)  ARG_SKIP_ACCESS=true ;;
        --skip-tsnet)   ARG_SKIP_TSNET=true ;;
        --build-tsnet)  ARG_BUILD_TSNET=true ;;
        --workers-only) ARG_WORKERS_ONLY=true ;;
        --email)        shift; ARG_EMAILS+=("$1") ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --email EMAIL     Email for CF Access policy (repeatable)"
            echo "  --redeploy        Re-deploy Workers with existing config"
            echo "  --skip-access     Skip CF Access setup"
            echo "  --skip-tsnet      Skip tsnet build step"
            echo "  --build-tsnet     Only rebuild tsnet binary"
            echo "  --workers-only    Skip tunnel/Access, just deploy Workers"
            echo "  -h, --help        Show this help"
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
        KV_NS_ID=$(config_val "kv_ns_id")

        local missing=()
        [ -z "$ACCT_ID" ]   && missing+=("account_id")
        [ -z "$SUBDOMAIN" ] && missing+=("subdomain")
        [ -z "$TUNNEL_ID" ] && missing+=("tunnel_id")
        [ -z "$KV_NS_ID" ]  && missing+=("kv_ns_id")
        if [ ${#missing[@]} -gt 0 ]; then
            err "Config incomplete -- missing: ${missing[*]}"
            err "Run full bootstrap first: $0"
            exit 1
        fi

        step_auth
        step_workers
        step_ts_relay
        if [ "$ARG_SKIP_TSNET" != "true" ]; then
            step_build_tsnet && TSNET_OK=true
        fi
        print_summary
        return
    fi

    # ── Full wizard ───────────────────────────────────────────────────
    step_auth
    step_discover

    if [ "$ARG_WORKERS_ONLY" != "true" ]; then
        step_tunnel
        step_kv
    else
        TUNNEL_ID=$(config_val "tunnel_id")
        KV_NS_ID=$(config_val "kv_ns_id")
    fi

    # Save config early so --redeploy works even if later steps fail
    step_save

    step_workers

    if [ "$ARG_WORKERS_ONLY" != "true" ]; then
        step_ingress
    fi

    # ts-relay Worker
    if [ "$ARG_WORKERS_ONLY" != "true" ]; then
        step_ts_relay
    fi

    # CF Access: collect emails
    local -a emails=("${ARG_EMAILS[@]}")
    if [ "$ARG_SKIP_ACCESS" != "true" ] && [ "$ARG_WORKERS_ONLY" != "true" ] && [ ${#emails[@]} -eq 0 ]; then
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
