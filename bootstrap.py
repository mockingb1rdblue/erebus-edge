#!/usr/bin/env python3
"""
bootstrap.py -- First-run setup wizard for erebus-edge.

Works for ANY Cloudflare account. Share the repo, not the URL.
Each user runs this once to get their own deployment.

What it does:
  1. Authenticate via CF browser OAuth
  2. Create a CF Tunnel + SSH Worker
  3. Set up CF Zero Trust Access (email OTP + browser SSH + short-lived certs)
  4. Deploy ts-relay Worker (Tailscale bypass, optional)
  5. Build tsnet.exe (userspace Tailscale, optional)
  6. Generate standalone installer scripts in keys/

Usage:
  python bootstrap.py                  # full wizard
  python bootstrap.py --redeploy       # re-deploy Workers with existing config
  python bootstrap.py --skip-access    # skip CF Access setup
  python bootstrap.py --skip-tsnet     # skip Tailscale build
  python bootstrap.py --build-tsnet    # only rebuild tsnet binary
"""

import argparse, base64, getpass, hashlib, json, os, re, shutil, ssl, subprocess, sys, zipfile
import urllib.request, urllib.error, urllib.parse
from pathlib import Path

from lib.config import get_config, save_config, CFG_FILE
import lib.cf_creds as _creds_mod

SCRIPT_DIR   = Path(__file__).parent
BIN_DIR      = SCRIPT_DIR / "bin"
KEYS_DIR     = SCRIPT_DIR / "keys"
CF_CERT_PATH = KEYS_DIR / "cf_login.pem"
CLOUDFLARED  = str(BIN_DIR / "cloudflared.exe")
CF_CFG_TXT   = SCRIPT_DIR / "cf_config.txt"

PORTAL_TOKEN_NAME = "ssh-portal"
REQUIRED_PERMS = [
    "Cloudflare Tunnel Edit",
    "Workers Script Edit",
    "Workers KV Storage Edit",
    "Zero Trust Edit",
]

# ── SSL (bypass corporate revocation check) ───────────────────────────────────
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode    = ssl.CERT_NONE

os.system("")  # enable VT100 on Windows
G="\033[32m"; Y="\033[33m"; C="\033[36m"; R="\033[31m"; B="\033[1m"; D="\033[2m"; X="\033[0m"
def ok(s):   print(f"  {G}✓{X} {s}")
def warn(s): print(f"  {Y}!{X} {s}")
def err(s):  print(f"  {R}✗{X} {s}")
def hdr(s):  print(f"\n{C}{B}── {s} {'─'*(52-len(s))}{X}")

# ═════════════════════════════════════════════════════════════════════════════
#  CF API helper
# ═════════════════════════════════════════════════════════════════════════════
def api(method, path, data=None, token=None, raw=False):
    t   = token or _TOKEN
    url = f"https://api.cloudflare.com/client/v4{path}"
    body = json.dumps(data).encode() if data is not None else None
    req  = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Bearer {t}")
    req.add_header("Content-Type",  "application/json")
    try:
        with urllib.request.urlopen(req, context=_SSL) as r:
            return r.read() if raw else json.loads(r.read())
    except urllib.error.HTTPError as e:
        if raw: return None
        try:    return json.loads(e.read())
        except: return {"success": False, "errors": [str(e)]}
    except Exception as e:
        if raw: return None
        return {"success": False, "errors": [str(e)]}

_TOKEN = None   # set during auth step

# ═════════════════════════════════════════════════════════════════════════════
#  Step 1 – Authentication (browser OAuth → scoped token)
# ═════════════════════════════════════════════════════════════════════════════
def _parse_cert_token(cert_path: Path) -> str | None:
    try:
        content = cert_path.read_text(errors="replace")
        m = re.search(
            r"-----BEGIN SERVICE KEY-----\r?\n(.*?)\r?\n-----END SERVICE KEY-----",
            content, re.DOTALL)
        if m:
            raw = m.group(1).replace("\n","").replace("\r","")
            tok = base64.b64decode(raw).decode().strip()
            if tok: return tok
        sidecar = cert_path.with_suffix(".json")
        if sidecar.exists():
            data = json.loads(sidecar.read_text())
            for k in ("APIToken","api_token","token"):
                if k in data: return data[k]
    except Exception:
        pass
    return None

def _browser_login() -> str | None:
    KEYS_DIR.mkdir(parents=True, exist_ok=True)
    CF_CERT_PATH.unlink(missing_ok=True)
    print(f"\n  {ok.__doc__ or ''}Opening Cloudflare in your browser...")
    print(f"  {D}Log in, select your account, and click Authorize.{X}\n")
    try:
        subprocess.run(
            [CLOUDFLARED, "tunnel", "login", f"--origincert={CF_CERT_PATH}"],
            timeout=300, check=False)
    except FileNotFoundError:
        warn(f"cloudflared not found at {CLOUDFLARED}")
        return None
    except subprocess.TimeoutExpired:
        warn("Browser login timed out.")
        return None
    if not CF_CERT_PATH.exists():
        warn("Login did not complete (cert not written).")
        return None
    tok = _parse_cert_token(CF_CERT_PATH)
    CF_CERT_PATH.unlink(missing_ok=True)
    return tok

def _get_permission_groups(token):
    r = api("GET", "/user/tokens/permission_groups", token=token)
    return r.get("result", []) if r.get("success") else []

def _list_portal_tokens(token):
    r = api("GET", "/user/tokens", token=token)
    return [t for t in r.get("result",[]) if t.get("name","").startswith(PORTAL_TOKEN_NAME)] \
           if r.get("success") else []

def _delete_token(token, tid):
    api("DELETE", f"/user/tokens/{tid}", token=token)

def _create_scoped_token(broad_token, acct_id) -> str | None:
    groups = _get_permission_groups(broad_token)
    chosen = [g for g in groups if g.get("name") in REQUIRED_PERMS]
    if not chosen:
        warn("Could not resolve CF permission groups.")
        return None
    r = api("POST", "/user/tokens", token=broad_token, data={
        "name": PORTAL_TOKEN_NAME,
        "policies": [{
            "effect": "allow",
            "resources": {f"com.cloudflare.api.account.{acct_id}": "*"},
            "permission_groups": [{"id": g["id"]} for g in chosen],
        }],
    })
    return r["result"].get("value") if r.get("success") else None

def _manage_scoped_token(broad_token, acct_id) -> str:
    existing = _list_portal_tokens(broad_token)
    if existing:
        print(f"\n  {B}Found existing '{PORTAL_TOKEN_NAME}' token(s):{X}")
        for t in existing:
            exp    = t.get("expiration_date","")[:10] or "no expiry"
            status = f"{G}active{X}" if t.get("status")=="active" else f"{Y}{t.get('status','')}{X}"
            print(f"    · {t['name']:<30} {status}  exp: {exp}")
        print(f"\n  {D}CF never re-exposes token values after creation.{X}")
        print(f"\n  {B}1{X}  Paste the existing token value  {D}(if you still have it){X}")
        print(f"  {B}2{X}  Replace — delete old token(s) and create a fresh one")
        print(f"  {B}3{X}  Create additional token")
        ch = input("\n  [1/2/3]: ").strip()
        if ch == "1":
            return getpass.getpass("  Paste token value: ").strip()
        if ch == "2":
            for t in existing:
                _delete_token(broad_token, t["id"])
            ok(f"Deleted {len(existing)} old portal token(s).")
        # fall through to create

    print(f"\n  Creating '{PORTAL_TOKEN_NAME}' token with permissions:")
    for p in REQUIRED_PERMS:
        print(f"  {D}· {p}{X}")
    tok = _create_scoped_token(broad_token, acct_id)
    if tok:
        ok(f"'{PORTAL_TOKEN_NAME}' token created — value captured automatically.")
    else:
        warn("Token creation failed.")
    return tok

