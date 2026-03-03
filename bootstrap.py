#!/usr/bin/env python3
"""
bootstrap.py -- First-run setup wizard for SSH Portal.

Works for ANY Cloudflare account. Share the repo, not the URL.
Each user runs this once to get their own deployment.

What it does:
  1. Authenticate via CF browser OAuth (no manual token needed)
     → creates a scoped 'ssh-portal' API token automatically
  2. Discover your workers.dev subdomain (e.g. "alice")
  3. Create a CF Tunnel named "home-ssh" (or reuse existing)
  4. Create/find the 'ssh-portal' KV namespace
  5. Deploy CF Workers: ssh, portal, term
  6. Update tunnel ingress for ssh + term routes
  7. Set up CF Zero Trust Access with email OTP (optional)
  8. Save everything to keys/portal_config.json
  9. Write CF_HOST to cf_config.txt (for connect.bat / connect.sh)

Usage:
  python bootstrap.py                  # full wizard
  python bootstrap.py --redeploy       # re-deploy Workers with existing config
  python bootstrap.py --skip-access    # skip CF Access setup
"""

import argparse, base64, getpass, hashlib, json, os, re, shutil, ssl, subprocess, sys, zipfile
import urllib.request, urllib.error, urllib.parse
from pathlib import Path

from config import get_config, save_config, CFG_FILE
import cf_creds as _creds_mod

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

def _term_worker_js(tunnel_id, term_host):
    return f"""\
// Terminal proxy Worker: forwards HTTP+WebSocket to ttyd via CF Tunnel.
const TUNNEL    = '{tunnel_id}.cfargotunnel.com';
const TERM_HOST = '{term_host}';
export default {{
  async fetch(request) {{
    const url  = new URL(request.url);
    const dest = new URL(url.pathname + url.search, `https://${{TUNNEL}}`);
    const headers = new Headers();
    for (const [k, v] of request.headers) {{
      if (/^(cf-|x-forwarded-|x-real-ip)/i.test(k)) continue;
      headers.set(k, v);
    }}
    headers.set('Host', TERM_HOST);
    try {{
      return await fetch(dest.toString(), {{
        method: request.method, headers,
        body: ['GET','HEAD'].includes(request.method) ? undefined : request.body,
        redirect: 'manual',
      }});
    }} catch(e) {{
      return new Response(
        `<html><body style="font-family:monospace;background:#0d1117;color:#e6edf3;padding:2rem">
         <h2 style="color:#f85149">&#x26A1; Terminal unreachable</h2>
         <p>Could not reach home machine. Make sure cloudflared + ttyd are running.</p>
         <p style="color:#8b949e">${{e.message}}</p></body></html>`,
        {{status:503,headers:{{'Content-Type':'text/html'}}}}
      );
    }}
  }}
}};
"""