def step_auth() -> str:
    global _TOKEN
    hdr("Step 1: Authenticate with Cloudflare")

    # Try stored token first
    try:
        stored = _creds_mod.get_token.__wrapped__() if hasattr(_creds_mod.get_token,"__wrapped__") else None
    except Exception:
        stored = None

    # cf_creds.get_token() prompts if not stored — call directly
    # We don't want interactive prompt here; check if file exists
    creds_file = KEYS_DIR / "cf_creds.dpapi"
    if creds_file.exists():
        try:
            stored_tok = _creds_mod.get_token()
            # Quick verify
            accts = api("GET", "/accounts", token=stored_tok).get("result", [])
            if accts:
                ok("Using stored Cloudflare credentials.")
                _TOKEN = stored_tok
                return stored_tok
        except Exception:
            pass
        warn("Stored token could not be verified — re-authenticating.")
        creds_file.unlink(missing_ok=True)

    print(f"\n  {B}Authentication method:{X}")
    print(f"  {B}1{X}  Browser OAuth  {D}(recommended — opens Cloudflare in browser){X}")
    print(f"  {B}2{X}  Paste API token  {D}(from CF Dashboard → My Profile → API Tokens){X}")
    method = input("\n  [1/2]: ").strip()

    if method != "2":
        broad = _browser_login()
        if not broad:
            warn("Browser login failed. Falling back to manual token.")
            method = "2"
        else:
            # Get account first so we can create scoped token
            accts = api("GET", "/accounts", token=broad).get("result", [])
            if not accts:
                err("No CF accounts found with this login.")
                sys.exit(1)
            acct = _pick_account(accts)
            tok = _manage_scoped_token(broad, acct["id"])
            if not tok:
                warn("Could not create scoped token. Using broad login token.")
                tok = broad
            _TOKEN = tok
            _save_token(tok)
            return tok

    # Manual paste fallback
    print(f"\n  Dashboard → My Profile → API Tokens → Create Token")
    print(f"  Permissions: {', '.join(REQUIRED_PERMS)}")
    tok = getpass.getpass("\n  Paste token: ").strip()
    if not tok:
        err("No token provided."); sys.exit(1)
    _TOKEN = tok
    _save_token(tok)
    return tok

def _save_token(tok):
    print(f"\n  {B}Save credentials?{X}")
    print(f"  {B}1{X}  Yes — DPAPI-encrypted, tied to this Windows login")
    print(f"  {B}2{X}  No  — session only")
    if input("\n  [1/2]: ").strip() != "2":
        KEYS_DIR.mkdir(parents=True, exist_ok=True)
        # Use cf_creds internals to save
        import ctypes, ctypes.wintypes
        class _BLOB(ctypes.Structure):
            _fields_=[("cbData",ctypes.wintypes.DWORD),("pbData",ctypes.POINTER(ctypes.c_char))]
        data = json.dumps({"cf_token": tok}).encode()
        bi = _BLOB(len(data), ctypes.cast(ctypes.c_char_p(data), ctypes.POINTER(ctypes.c_char)))
        bo = _BLOB()
        if not ctypes.windll.crypt32.CryptProtectData(
                ctypes.byref(bi), None, None, None, None, 0x01, ctypes.byref(bo)):
            warn(f"DPAPI encryption failed (error {ctypes.GetLastError()}) — token not saved.")
        else:
            try:
                enc = ctypes.string_at(bo.pbData, bo.cbData)
                (KEYS_DIR / "cf_creds.dpapi").write_bytes(enc)
                ok("Credentials saved (DPAPI-encrypted).")
            finally:
                if bo.pbData:
                    ctypes.windll.kernel32.LocalFree(bo.pbData)

def _pick_account(accts):
    if len(accts) == 1:
        ok(f"Account: {accts[0]['name']}")
        return accts[0]
    print(f"\n  {B}Select account:{X}")
    for i, a in enumerate(accts, 1):
        print(f"  {B}{i}{X}  {a['name']}  {D}({a['id'][:8]}...){X}")
    idx = input("\n  Account [1]: ").strip()
    return accts[int(idx)-1] if idx.isdigit() and 1 <= int(idx) <= len(accts) else accts[0]

# ═════════════════════════════════════════════════════════════════════════════
#  Step 2 – Discover account + workers.dev subdomain
# ═════════════════════════════════════════════════════════════════════════════
def step_discover() -> tuple[str, str, str]:
    hdr("Step 2: Discover account & workers.dev subdomain")
    accts = api("GET", "/accounts").get("result", [])
    if not accts:
        err("No accounts found. Check token permissions."); sys.exit(1)
    acct = _pick_account(accts)
    acct_id = acct["id"]

    # Get workers.dev subdomain
    r = api("GET", f"/accounts/{acct_id}/workers/subdomain")
    subdomain = r.get("result", {}).get("subdomain") if r.get("success") else None
    if not subdomain:
        # Try via zones
        warn("Could not fetch workers.dev subdomain automatically.")
        subdomain = input("  Enter your workers.dev subdomain (e.g. 'alice'): ").strip()
    ok(f"workers.dev subdomain: {subdomain}.workers.dev")
    ok(f"Account: {acct['name']} ({acct_id[:8]}...)")
    return acct_id, acct["name"], subdomain

# ═════════════════════════════════════════════════════════════════════════════
#  Step 3 – Tunnel
# ═════════════════════════════════════════════════════════════════════════════
TUNNEL_NAME = "home-ssh"

def step_tunnel(acct_id) -> tuple[str, str]:
    hdr("Step 3: CF Tunnel")
    r = api("GET", f"/accounts/{acct_id}/cfd_tunnel?name={TUNNEL_NAME}")
    tunnels = [t for t in r.get("result", []) if t.get("name") == TUNNEL_NAME and not t.get("deleted_at")]
    if tunnels:
        t = tunnels[0]
        ok(f"Found existing tunnel '{TUNNEL_NAME}': {t['id'][:8]}...")
        return t["id"], t.get("token", "")

    print(f"  Creating tunnel '{TUNNEL_NAME}'...")
    r = api("POST", f"/accounts/{acct_id}/cfd_tunnel", {
        "name":          TUNNEL_NAME,
        "tunnel_secret": base64.b64encode(os.urandom(32)).decode(),
        "config_src":    "cloudflare",
    })
    if not r.get("success"):
        err(f"Failed to create tunnel: {r.get('errors')}"); sys.exit(1)
    tunnel = r["result"]
    tunnel_id  = tunnel["id"]
    tunnel_tok = tunnel.get("token", "")
    ok(f"Tunnel '{TUNNEL_NAME}' created: {tunnel_id[:8]}...")

    # Retrieve tunnel token (may need separate call)
    if not tunnel_tok:
        r2 = api("GET", f"/accounts/{acct_id}/cfd_tunnel/{tunnel_id}/token")
        tunnel_tok = r2.get("result", "") if r2.get("success") else ""

    return tunnel_id, tunnel_tok

# ═════════════════════════════════════════════════════════════════════════════
#  Step 4 – KV namespace
# ═════════════════════════════════════════════════════════════════════════════
def step_kv(acct_id) -> str:
    hdr("Step 4: KV Namespace (ssh-portal)")
    r = api("GET", f"/accounts/{acct_id}/storage/kv/namespaces")
    ns = next((n for n in r.get("result",[]) if n["title"]=="ssh-portal"), None)
    if ns:
        ok(f"Found existing KV namespace: {ns['id'][:8]}...")
        return ns["id"]
    r = api("POST", f"/accounts/{acct_id}/storage/kv/namespaces", {"title":"ssh-portal"})
    if not r.get("success"):
        err(f"Failed to create KV namespace: {r.get('errors')}"); sys.exit(1)
    ok(f"Created KV namespace: {r['result']['id'][:8]}...")
    return r["result"]["id"]

# ═════════════════════════════════════════════════════════════════════════════
#  Step 5 – Deploy Workers
# ═════════════════════════════════════════════════════════════════════════════
def _deploy_worker(acct_id, script_name, worker_js):
    """Deploy a single ES module Worker and enable workers.dev."""
    boundary = f"----Bootstrap{script_name}Boundary"
    meta = json.dumps({
        "main_module": "worker.js",
        "compatibility_date": "2024-09-23",
        "bindings": [],
        "logpush": False,
    })
    def mp(name, val, fn=None, ct="text/plain"):
        cd = f'Content-Disposition: form-data; name="{name}"'
        if fn: cd += f'; filename="{fn}"'
        p  = f"--{boundary}\r\n{cd}\r\nContent-Type: {ct}\r\n\r\n"
        return p.encode() + val.encode() + b"\r\n"
    body  = mp("metadata", meta, "metadata.json", "application/json")
    body += mp("worker.js", worker_js, "worker.js", "application/javascript+module")
    body += f"--{boundary}--\r\n".encode()

    url = f"https://api.cloudflare.com/client/v4/accounts/{acct_id}/workers/scripts/{script_name}"
    req = urllib.request.Request(url, data=body, method="PUT")
    req.add_header("Authorization", f"Bearer {_TOKEN}")
    req.add_header("Content-Type",  f"multipart/form-data; boundary={boundary}")
    try:
        with urllib.request.urlopen(req, context=_SSL) as r:
            result = json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:    result = json.loads(e.read())
        except: result = {"success": False, "errors": [str(e)]}
    except Exception as e:
        result = {"success": False, "errors": [str(e)]}

    if not result.get("success"):
        err(f"Worker '{script_name}' deploy failed: {result.get('errors')}")
        return False

    # Enable workers.dev subdomain
    sub_url = f"https://api.cloudflare.com/client/v4/accounts/{acct_id}/workers/scripts/{script_name}/subdomain"
    sub_req = urllib.request.Request(
        sub_url, data=json.dumps({"enabled": True}).encode(), method="POST")
    sub_req.add_header("Authorization", f"Bearer {_TOKEN}")
    sub_req.add_header("Content-Type",  "application/json")
    try:
        with urllib.request.urlopen(sub_req, context=_SSL) as r:
            json.loads(r.read())
    except urllib.error.HTTPError as e:
        body_txt = e.read().decode()
        if e.code not in (409,) and "already" not in body_txt and "10054" not in body_txt:
            warn(f"Could not enable workers.dev for '{script_name}': {e.code}")
    except Exception:
        pass
    return True


def _ssh_worker_js(tunnel_id, ssh_host):
    return f"""\
// SSH proxy Worker: forwards cloudflared SSH traffic to the CF Tunnel.
const TUNNEL   = '{tunnel_id}.cfargotunnel.com';
const SSH_HOST = '{ssh_host}';
export default {{
  async fetch(request) {{
    const url  = new URL(request.url);
    const dest = new URL(url.pathname + url.search, `https://${{TUNNEL}}`);
    const headers = new Headers();
    for (const [k, v] of request.headers) {{
      if (/^(cf-|x-forwarded-|x-real-ip)/i.test(k)) continue;
      headers.set(k, v);
    }}
    headers.set('Host', SSH_HOST);
    return fetch(dest.toString(), {{
      method: request.method, headers,
      body: ['GET','HEAD'].includes(request.method) ? undefined : request.body,
    }});
  }}
}};
"""

def step_workers(acct_id, subdomain, tunnel_id):
    hdr("Step 5: Deploy SSH Worker")
    ssh_host = f"ssh.{subdomain}.workers.dev"

    print(f"  Deploying 'ssh' Worker ...", end=" ", flush=True)
    if _deploy_worker(acct_id, "ssh", _ssh_worker_js(tunnel_id, ssh_host)):
        print(f"{G}OK{X}  ->  https://{ssh_host}")
    else:
        print(f"{R}FAILED{X}")

# ═════════════════════════════════════════════════════════════════════════════
#  Step 6 – Tunnel ingress
# ═════════════════════════════════════════════════════════════════════════════
def step_ingress(acct_id, tunnel_id, subdomain):
    hdr("Step 6: Tunnel ingress rules")
    ssh_host  = f"ssh.{subdomain}.workers.dev"

    url = f"/accounts/{acct_id}/cfd_tunnel/{tunnel_id}/configurations"
    r   = api("GET", url)
    existing = r.get("result", {}).get("config", {}).get("ingress", [])

    # Load Access aud tag + team name for origin-side JWT validation
    cfg = get_config()
    ssh_aud   = cfg.get("ssh_app_aud", "")
    team_name = cfg.get("team_name", "")

    # Build SSH ingress rule with Access validation
    ssh_rule = {"hostname": ssh_host, "service": "ssh://localhost:22"}
    if ssh_aud and team_name:
        ssh_rule["originRequest"] = {
            "access": {
                "required": True,
                "teamName": team_name,
                "audTag":   [ssh_aud],
            }
        }

    rules = [
        ssh_rule,
        {"service": "http_status:404"},
    ]

    has_ssh = any(isinstance(x, dict) and x.get("hostname") == ssh_host for x in existing)
    if has_ssh:
        # Check if existing rule already has Access validation
        ssh_existing = next(x for x in existing if isinstance(x, dict) and x.get("hostname") == ssh_host)
        has_access = bool(ssh_existing.get("originRequest", {}).get("access"))
        if has_access or not ssh_aud:
            ok("Tunnel ingress already configured.")
            return
        # Upgrade: add Access validation to existing ingress
        print(f"  Upgrading ingress with Access JWT validation...")

    r2 = api("PUT", url, {"config": {"ingress": rules}})
    if r2.get("success"):
        ok(f"Ingress set: {ssh_host} -> ssh://localhost:22")
        if ssh_aud:
            ok(f"Access JWT validation enabled (team: {team_name})")
        ok("cloudflared on the home machine will pick this up automatically.")
    else:
        warn(f"Ingress update failed: {r2.get('errors')}")
        warn("You may need to update your cloudflared config manually.")

# ═════════════════════════════════════════════════════════════════════════════
#  Step 7 – CF Access (optional)
# ═════════════════════════════════════════════════════════════════════════════
def step_access(acct_id, subdomain, emails):
    hdr("Step 7: CF Zero Trust Access (OTP email + browser SSH + short-lived certs)")
    if not emails:
        print(f"  {D}Skipped (no emails provided).{X}")
        return

    import importlib.util
    spec = importlib.util.spec_from_file_location("sca", SCRIPT_DIR/"lib"/"setup_cf_access.py")
    mod  = importlib.util.module_from_spec(spec)
    mod.ACCT       = acct_id
    mod.SSH_HOST   = f"ssh.{subdomain}.workers.dev"
    mod.CF_TOKEN   = _TOKEN
    spec.loader.exec_module(mod)

    org = mod.ensure_org()
    if not org:
        warn("Zero Trust org setup failed. Skipping Access policies.")
        warn("Make sure token has 'Zero Trust Edit' permission.")
        return

    team_name = org.get("auth_domain", "").replace(".cloudflareaccess.com", "")
    mod.ensure_otp_idp()

    # SSH app (type "ssh" — browser-rendered terminal + short-lived certs)
    ssh_app_id, ssh_aud = mod.ensure_app(
        mod.SSH_HOST, "SSH Browser Terminal", app_type="ssh", session_duration="24h")
    if ssh_app_id:
        mod.ensure_policy(ssh_app_id, emails)
        ssh_ca = mod.ensure_ssh_ca(ssh_app_id)
        if ssh_ca:
            save_config({
                "ssh_ca_public_key": ssh_ca,
                "ssh_app_aud":       ssh_aud,
                "team_name":         team_name,
            })
            ok("SSH short-lived certificate CA generated and saved")

    ok("CF Access configured.")