def _portal_worker_js():
    """Load portal Worker JS from deploy_portal_worker.py (reuse its SPA)."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("dpm", SCRIPT_DIR/"deploy_portal_worker.py")
    mod  = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.WORKER_CODE


def step_workers(acct_id, subdomain, tunnel_id):
    hdr("Step 5: Deploy Workers")
    ssh_host    = f"ssh.{subdomain}.workers.dev"
    portal_host = f"portal.{subdomain}.workers.dev"
    term_host   = f"term.{subdomain}.workers.dev"

    workers = [
        ("ssh",    _ssh_worker_js(tunnel_id, ssh_host),    f"https://{ssh_host}"),
        ("portal", _portal_worker_js(),                     f"https://{portal_host}"),
        ("term",   _term_worker_js(tunnel_id, term_host),  f"https://{term_host}"),
    ]
    for name, js, url in workers:
        print(f"  Deploying '{name}' Worker ...", end=" ", flush=True)
        if _deploy_worker(acct_id, name, js):
            print(f"{G}OK{X}  →  {url}")
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
    spec = importlib.util.spec_from_file_location("sca", SCRIPT_DIR/"setup_cf_access.py")
    mod  = importlib.util.module_from_spec(spec)
    mod.ACCT       = acct_id
    mod.PORTAL_URL = f"portal.{subdomain}.workers.dev"
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

    # Portal app (self-hosted)
    portal_app_id, _ = mod.ensure_app(mod.PORTAL_URL, "SSH Portal")
    if portal_app_id:
        mod.ensure_policy(portal_app_id, emails)

    ok("CF Access configured.")

# ═════════════════════════════════════════════════════════════════════════════
#  Step 8 – Deploy ts-relay Worker
# ═════════════════════════════════════════════════════════════════════════════
def step_ts_relay(acct_id, subdomain) -> str | None:
    hdr("Step 8: Deploy ts-relay Worker (Tailscale bypass)")
    import importlib.util
    spec = importlib.util.spec_from_file_location("dtrw", SCRIPT_DIR / "deploy_ts_relay_worker.py")
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
    tsnet_src = SCRIPT_DIR / "tsnet-src"
    tsnet_exe = BIN_DIR / "tsnet.exe"

    if not tsnet_src.exists() or not (tsnet_src / "main.go").exists():
        warn("tsnet-src/main.go not found. Cannot build.")
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
    ssh_host    = f"ssh.{subdomain}.workers.dev"
    portal_host = f"portal.{subdomain}.workers.dev"
    term_host   = f"term.{subdomain}.workers.dev"

    # ts_relay_url is derived from subdomain here; step_ts_relay will
    # overwrite it with the confirmed URL after successful deploy.
    cfg = {
        "account_id":   acct_id,
        "subdomain":    subdomain,
        "tunnel_id":    tunnel_id,
        "kv_ns_id":     kv_ns_id,
        "ssh_host":     ssh_host,
        "portal_host":  portal_host,
        "term_host":    term_host,
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
#  Summary
# ═════════════════════════════════════════════════════════════════════════════
def print_summary(subdomain, emails, tsnet_ok=False):
    from config import get_config
    cfg = get_config()
    tunnel_tok  = cfg.get("tunnel_token", "")
    ssh_ca_key  = cfg.get("ssh_ca_public_key", "")

    print(f"\n{'═'*58}")
    print(f"  {G}{B}Bootstrap complete!{X}")
    print(f"{'═'*58}")
    print(f"""
  Your SSH Portal:
    Browser SSH : {C}https://ssh.{subdomain}.workers.dev{X}  (CF Access login)
    Portal      : {C}https://portal.{subdomain}.workers.dev{X}
    TS relay    : {C}https://ts-relay.{subdomain}.workers.dev{X}
""")
    if emails:
        print(f"  CF Access (OTP email): {', '.join(emails)}")
    if ssh_ca_key:
        print(f"  Short-lived SSH certs: {G}ENABLED{X}")
    print()

    tsnet_note = (f"  {G}[ok]{X} tsnet.exe built -- run:  bin\\tsnet.exe up"
                  if tsnet_ok else
                  f"  {Y}[!!]{X} tsnet.exe not built. Run later:  python bootstrap.py --build-tsnet")

    # Build home setup command
    if tunnel_tok:
        home_args = ["python3 home_setup.py"]
        home_args.append(f"    --token {tunnel_tok}")
        home_args.append(f"    --ssh-host ssh.{subdomain}.workers.dev")
        if ssh_ca_key:
            home_args.append(f"    --ssh-ca-key '{ssh_ca_key}'")
        home_py_cmd = " \\\n".join(home_args)
    else:
        home_py_cmd = "python3 home_setup.py --token <TOKEN>  # token in keys/portal_config.json"

    print(f"""  Next steps:

  1. On your HOME machine (Mac / Linux / Windows):

       {home_py_cmd}

     This installs cloudflared as a system service and (if --ssh-ca-key
     is provided) configures sshd to trust CF's short-lived certificates.

  2. Browser SSH terminal:
       https://ssh.{subdomain}.workers.dev
     Authenticate via email OTP -> browser SSH session opens.
     No SSH keys, no ttyd, no extra software on the home machine.

  3. CLI SSH (cloudflared ProxyCommand):
       connect.bat   (cmd)
       ./connect.sh  (Git Bash)

  4. Tailscale (works even without home-ssh):
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