# ═════════════════════════════════════════════════════════════════════════════
#  Step 8 – Deploy ts-relay Worker
# ═════════════════════════════════════════════════════════════════════════════
def step_ts_relay(acct_id, subdomain) -> str | None:
    hdr("Step 8: Deploy ts-relay Worker (Tailscale bypass)")
    import importlib.util
    spec = importlib.util.spec_from_file_location("dtrw", SCRIPT_DIR / "lib" / "deploy_ts_relay_worker.py")
    mod  = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)

    relay_host = f"ts-relay.{subdomain}.workers.dev"
    relay_url  = f"https://{relay_host}"
    print(f"  Deploying 'ts-relay' Worker ...", end=" ", flush=True)
    if mod.deploy(acct_id, subdomain, _TOKEN):
        print(f"{G}OK{X}  →  {relay_url}")
        ok(f"Tailscale control plane + DERP proxied through workers.dev")
        save_config({"ts_relay_url": relay_url})  # update config with confirmed relay URL
        return relay_url
    else:
        print(f"{R}FAILED{X}")
        warn("ts-relay deploy failed. Retry: python deploy_ts_relay_worker.py")
        return None


# ═════════════════════════════════════════════════════════════════════════════
#  Step 9 – Build tsnet binary
# ═════════════════════════════════════════════════════════════════════════════
def _get_latest_go_info() -> tuple[str, str]:
    """
    Fetch the latest stable Go version + SHA256 for windows/amd64 zip from go.dev.
    Returns (version, sha256) — sha256 may be empty string if unavailable.
    """
    try:
        req = urllib.request.Request("https://go.dev/dl/?mode=json")
        with urllib.request.urlopen(req, context=_SSL, timeout=15) as r:
            releases = json.loads(r.read())
        for rel in releases:
            if rel.get("stable") and rel.get("version", "").startswith("go"):
                ver = rel["version"][2:]  # strip "go" → "1.22.3"
                for f in rel.get("files", []):
                    if (f.get("os") == "windows" and f.get("arch") == "amd64"
                            and f.get("kind") == "archive"):
                        return ver, f.get("sha256", "")
                return ver, ""  # version found but no file match
    except Exception as e:
        warn(f"Could not fetch Go release info: {e}")
    warn("Using fallback Go version 1.22.3 (may be outdated — check https://go.dev/dl/)")
    return "1.22.3", ""


def _download_go_toolchain() -> str | None:
    """
    Returns path to go.exe.
    Checks: bin/go-toolchain/bin/go.exe → system go → downloads latest.
    """
    # Already present from a previous bootstrap run
    local_go = BIN_DIR / "go-toolchain" / "bin" / "go.exe"
    if local_go.exists():
        ok(f"Go toolchain already present.")
        return str(local_go)

    # System Go
    try:
        r = subprocess.run(["go", "version"], capture_output=True, timeout=10)
        if r.returncode == 0:
            ok(f"System Go: {r.stdout.decode().strip()}")
            return "go"
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        pass

    # Download portable Go (no admin, no installer)
    go_ver, go_sha256 = _get_latest_go_info()
    go_url = f"https://go.dev/dl/go{go_ver}.windows-amd64.zip"
    go_zip = BIN_DIR / f"go{go_ver}.windows-amd64.zip"
    BIN_DIR.mkdir(parents=True, exist_ok=True)

    print(f"  Downloading Go {go_ver} (~130 MB) ...")
    print(f"  {D}{go_url}{X}")
    try:
        req = urllib.request.Request(go_url)
        with urllib.request.urlopen(req, context=_SSL) as resp:
            total = int(resp.headers.get("Content-Length") or 0)
            downloaded = 0
            with open(go_zip, "wb") as fh:
                while True:
                    chunk = resp.read(65536)
                    if not chunk:
                        break
                    fh.write(chunk)
                    downloaded += len(chunk)
                    if total > 0:
                        pct = min(100, downloaded * 100 // total)
                        print(f"\r  {pct:3d}%", end="", flush=True)
        print()
    except Exception as e:
        warn(f"Go download failed: {e}")
        warn("Install Go manually from https://go.dev/dl/ and re-run: python bootstrap.py --build-tsnet")
        go_zip.unlink(missing_ok=True)
        return None

    # Verify SHA256 if we have one
    if go_sha256:
        actual = hashlib.sha256(go_zip.read_bytes()).hexdigest()
        if actual != go_sha256:
            err(f"Go archive SHA256 mismatch — download may be corrupted or intercepted.")
            err(f"  expected: {go_sha256}")
            err(f"  got:      {actual}")
            go_zip.unlink(missing_ok=True)
            return None
        ok(f"SHA256 verified.")
    else:
        warn("Could not verify Go archive checksum (SHA256 unavailable).")

    print(f"  Extracting ...")
    try:
        with zipfile.ZipFile(go_zip) as zf:
            zf.extractall(BIN_DIR)
        extracted = BIN_DIR / "go"
        if not extracted.exists():
            err("Extraction produced unexpected directory structure.")
            go_zip.unlink(missing_ok=True)
            return None
        shutil.move(str(extracted), str(BIN_DIR / "go-toolchain"))
        go_zip.unlink(missing_ok=True)
    except Exception as e:
        warn(f"Extraction failed: {e}")
        go_zip.unlink(missing_ok=True)
        return None

    # Quick smoke test
    go_exe_path = BIN_DIR / "go-toolchain" / "bin" / "go.exe"
    try:
        r = subprocess.run([str(go_exe_path), "version"], capture_output=True, timeout=10)
        if r.returncode != 0:
            err("Go binary failed self-test after extraction.")
            return None
        ok(f"Go toolchain: {r.stdout.decode().strip()}")
    except Exception as e:
        err(f"Could not run extracted Go binary: {e}")
        return None

    return str(go_exe_path)


def _build_tsnet(go_exe: str) -> bool:
    """Download latest tailscale and build tsnet.exe."""
    tsnet_src = SCRIPT_DIR / "tsnet"
    tsnet_exe = BIN_DIR / "tsnet.exe"

    if not tsnet_src.exists() or not (tsnet_src / "main.go").exists():
        warn("tsnet/main.go not found. Cannot build.")
        return False

    _go_env = os.environ.copy()
    _go_env["GONOSUMDB"] = "*"
    _go_env["GOFLAGS"]   = "-mod=mod"

    # Update to latest tailscale
    print(f"  Fetching latest tailscale.com (this may take a few minutes)...")
    r = subprocess.run(
        [go_exe, "get", "tailscale.com@latest"],
        cwd=tsnet_src, capture_output=True, timeout=300, env=_go_env)
    if r.returncode != 0:
        warn(f"go get failed (building with pinned version):")
        for line in r.stderr.decode()[:400].splitlines():
            print(f"    {D}{line}{X}")

    print(f"  Running go mod tidy ...")
    r = subprocess.run(
        [go_exe, "mod", "tidy"],
        cwd=tsnet_src, capture_output=True, timeout=120, env=_go_env)
    if r.returncode != 0:
        warn(f"go mod tidy failed:")
        for line in r.stderr.decode()[:400].splitlines():
            print(f"    {D}{line}{X}")
        return False

    print(f"  Building tsnet.exe (first build ~2-3 min, subsequent builds faster)...")
    env = os.environ.copy()
    env["GOOS"]      = "windows"
    env["GOARCH"]    = "amd64"
    env["GONOSUMDB"] = "*"     # skip sum DB — helps if sum.golang.org blocked by corporate proxy
    env["GOFLAGS"]   = "-mod=mod"  # allow go.mod to be updated during build
    r = subprocess.run(
        [go_exe, "build", "-ldflags", "-s -w", "-o", str(tsnet_exe), "."],
        cwd=tsnet_src, capture_output=True, timeout=600, env=env)
    if r.returncode != 0:
        err(f"Build failed:")
        for line in r.stderr.decode()[:1200].splitlines():
            print(f"    {line}")
        return False

    ok(f"tsnet.exe built: {tsnet_exe}")
    return True


def step_build_tsnet():
    hdr("Step 9: Build tsnet binary (userspace Tailscale)")
    go_exe = _download_go_toolchain()
    if not go_exe:
        warn("Skipping tsnet build. Run later: python bootstrap.py --build-tsnet")
        return False
    if not _build_tsnet(go_exe):
        warn("tsnet build failed. Run later: python bootstrap.py --build-tsnet")
        return False
    return True


# ═════════════════════════════════════════════════════════════════════════════
#  Save config + update cf_config.txt
# ═════════════════════════════════════════════════════════════════════════════
def step_save(acct_id, subdomain, tunnel_id, tunnel_tok, kv_ns_id):
    hdr("Saving configuration")
    ssh_host = f"ssh.{subdomain}.workers.dev"

    cfg = {
        "account_id":   acct_id,
        "subdomain":    subdomain,
        "tunnel_id":    tunnel_id,
        "kv_ns_id":     kv_ns_id,
        "ssh_host":     ssh_host,
    }
    if tunnel_tok:
        cfg["tunnel_token"] = tunnel_tok
    save_config(cfg)
    ok(f"Config saved to {CFG_FILE}")

    # Write CF_HOST to cf_config.txt so connect.bat / connect.sh pick it up
    cfg_txt_lines = []
    if CF_CFG_TXT.exists():
        for line in CF_CFG_TXT.read_text().splitlines():
            k = line.split("=", 1)[0] if "=" in line else ""
            if k not in ("CF_HOST",):
                cfg_txt_lines.append(line)
    cfg_txt_lines.append(f"CF_HOST={ssh_host}")
    CF_CFG_TXT.write_text("\n".join(cfg_txt_lines) + "\n")
    ok(f"cf_config.txt updated: CF_HOST={ssh_host}")

# ═════════════════════════════════════════════════════════════════════════════
#  Generate standalone installers (host + client, all platforms)
# ═════════════════════════════════════════════════════════════════════════════
def generate_installers(subdomain):
    """Generate self-contained installer scripts in keys/ (gitignored).

    Generates 4 files with self-documenting names:
      keys/home_linux_mac.sh  — Run on home machine (Linux/Mac) — needs sudo
      keys/home_windows.bat   — Run on home machine (Windows)   — needs admin
      keys/work_linux_mac.sh  — Run on work machine (Linux/Mac) — no admin
      keys/work_windows.bat   — Run on work machine (Windows)   — no admin

    All Windows files are pure .bat -- works when GPO/AppLocker blocks .ps1.
    Token + SSH CA key are baked in — no arguments needed.
    """
    from lib.config import get_config
    cfg = get_config()
    tunnel_tok = cfg.get("tunnel_token", "")
    ssh_ca_key = cfg.get("ssh_ca_public_key", "")
    ssh_host   = f"ssh.{subdomain}.workers.dev"

    if not tunnel_tok:
        warn("No tunnel token in config -- cannot generate installers")
        return None

    keys_dir = SCRIPT_DIR / "keys"
    keys_dir.mkdir(exist_ok=True)
    generated = {}

    # ══════════════════════════════════════════════════════════════════════
    #  HOME machine: Bash installer (Linux + macOS)
    # ══════════════════════════════════════════════════════════════════════
    host_sh = f'''#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  erebus-edge -- HOME machine setup (auto-generated -- do not commit)
#  Run this on the machine you want to SSH INTO (your home server).
#  For: Linux and macOS
#
#  Run:  chmod +x home_linux_mac.sh && sudo ./home_linux_mac.sh
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

TOKEN="{tunnel_tok}"
SSH_CA_KEY="{ssh_ca_key}"
SSH_HOST="{ssh_host}"

G='\\033[0;32m'; Y='\\033[1;33m'; R='\\033[0;31m'; X='\\033[0m'
ok()   {{ echo -e "${{G}}[OK]${{X}}   $*"; }}
info() {{ echo -e "${{Y}}[..]${{X}}   $*"; }}
err()  {{ echo -e "${{R}}[!!]${{X}}   $*" >&2; }}

IS_MAC=false; [[ "$(uname -s)" == "Darwin" ]] && IS_MAC=true

echo ""
echo "  ================================================"
echo "    erebus-edge -- Home Machine Setup (Linux/Mac)"
echo "  ================================================"
echo ""

# ── 1. Ensure SSH server is running ───────────────────────────────
if $IS_MAC; then
    # macOS: check Remote Login
    if systemsetup -getremotelogin 2>/dev/null | grep -qi "on"; then
        ok "Remote Login (SSH) is enabled"
    else
        info "Enabling Remote Login (SSH)..."
        sudo systemsetup -setremotelogin on 2>/dev/null || {{
            err "Could not enable Remote Login automatically"
            err "Enable manually: System Settings -> General -> Sharing -> Remote Login"
        }}
    fi
else
    # Linux: check sshd
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        ok "SSH server is running"
    else
        info "Starting SSH server..."
        sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd 2>/dev/null || {{
            err "Could not start sshd. Install: sudo apt install openssh-server"
        }}
    fi
fi

# ── 2. Install cloudflared ────────────────────────────────────────
if command -v cloudflared &>/dev/null; then
    ok "cloudflared already installed"
else
    info "Installing cloudflared..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)        CF_ARCH="amd64" ;;
        aarch64|arm64) CF_ARCH="arm64" ;;
        armv7*)        CF_ARCH="arm" ;;
        *)             err "Unknown arch: $ARCH"; exit 1 ;;
    esac
    if $IS_MAC; then
        if command -v brew &>/dev/null; then
            brew install cloudflare/cloudflare/cloudflared 2>/dev/null && ok "Installed via brew" || true
        fi
        if ! command -v cloudflared &>/dev/null; then
            curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${{CF_ARCH}}.tgz" -o /tmp/cf.tgz
            tar xzf /tmp/cf.tgz -C /usr/local/bin/ cloudflared 2>/dev/null || tar xzf /tmp/cf.tgz -C /tmp/ && sudo mv /tmp/cloudflared /usr/local/bin/
            sudo chmod +x /usr/local/bin/cloudflared
            rm -f /tmp/cf.tgz
            ok "cloudflared binary installed"
        fi
    else
        if command -v apt-get &>/dev/null; then
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \\
                | sudo tee /etc/apt/sources.list.d/cloudflared.list
            sudo apt-get update -qq && sudo apt-get install -y cloudflared 2>/dev/null && ok "Installed via apt"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y cloudflared 2>/dev/null && ok "Installed via dnf"
        fi
        if ! command -v cloudflared &>/dev/null; then
            sudo curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${{CF_ARCH}}" \\
                -o /usr/local/bin/cloudflared
            sudo chmod +x /usr/local/bin/cloudflared
            ok "cloudflared binary installed"
        fi
    fi
fi

# ── 3. Register tunnel service ────────────────────────────────────
info "Installing cloudflared tunnel service..."
if sudo cloudflared service install "$TOKEN" 2>/dev/null; then
    ok "Tunnel service installed and started"
else
    if pgrep -x cloudflared &>/dev/null; then
        info "Reinstalling with current token..."
        sudo cloudflared service uninstall 2>/dev/null || true
        sudo cloudflared service install "$TOKEN"
        ok "Service reinstalled"
    else
        err "Service install failed"
    fi
fi

# ── 4. SSH CA trust (short-lived certificates) ────────────────────
if [[ -n "$SSH_CA_KEY" ]]; then
    info "Configuring sshd to trust CF SSH CA..."
    if $IS_MAC; then
        CA_PATH="/etc/ssh/ca.pub"
        SSHD_CFG="/etc/ssh/sshd_config"
    else
        CA_PATH="/etc/ssh/ca.pub"
        SSHD_CFG="/etc/ssh/sshd_config"
    fi
    echo "$SSH_CA_KEY" | sudo tee "$CA_PATH" >/dev/null
    sudo chmod 600 "$CA_PATH"
    ok "CA key written to $CA_PATH"

    if grep -q "TrustedUserCAKeys" "$SSHD_CFG" 2>/dev/null; then
        ok "sshd_config already has TrustedUserCAKeys"
    else
        printf '\\n# Cloudflare Access short-lived SSH certificates\\nTrustedUserCAKeys %s\\n' "$CA_PATH" \\
            | sudo tee -a "$SSHD_CFG" >/dev/null
        ok "TrustedUserCAKeys added to sshd_config"
    fi

    # Restart sshd
    if $IS_MAC; then
        sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
        sudo launchctl load /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
        ok "sshd restarted (launchd)"
    else
        sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null
        ok "sshd restarted"
    fi
else
    info "No SSH CA key -- short-lived certs not configured"
fi

# ── 5. Verify ─────────────────────────────────────────────────────
info "Waiting for tunnel..."
sleep 5
if pgrep -x cloudflared &>/dev/null; then
    ok "cloudflared is running"
else
    err "cloudflared may not be running -- check: sudo systemctl status cloudflared"
fi

echo ""
echo "  ================================================"
echo "    Done!  Home machine is ready."
echo "  ================================================"
echo ""
echo "  Now run the WORK machine installer on the machine"
echo "  you connect FROM, then SSH via:"
echo "    Browser : https://$SSH_HOST"
echo "    CLI     : ssh YOUR_USER@$SSH_HOST"
echo ""
'''
    (keys_dir / "home_linux_mac.sh").write_text(host_sh)
    generated["home_sh"] = keys_dir / "home_linux_mac.sh"

    # ══════════════════════════════════════════════════════════════════════
    #  HOME machine: Batch installer (Windows) — pure .bat, no PowerShell
    # ══════════════════════════════════════════════════════════════════════
    host_bat = f'''@echo off
setlocal enabledelayedexpansion
REM ═══════════════════════════════════════════════════════════════════
REM  erebus-edge -- HOME machine setup for Windows (auto-generated)
REM  Run this on the machine you want to SSH INTO (your home server).
REM  Pure batch -- works even when PowerShell is blocked by GPO.
REM
REM  Right-click -> Run as Administrator
REM ═══════════════════════════════════════════════════════════════════

set "TOKEN={tunnel_tok}"
set "SSH_CA_KEY={ssh_ca_key}"
set "SSH_HOST={ssh_host}"

echo.
echo   ================================================
echo     erebus-edge -- Home Machine Setup (Windows)
echo   ================================================
echo.

REM ── 1. Ensure OpenSSH Server is installed + running ─────────────
echo   [..]  Checking OpenSSH Server...
sc query sshd >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  OpenSSH Server service exists
) else (
    echo   [..]  Installing OpenSSH Server via DISM...
    dism /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 /NoRestart >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK]  OpenSSH Server installed
    ) else (
        echo   [!!]  DISM install failed -- install OpenSSH Server manually
        echo         Settings -^> Apps -^> Optional Features -^> OpenSSH Server
    )
)
net start sshd >nul 2>&1
sc config sshd start=auto >nul 2>&1
echo   [OK]  sshd service running (auto-start enabled)

REM ── 2. Download cloudflared ─────────────────────────────────────
set "CF_DIR=%ProgramFiles%\\cloudflared"
set "CF_PATH=%CF_DIR%\\cloudflared.exe"

where cloudflared >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  cloudflared already in PATH
    for /f "delims=" %%i in ('where cloudflared') do set "CF_PATH=%%i"
    goto :cf_done
)
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared found at %CF_PATH%
    goto :cf_done
)

echo   [..]  Downloading cloudflared...
if not exist "%CF_DIR%" mkdir "%CF_DIR%"
set "CF_URL=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"

REM Try curl first (Windows 10 1803+), then certutil, then bitsadmin
curl.exe -fsSL -o "%CF_PATH%" "%CF_URL%" 2>nul
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared downloaded via curl
    goto :cf_done
)
certutil -urlcache -split -f "%CF_URL%" "%CF_PATH%" >nul 2>&1
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared downloaded via certutil
    goto :cf_done
)
bitsadmin /transfer cf /download /priority high "%CF_URL%" "%CF_PATH%" >nul 2>&1
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared downloaded via bitsadmin
    goto :cf_done
)
echo   [!!]  Could not download cloudflared. Download manually:
echo         %CF_URL%
echo         Place at: %CF_PATH%
goto :cf_done

:cf_done

REM ── 3. Install tunnel service ───────────────────────────────────
echo   [..]  Installing cloudflared tunnel service...
"%CF_PATH%" service install %TOKEN% >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  cloudflared service installed
) else (
    REM May already be installed -- try uninstall + reinstall
    "%CF_PATH%" service uninstall >nul 2>&1
    timeout /t 2 /nobreak >nul
    "%CF_PATH%" service install %TOKEN% >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK]  cloudflared service reinstalled
    ) else (
        echo   [!!]  Service install failed -- ensure running as Administrator
    )
)

REM ── 4. SSH CA trust (short-lived certificates) ──────────────────
if "%SSH_CA_KEY%"=="" (
    echo   [..]  No SSH CA key -- short-lived certs not configured
    goto :ca_done
)

echo   [..]  Configuring sshd to trust CF SSH CA...
set "SSH_DIR=%ProgramData%\\ssh"
set "CA_PATH=%SSH_DIR%\\ca.pub"
set "SSHD_CFG=%SSH_DIR%\\sshd_config"

echo %SSH_CA_KEY%> "%CA_PATH%"
echo   [OK]  CA key written to %CA_PATH%

if not exist "%SSHD_CFG%" (
    echo   [!!]  sshd_config not found at %SSHD_CFG%
    goto :ca_done
)

findstr /C:"TrustedUserCAKeys" "%SSHD_CFG%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  sshd_config already has TrustedUserCAKeys
) else (
    echo.>> "%SSHD_CFG%"
    echo # Cloudflare Access short-lived SSH certificates>> "%SSHD_CFG%"
    echo TrustedUserCAKeys %CA_PATH%>> "%SSHD_CFG%"
    echo   [OK]  TrustedUserCAKeys added to sshd_config
)

net stop sshd >nul 2>&1
net start sshd >nul 2>&1
echo   [OK]  sshd restarted with CF CA trust

:ca_done

REM ── 5. Verify ───────────────────────────────────────────────────
echo   [..]  Waiting for tunnel...
timeout /t 5 /nobreak >nul
sc query cloudflared | findstr /C:"RUNNING" >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  cloudflared is running
) else (
    echo   [!!]  cloudflared may not be running -- check: sc query cloudflared
)

echo.
echo   ================================================
echo     Done!  Home machine is ready.
echo   ================================================
echo.
echo   Now run the WORK machine installer on the machine
echo   you connect FROM, then SSH via:
echo     Browser : https://%SSH_HOST%
echo     CLI     : ssh YOUR_USER@%SSH_HOST%
echo.
endlocal
'''
    (keys_dir / "home_windows.bat").write_text(host_bat)
    generated["home_bat"] = keys_dir / "home_windows.bat"

    # ══════════════════════════════════════════════════════════════════════
    #  WORK machine: Bash installer (Mac + Linux)
    # ══════════════════════════════════════════════════════════════════════
    client_sh = f'''#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  erebus-edge -- WORK machine setup (auto-generated -- do not commit)
#  Run this on the machine you connect FROM (your work/office machine).
#  For: Linux and macOS.  No admin/sudo required.
#
#  Run:  chmod +x work_linux_mac.sh && ./work_linux_mac.sh
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

SSH_HOST="{ssh_host}"
INSTALL_DIR="${{HOME}}/.erebus-edge"

G='\\033[0;32m'; Y='\\033[1;33m'; X='\\033[0m'
ok()   {{ echo -e "${{G}}[OK]${{X}}   $*"; }}
info() {{ echo -e "${{Y}}[..]${{X}}   $*"; }}

echo ""
echo "  ================================================"
echo "    erebus-edge -- Work Machine Setup (Linux/Mac)"
echo "  ================================================"
echo ""

mkdir -p "$INSTALL_DIR"

# ── 1. Download cloudflared (portable, no admin) ──────────────────
CF_BIN="$INSTALL_DIR/cloudflared"
if command -v cloudflared &>/dev/null; then
    ok "cloudflared already in PATH"
    CF_BIN=$(command -v cloudflared)
elif [[ -x "$CF_BIN" ]]; then
    ok "cloudflared already at $CF_BIN"
else
    ARCH=$(uname -m)
    OS=$(uname -s | tr A-Z a-z)
    case "$ARCH" in
        x86_64)        CF_ARCH="amd64" ;;
        aarch64|arm64) CF_ARCH="arm64" ;;
        armv7*)        CF_ARCH="arm" ;;
        *)             CF_ARCH="amd64" ;;
    esac
    if [[ "$OS" == "darwin" ]]; then
        info "Downloading cloudflared for macOS ($CF_ARCH)..."
        curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${{CF_ARCH}}.tgz" -o /tmp/cf.tgz
        tar xzf /tmp/cf.tgz -C "$INSTALL_DIR/"
        rm -f /tmp/cf.tgz
    else
        info "Downloading cloudflared for Linux ($CF_ARCH)..."
        curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${{CF_ARCH}}" -o "$CF_BIN"
    fi
    chmod +x "$CF_BIN"
    ok "cloudflared installed to $CF_BIN"
fi

# ── 2. Create connect script ─────────────────────────────────────
CONNECT="$INSTALL_DIR/connect.sh"
cat > "$CONNECT" << 'SCRIPT'
#!/usr/bin/env bash
SSH_HOST="__SSH_HOST__"
CF_BIN="__CF_BIN__"
read -rp "  Username on remote host: " USER
ssh -o "ProxyCommand=$CF_BIN access ssh --hostname $SSH_HOST" "$USER@$SSH_HOST"
SCRIPT
sed -i.bak "s|__SSH_HOST__|$SSH_HOST|g; s|__CF_BIN__|$CF_BIN|g" "$CONNECT" && rm -f "${{CONNECT}}.bak"
chmod +x "$CONNECT"
ok "Created $CONNECT"

# ── 3. SSH config entry ──────────────────────────────────────────
SSH_CFG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if grep -q "$SSH_HOST" "$SSH_CFG" 2>/dev/null; then
    ok "SSH config already has $SSH_HOST entry"
else
    cat >> "$SSH_CFG" << EOF

# erebus-edge -- CF Tunnel SSH
Host $SSH_HOST
    ProxyCommand $CF_BIN access ssh --hostname %h
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    chmod 600 "$SSH_CFG"
    ok "Added SSH config entry for $SSH_HOST"
    info "Connect with:  ssh YOUR_USER@$SSH_HOST"
fi

echo ""
echo "  ================================================"
echo "    Done!  Work machine is ready."
echo "  ================================================"
echo ""
echo "  Connect to your home machine:"
echo "    Browser : https://$SSH_HOST  (email OTP login)"
echo "    CLI     : ssh YOUR_USER@$SSH_HOST"
echo "    Script  : $CONNECT"
echo ""
'''
    (keys_dir / "work_linux_mac.sh").write_text(client_sh)
    generated["work_sh"] = keys_dir / "work_linux_mac.sh"

    # ══════════════════════════════════════════════════════════════════════
    #  WORK machine: Batch installer (Windows — no admin, no PowerShell)
    # ══════════════════════════════════════════════════════════════════════
    client_bat = f'''@echo off
setlocal enabledelayedexpansion
REM ═══════════════════════════════════════════════════════════════════
REM  erebus-edge -- WORK machine setup for Windows (auto-generated)
REM  Run this on the machine you connect FROM (your work/office machine).
REM  Pure batch -- works even when PowerShell is blocked by GPO.
REM  No admin needed. Downloads cloudflared to your user directory.
REM
REM  Double-click or run:  work_windows.bat
REM ═══════════════════════════════════════════════════════════════════

set "SSH_HOST={ssh_host}"
set "INSTALL_DIR=%LOCALAPPDATA%\\erebus-edge"

echo.
echo   ================================================
echo     erebus-edge -- Work Machine Setup (Windows)
echo   ================================================
echo.

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

REM ── 1. Download cloudflared (portable, no admin) ────────────────
set "CF_PATH=%INSTALL_DIR%\\cloudflared.exe"

where cloudflared >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  cloudflared already in PATH
    for /f "delims=" %%i in ('where cloudflared') do set "CF_PATH=%%i"
    goto :cf_done
)
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared already at %CF_PATH%
    goto :cf_done
)

echo   [..]  Downloading cloudflared...
set "CF_URL=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"

REM Try curl first (Windows 10 1803+), then certutil, then bitsadmin
curl.exe -fsSL -o "%CF_PATH%" "%CF_URL%" 2>nul
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared downloaded via curl
    goto :cf_done
)
certutil -urlcache -split -f "%CF_URL%" "%CF_PATH%" >nul 2>&1
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared downloaded via certutil
    goto :cf_done
)
bitsadmin /transfer cf /download /priority high "%CF_URL%" "%CF_PATH%" >nul 2>&1
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared downloaded via bitsadmin
    goto :cf_done
)
echo   [!!]  Could not download cloudflared automatically.
echo         Download manually from:
echo           %CF_URL%
echo         Save to: %CF_PATH%
goto :cf_done

:cf_done

REM ── 2. Create connect.bat ───────────────────────────────────────
set "CONNECT=%INSTALL_DIR%\\connect.bat"
(
    echo @echo off
    echo set /p RUSER=Username on remote host:
    echo "%CF_PATH%" access ssh --hostname %SSH_HOST%
    echo ssh -o "ProxyCommand=""%CF_PATH%"" access ssh --hostname %SSH_HOST%" %%RUSER%%@%SSH_HOST%
) > "%CONNECT%"
echo   [OK]  Created %CONNECT%

REM ── 3. SSH config entry ─────────────────────────────────────────
set "SSH_DIR=%USERPROFILE%\\.ssh"
set "SSH_CFG=%SSH_DIR%\\config"
if not exist "%SSH_DIR%" mkdir "%SSH_DIR%"

if exist "%SSH_CFG%" (
    findstr /C:"%SSH_HOST%" "%SSH_CFG%" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK]  SSH config already has %SSH_HOST% entry
        goto :ssh_done
    )
)

echo.>> "%SSH_CFG%"
echo # erebus-edge -- CF Tunnel SSH>> "%SSH_CFG%"
echo Host %SSH_HOST%>> "%SSH_CFG%"
echo     ProxyCommand "%CF_PATH%" access ssh --hostname %%h>> "%SSH_CFG%"
echo     StrictHostKeyChecking no>> "%SSH_CFG%"
echo     UserKnownHostsFile NUL>> "%SSH_CFG%"
echo   [OK]  Added SSH config entry for %SSH_HOST%
echo   [..]  Connect with:  ssh YOUR_USER@%SSH_HOST%

:ssh_done

echo.
echo   ================================================
echo     Done!  Work machine is ready.
echo   ================================================
echo.
echo   Connect to your home machine:
echo     Browser : https://%SSH_HOST%  (email OTP login)
echo     CLI     : ssh YOUR_USER@%SSH_HOST%
echo     Script  : %CONNECT%
echo.
endlocal
'''
    (keys_dir / "work_windows.bat").write_text(client_bat)
    generated["work_bat"] = keys_dir / "work_windows.bat"

    for name, path in generated.items():
        ok(f"Generated: {path.name}")

    return generated


# ═════════════════════════════════════════════════════════════════════════════
#  Summary
# ═════════════════════════════════════════════════════════════════════════════
def print_summary(subdomain, emails, tsnet_ok=False):
    from lib.config import get_config
    cfg = get_config()
    tunnel_tok  = cfg.get("tunnel_token", "")
    ssh_ca_key  = cfg.get("ssh_ca_public_key", "")

    # Generate standalone installers
    installers = None
    if tunnel_tok:
        installers = generate_installers(subdomain)

    print(f"\n{'═'*58}")
    print(f"  {G}{B}Bootstrap complete!{X}")
    print(f"{'═'*58}")
    print(f"""
  Your endpoints:
    Browser SSH : {C}https://ssh.{subdomain}.workers.dev{X}  (CF Access login)
    TS relay    : {C}https://ts-relay.{subdomain}.workers.dev{X}  (Tailscale bypass)
""")
    if emails:
        print(f"  CF Access (OTP email): {', '.join(emails)}")
    if ssh_ca_key:
        print(f"  Short-lived SSH certs: {G}ENABLED{X}")
    print()

    tsnet_note = (f"  {G}[ok]{X} tsnet.exe built -- run:  bin\\tsnet.exe up"
                  if tsnet_ok else
                  f"  {Y}[!!]{X} tsnet.exe not built. Run later:  python bootstrap.py --build-tsnet")

    if installers:
        print(f"""  {G}{B}What to do next:{X}

  {C}STEP 1 -- Set up your HOME machine{X} (the one you SSH into)
  Pick the file that matches your home machine's OS:

    {Y}Linux / Mac:{X}  {installers['home_sh']}
                  chmod +x home_linux_mac.sh && sudo ./home_linux_mac.sh

    {Y}Windows:{X}      {installers['home_bat']}
                  Right-click -> Run as Administrator

  {C}STEP 2 -- Set up your WORK machine{X} (the one you connect from)
  Pick the file that matches your work machine's OS:

    {Y}Linux / Mac:{X}  {installers['work_sh']}
                  chmod +x work_linux_mac.sh && ./work_linux_mac.sh

    {Y}Windows:{X}      {installers['work_bat']}
                  Double-click to run (no admin needed)

  All files are in keys/ (gitignored). Token + SSH CA baked in.
  Windows .bat files work even when GPO blocks PowerShell.

  {C}STEP 3 -- Connect{X}
    Browser : https://ssh.{subdomain}.workers.dev  (email OTP login)
    CLI     : ssh YOUR_USER@ssh.{subdomain}.workers.dev
""")
    else:
        print(f"""  After setting up your home machine:
    Browser : https://ssh.{subdomain}.workers.dev  (email OTP login)
    CLI     : ssh YOUR_USER@ssh.{subdomain}.workers.dev
""")

    print(f"""  Tailscale (optional, works independently):
{tsnet_note}
     Peers:  bin\\tsnet.exe status
     SSH:    ssh -o "ProxyCommand=bin\\tsnet.exe proxy %h %p" user@peer
""")

# ═════════════════════════════════════════════════════════════════════════════
#  Main
# ═════════════════════════════════════════════════════════════════════════════
def main():
    parser = argparse.ArgumentParser(description="SSH Portal bootstrap wizard")
    parser.add_argument("--redeploy",     action="store_true", help="Re-deploy all Workers (use existing config)")
    parser.add_argument("--skip-access",  action="store_true", help="Skip CF Access setup")
    parser.add_argument("--skip-tsnet",   action="store_true", help="Skip tsnet build step")
    parser.add_argument("--build-tsnet",  action="store_true", help="Only build tsnet binary (skip everything else)")
    parser.add_argument("--email",        action="append",     metavar="EMAIL", help="Email for CF Access policy (repeatable)")
    parser.add_argument("--workers-only", action="store_true", help="Skip tunnel and Access steps; just deploy Workers")
    args = parser.parse_args()

    print(f"\n{C}{B}  ╔══════════════════════════════════════════╗")
    print(f"  ║       SSH Portal — Bootstrap Wizard      ║")
    print(f"  ╚══════════════════════════════════════════╝{X}\n")
    print(f"  Each user deploys their OWN instance with their OWN CF account.")
    print(f"  Share the repo/zip — not the URL.\n")

    # ── Build-tsnet-only mode ─────────────────────────────────────────────
    if args.build_tsnet:
        tsnet_ok = step_build_tsnet()
        if tsnet_ok:
            ok("tsnet.exe ready. Run:  bin\\tsnet.exe up")
        return

    # ── Redeploy mode: skip setup, use existing config ────────────────────
    if args.redeploy:
        cfg = get_config()
        _req = ["account_id", "subdomain", "tunnel_id", "kv_ns_id"]
        missing = [k for k in _req if not cfg.get(k)]
        if missing:
            err(f"Config incomplete — missing: {', '.join(missing)}")
            err(f"Run full bootstrap first:  python bootstrap.py")
            sys.exit(1)
        acct_id   = cfg["account_id"]
        subdomain = cfg["subdomain"]
        tunnel_id = cfg["tunnel_id"]
        step_auth()
        step_workers(acct_id, subdomain, tunnel_id)
        step_ts_relay(acct_id, subdomain)
        tsnet_ok = False if args.skip_tsnet else step_build_tsnet()
        print_summary(subdomain, [], tsnet_ok)
        return

    # ── Full wizard ────────────────────────────────────────────────────────
    step_auth()
    acct_id, acct_name, subdomain = step_discover()

    if not args.workers_only:
        tunnel_id, tunnel_tok = step_tunnel(acct_id)
        kv_ns_id = step_kv(acct_id)
    else:
        cfg = get_config()
        tunnel_id  = cfg["tunnel_id"]
        tunnel_tok = ""
        kv_ns_id   = cfg["kv_ns_id"]

    # ── Save config early — so --redeploy works even if later steps fail ─────
    step_save(acct_id, subdomain, tunnel_id, tunnel_tok, kv_ns_id)

    step_workers(acct_id, subdomain, tunnel_id)

    if not args.workers_only:
        step_ingress(acct_id, tunnel_id, subdomain)

    # ── Step 8: ts-relay Worker (updates ts_relay_url in config on success) ──
    if not args.workers_only:
        step_ts_relay(acct_id, subdomain)

    # CF Access: collect emails
    emails = args.email or []
    if not args.skip_access and not args.workers_only and not emails:
        print(f"\n  {B}CF Zero Trust Access{X} protects the terminal (shell on home machine).")
        print(f"  Enter email addresses to allow. Press Enter with no input to skip.")
        while True:
            e = input("  Email (or Enter to skip): ").strip().lower()
            if not e: break
            emails.append(e)

    if emails and not args.skip_access:
        step_access(acct_id, subdomain, emails)

    # ── Step 9: Build tsnet binary ─────────────────────────────────────────
    tsnet_ok = False
    if not args.skip_tsnet:
        tsnet_ok = step_build_tsnet()

    print_summary(subdomain, emails, tsnet_ok)


if __name__ == "__main__":
    main()
