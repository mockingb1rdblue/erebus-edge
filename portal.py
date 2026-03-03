#!/usr/bin/env python3
"""
portal.py -- SSH Portal via Cloudflare Tunnel
Credentials and endpoint configs stored in CF Workers KV (not local disk).
CF API token stored DPAPI-encrypted locally, or session-only.
"""

import sys, os, json, ssl, base64, tempfile, subprocess, time, ctypes, ctypes.wintypes
import urllib.request, urllib.error, getpass
from pathlib import Path
from datetime import datetime

# Force UTF-8 output on Windows (avoids cp1252 encoding errors for box/tick chars)
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

# ── paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR  = Path(__file__).parent
BIN_DIR     = SCRIPT_DIR / "bin"
KEYS_DIR    = SCRIPT_DIR / "keys"
CREDS_FILE  = KEYS_DIR / "cf_creds.dpapi"       # CF token (DPAPI)
PORTAL_CFG  = KEYS_DIR / "portal_config.json"   # non-sensitive: acct id, ns id

CLOUDFLARED = str(BIN_DIR / "cloudflared.exe")

# ── SSL: bypass corporate revocation check ────────────────────────────────────
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode = ssl.CERT_NONE

# ── ANSI helpers ──────────────────────────────────────────────────────────────
os.system("")  # enable VT100 on Windows
G = "\033[32m"; Y = "\033[33m"; C = "\033[36m"; R = "\033[31m"
B = "\033[1m";  D = "\033[2m";  X = "\033[0m"

def banner():
    print(f"""{C}{B}
  ╔══════════════════════════════════════════╗
  ║        SSH Portal  ·  Cloudflare         ║
  ╚══════════════════════════════════════════╝{X}""")

def hline(): print(f"  {D}{'─'*44}{X}")
def ok(s):   return f"  {G}✓{X} {s}"
def warn(s): return f"  {Y}!{X} {s}"
def err(s):  return f"  {R}✗{X} {s}"
def dim(s):  return f"{D}{s}{X}"

# ── Windows DPAPI ─────────────────────────────────────────────────────────────
class _BLOB(ctypes.Structure):
    _fields_ = [("cbData", ctypes.wintypes.DWORD),
                ("pbData", ctypes.POINTER(ctypes.c_char))]

def _dpapi_enc(plain: str) -> bytes:
    data = plain.encode()
    bi = _BLOB(len(data), ctypes.cast(ctypes.c_char_p(data), ctypes.POINTER(ctypes.c_char)))
    bo = _BLOB()
    if not ctypes.windll.crypt32.CryptProtectData(ctypes.byref(bi), None, None, None, None, 0x01, ctypes.byref(bo)):
        raise RuntimeError(f"DPAPI encrypt failed: {ctypes.GetLastError()}")
    out = ctypes.string_at(bo.pbData, bo.cbData)
    ctypes.windll.kernel32.LocalFree(bo.pbData)
    return out

def _dpapi_dec(cipher: bytes) -> str:
    bi = _BLOB(len(cipher), ctypes.cast(ctypes.c_char_p(cipher), ctypes.POINTER(ctypes.c_char)))
    bo = _BLOB()
    if not ctypes.windll.crypt32.CryptUnprotectData(ctypes.byref(bi), None, None, None, None, 0x01, ctypes.byref(bo)):
        raise RuntimeError(f"DPAPI decrypt failed: {ctypes.GetLastError()}")
    out = ctypes.string_at(bo.pbData, bo.cbData).decode()
    ctypes.windll.kernel32.LocalFree(bo.pbData)
    return out

# ── CF API client ─────────────────────────────────────────────────────────────
class CF:
    BASE = "https://api.cloudflare.com/client/v4"

    def __init__(self, token: str, account_id: str = ""):
        self.token = token
        self.account_id = account_id

    def _r(self, method, path, data=None, raw=False):
        url = self.BASE + path
        body = (json.dumps(data).encode() if data is not None else None)
        req = urllib.request.Request(url, data=body, method=method)
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, context=_SSL) as r:
                return r.read() if raw else json.loads(r.read())
        except urllib.error.HTTPError as e:
            body = e.read()
            if raw: return None
            try:    return json.loads(body)
            except: return {"success": False, "errors": [str(e)]}
        except Exception as e:
            if raw: return None
            return {"success": False, "errors": [str(e)]}

    def get(self, p):        return self._r("GET", p)
    def post(self, p, d):    return self._r("POST", p, d)
    def put(self, p, d):     return self._r("PUT", p, d)
    def delete(self, p):     return self._r("DELETE", p)

    def kv_get(self, ns, key) -> str | None:
        url = f"{self.BASE}/accounts/{self.account_id}/storage/kv/namespaces/{ns}/values/{key}"
        req = urllib.request.Request(url)
        req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, context=_SSL) as r:
                return r.read().decode()
        except urllib.error.HTTPError as e:
            return None if e.code == 404 else None
        except Exception:
            return None

    def kv_put(self, ns, key, value: str):
        url = f"{self.BASE}/accounts/{self.account_id}/storage/kv/namespaces/{ns}/values/{key}"
        req = urllib.request.Request(url, data=value.encode(), method="PUT")
        req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, context=_SSL) as r:
                return json.loads(r.read())
        except Exception as e:
            return {"success": False, "errors": [str(e)]}

    def kv_del(self, ns, key):
        url = f"{self.BASE}/accounts/{self.account_id}/storage/kv/namespaces/{ns}/values/{key}"
        req = urllib.request.Request(url, method="DELETE")
        req.add_header("Authorization", f"Bearer {self.token}")
        try:
            with urllib.request.urlopen(req, context=_SSL) as r:
                return json.loads(r.read())
        except: pass

# ── local config (non-sensitive) ──────────────────────────────────────────────
def load_local_cfg() -> dict:
    if PORTAL_CFG.exists():
        try: return json.loads(PORTAL_CFG.read_text())
        except: pass
    return {}

def save_local_cfg(cfg: dict):
    KEYS_DIR.mkdir(parents=True, exist_ok=True)
    PORTAL_CFG.write_text(json.dumps(cfg, indent=2))

# ── OAuth via cloudflared login ───────────────────────────────────────────────
CF_CERT = KEYS_DIR / "cf_login.pem"

# Required permission group names for our scoped token
REQUIRED_PERMS = [
    "Cloudflare Tunnel Edit",
    "Workers Script Edit",
    "Workers KV Storage Edit",
    "Zero Trust Edit",
]

def _parse_cert_token(cert_path: Path) -> str | None:
    """
    cloudflared cert.pem may contain a SERVICE KEY PEM block whose raw bytes
    are the CF API bearer token, OR a JSON credentials sidecar file.
    Returns the token string, or None if it can't be extracted.
    """
    import re
    try:
        content = cert_path.read_text(errors="replace")
        # Method 1: SERVICE KEY PEM block
        m = re.search(
            r"-----BEGIN SERVICE KEY-----\r?\n(.*?)\r?\n-----END SERVICE KEY-----",
            content, re.DOTALL
        )
        if m:
            raw = m.group(1).replace("\n", "").replace("\r", "")
            token = base64.b64decode(raw).decode().strip()
            if token:
                return token

        # Method 2: JSON sidecar written by newer cloudflared versions
        sidecar = cert_path.with_suffix(".json")
        if sidecar.exists():
            data = json.loads(sidecar.read_text())
            for key in ("APIToken", "api_token", "token"):
                if key in data:
                    return data[key]
    except Exception:
        pass
    return None


PORTAL_TOKEN_NAME = "ssh-portal"


def _get_permission_groups(cf: CF) -> list[dict]:
    r = cf.get("/user/tokens/permission_groups")
    return r.get("result", []) if r.get("success") else []


def _list_user_tokens(cf: CF) -> list[dict]:
    r = cf.get("/user/tokens")
    return r.get("result", []) if r.get("success") else []


def _delete_token(cf: CF, token_id: str):
    cf.delete(f"/user/tokens/{token_id}")


def _create_portal_token(cf: CF, acct_id: str) -> str | None:
    """Create a minimal-scope ssh-portal token. Returns value (only at creation)."""
    all_groups = _get_permission_groups(cf)
    chosen = [g for g in all_groups if g.get("name") in REQUIRED_PERMS]
    if not chosen:
        print(warn("Could not resolve permission groups from CF."))
        return None

    r = cf.post("/user/tokens", {
        "name": PORTAL_TOKEN_NAME,
        "policies": [{
            "effect": "allow",
            "resources": {f"com.cloudflare.api.account.{acct_id}": "*"},
            "permission_groups": [{"id": g["id"]} for g in chosen],
        }],
    })
    return r["result"].get("value") if r.get("success") else None


def _manage_portal_token(cf: CF, acct_id: str) -> str | None:
    """
    Smart token management after browser login:
    - Shows any existing 'ssh-portal' tokens on the account
    - Offers to reuse (by paste), replace (delete + recreate), or create fresh
    - CF never returns existing token values — explains this clearly
    """
    all_tokens = _list_user_tokens(cf)
    portal_tokens = [t for t in all_tokens if t.get("name", "").startswith(PORTAL_TOKEN_NAME)]

    print()
    if portal_tokens:
        print(f"  {B}Found existing portal token(s) on your account:{X}")
        for t in portal_tokens:
            exp    = t.get("expiration_date", "")[:10] or "no expiry"
            status = f"{G}active{X}" if t.get("status") == "active" else f"{R}{t.get('status','')}{X}"
            print(f"    · {t['name']:<38} {status}  exp: {exp}")
        print()
        print(dim("  Note: Cloudflare never re-exposes token values after creation."))
        print()
        print(f"  {B}Options:{X}")
        print(f"  {B}1.{X} Paste the value of an existing token  {dim('(if you saved it)')}")
        print(f"  {B}2.{X} Replace — delete old token(s) and create a new one  {dim('(gets a fresh value automatically)')}")
        print(f"  {B}3.{X} Create additional token  {dim('(keeps existing ones — avoid if possible)')}")
        print()
        choice = input("  [1/2/3]: ").strip()

        if choice == "1":
            return getpass.getpass("  Paste token value: ").strip() or None

        elif choice == "2":
            for t in portal_tokens:
                _delete_token(cf, t["id"])
            print(ok(f"Deleted {len(portal_tokens)} old portal token(s)."))
            print(dim("  Creating fresh token with required permissions..."))
            token = _create_portal_token(cf, acct_id)
            if token:
                print(ok(f"Created '{PORTAL_TOKEN_NAME}' token."))
            return token

        else:  # 3 or anything else → just create
            pass

    else:
        print(dim(f"  No existing '{PORTAL_TOKEN_NAME}' token found."))

    # Create new (first time, or choice 3)
    print(dim(f"  Creating '{PORTAL_TOKEN_NAME}' token with these permissions:"))
    for p in REQUIRED_PERMS:
        print(dim(f"    · {p}"))
    print()
    token = _create_portal_token(cf, acct_id)
    if token:
        print(ok(f"Token '{PORTAL_TOKEN_NAME}' created — value captured automatically."))
    else:
        print(warn("Token creation failed. You can paste one manually."))
    return token


def _do_browser_login() -> str | None:
    """
    Run cloudflared login, wait for cert.pem, extract token.
    Returns bearer token string or None on failure.
    """
    KEYS_DIR.mkdir(parents=True, exist_ok=True)
    CF_CERT.unlink(missing_ok=True)

    print(f"\n{ok('Opening Cloudflare in your browser...')}")
    print(dim("  Log in and click Authorize on the page that opens."))
    print(dim("  When done, return here.\n"))

    subprocess.run(
        [CLOUDFLARED, "tunnel", "login", f"--origincert={CF_CERT}"],
        timeout=300
    )

    if not CF_CERT.exists():
        print(warn("Login did not complete (cert not found)."))
        return None

    token = _parse_cert_token(CF_CERT)

    # Whether or not we extracted a token, keep cert for cloudflared's own use.
    # If we got a token, delete cert (we'll store the token DPAPI instead).
    if token:
        CF_CERT.unlink(missing_ok=True)

    return token


# ── auth ──────────────────────────────────────────────────────────────────────
def do_auth(reset=False) -> tuple[CF, str, bool]:
    """
    Returns (CF client, account_name, session_only).

    Auth priority:
      1. DPAPI-stored token (from previous session)  →  silent load
      2. Browser OAuth (cloudflared login)            →  no paste needed
      3. Manual paste                                 →  fallback
    """
    token = None
    session_only = False

    # 1. Try stored token
    if not reset and CREDS_FILE.exists():
        try:
            data = json.loads(_dpapi_dec(CREDS_FILE.read_bytes()))
            token = data.get("cf_token")
            print(dim("  Using saved Cloudflare credentials."))
        except Exception:
            print(warn("Stored credentials could not be decrypted — re-authenticating."))
            CREDS_FILE.unlink(missing_ok=True)

    # 2. Prompt for auth method if no stored token
    if not token:
        print(f"\n  {B}Cloudflare authentication{X}\n")
        print(f"  {B}1.{X} Browser login  {dim('(no API key needed — opens Cloudflare in browser)')}")
        print(f"  {B}2.{X} Paste API token {dim('(manual — token from CF dashboard)')}")
        print()
        method = input("  How would you like to authenticate? [1/2]: ").strip()
        print()

        if method == "1":
            broad_token = _do_browser_login()

            if not broad_token:
                # Cert extraction failed — cloudflared login may use mTLS internally.
                # Fall back: show existing token names, ask user to paste value.
                print(warn("Could not extract token from cert automatically."))
                print(dim("  Note: Cloudflare does not expose token *values* after creation."))
                print()

                # Try to use cert for a quick account check
                tmp_cf = CF("") if not broad_token else CF(broad_token)
                tokens = []
                if broad_token:
                    tmp_cf.token = broad_token
                    tokens = _list_user_tokens(tmp_cf)

                if tokens:
                    print(f"  Tokens on your account (values not shown by CF):")
                    for t in tokens:
                        exp = t.get("expiration_date", "")[:10] or "never"
                        status = G + "active" + X if t.get("status") == "active" else R + t.get("status","") + X
                        print(f"    · {t['name']:<35} {status}  exp: {exp}")
                    print()
                    print(dim("  Open the CF dashboard to copy a token value, or create a new one."))
                    print(dim("  Dashboard → My Profile → API Tokens"))
                    print()

                token = getpass.getpass("  Paste token value: ").strip()

            else:
                # Got a broad token from cert — manage portal token smartly
                tmp_cf = CF(broad_token)
                accts = tmp_cf.get("/accounts").get("result", [])
                if accts:
                    tmp_cf.account_id = accts[0]["id"]
                    print(ok(f"Logged in as: {accts[0]['name']}"))
                    scoped = _manage_portal_token(tmp_cf, accts[0]["id"])
                    token = scoped or broad_token
                    if not scoped:
                        print(warn("Using broad login token — consider creating a scoped one."))
                else:
                    token = broad_token

        else:
            # Manual paste
            print(dim("  Dashboard → My Profile → API Tokens → Create Token"))
            print(dim(f"  Needs: {', '.join(REQUIRED_PERMS)}"))
            print()
            # Show existing tokens if we have a prior broad credential
            token = getpass.getpass("  Paste token value: ").strip()

        if not token:
            print(err("No token provided.")); sys.exit(1)

        # Ask about persistence
        print()
        print(f"  {B}Save credentials?{X}")
        print(f"  {B}1.{X} Yes — DPAPI-encrypted, tied to this Windows login, persists across sessions")
        print(f"  {B}2.{X} No  — session only, cleared when portal exits")
        print()
        persist = input("  [1/2]: ").strip()
        if persist == "1":
            KEYS_DIR.mkdir(parents=True, exist_ok=True)
            CREDS_FILE.write_bytes(_dpapi_enc(json.dumps({"cf_token": token})))
            print(ok("Credentials saved (DPAPI-encrypted)."))
        else:
            session_only = True
            print(ok("Session only — not written to disk."))
        print()

    # Verify token by listing accounts (avoids needing "API Tokens: Read" permission)
    cf = CF(token)
    accts = cf.get("/accounts").get("result", [])
    if not accts:
        print(err("No Cloudflare accounts found for this token.")); sys.exit(1)

    cfg = load_local_cfg()

    # If multiple accounts, let user pick (cached after first choice)
    if len(accts) > 1 and "account_id" not in cfg:
        print(f"\n  {B}Select account:{X}")
        for i, a in enumerate(accts, 1):
            print(f"  {i}. {a['name']}  {dim(a['id'][:8] + '...')}")
        idx = input("\n  Account [1]: ").strip()
        acct = accts[int(idx) - 1] if idx.isdigit() and 1 <= int(idx) <= len(accts) else accts[0]
    else:
        acct = next((a for a in accts if a["id"] == cfg.get("account_id")), accts[0])

    cf.account_id = acct["id"]
    cfg["account_id"] = acct["id"]
    save_local_cfg(cfg)

    return cf, acct["name"], session_only

# ── KV namespace ──────────────────────────────────────────────────────────────
NS_NAME = "ssh-portal"

def ensure_ns(cf: CF) -> str:
    """Return KV namespace ID for 'ssh-portal', creating if needed."""
    cfg = load_local_cfg()
    if "kv_ns_id" in cfg:
        return cfg["kv_ns_id"]

    ns_list = cf.get(f"/accounts/{cf.account_id}/storage/kv/namespaces").get("result", [])
    ns = next((n for n in ns_list if n["title"] == NS_NAME), None)

    if not ns:
        r = cf.post(f"/accounts/{cf.account_id}/storage/kv/namespaces", {"title": NS_NAME})
        if not r.get("success"):
            print(err(f"Could not create KV namespace: {r.get('errors')}")); sys.exit(1)
        ns = r["result"]
        print(ok(f"Created KV namespace '{NS_NAME}'"))

    cfg["kv_ns_id"]   = ns["id"]
    cfg["account_id"] = cf.account_id
    save_local_cfg(cfg)
    return ns["id"]

# ── endpoint helpers ──────────────────────────────────────────────────────────
DEFAULT_ENDPOINTS = {
    "home": {
        "cf_host": "ssh.mock1ng.workers.dev",
        "username": "",
        "port": 22,
        "has_key": False,
        "has_password": False,
        "last_connected": None,
        "connect_count": 0,
    }
}

def load_endpoints(cf: CF, ns: str) -> dict:
    raw = cf.kv_get(ns, "endpoints")
    if raw:
        try: return json.loads(raw)
        except: pass
    # first run: seed defaults and save
    cf.kv_put(ns, "endpoints", json.dumps(DEFAULT_ENDPOINTS))
    return dict(DEFAULT_ENDPOINTS)

def save_endpoints(cf: CF, ns: str, endpoints: dict):
    cf.kv_put(ns, "endpoints", json.dumps(endpoints))

def is_golden(ep: dict) -> bool:
    return bool(ep.get("username")) and (ep.get("has_key") or ep.get("has_password"))

def status_tag(ep: dict) -> str:
    if is_golden(ep):
        last = ep.get("last_connected", "")
        ts   = f"last: {last[:10]}" if last else "ready"
        return f"{G}✓ {ts}{X}"
    elif ep.get("username"):
        return f"{Y}○ no auth saved{X}"
    else:
        return f"{R}○ not configured{X}"

# ── Tailscale section ─────────────────────────────────────────────────────────
TSNET_EXE = str(BIN_DIR / "tsnet.exe")

def tsnet_status() -> list[dict] | None:
    """
    Run tsnet.exe status and return peer list, or None on failure.
    stderr is NOT captured so auth URL / progress is visible to the user.
    """
    if not Path(TSNET_EXE).exists():
        return None
    try:
        result = subprocess.run(
            [TSNET_EXE, "status"],
            stdout=subprocess.PIPE,   # capture JSON output
            stderr=None,              # let tsnet print auth URL / progress to terminal
            timeout=60)
        if result.returncode != 0:
            return None
        text = result.stdout.decode().strip()
        if not text:
            return []
        return json.loads(text)
    except subprocess.TimeoutExpired:
        print(warn("tsnet timed out. Check relay URL or run: bin\\tsnet.exe up"))
        return None
    except json.JSONDecodeError as e:
        print(warn(f"tsnet output was not valid JSON: {e}"))
        return None
    except Exception as e:
        print(warn(f"tsnet_status error: {type(e).__name__}: {e}"))
        return None


def handle_tailscale(cf: CF, ns: str, endpoints: dict) -> dict:
    os.system("cls")
    banner()
    print(f"\n  {B}Tailscale Peers{X}\n")
    hline()

    if not Path(TSNET_EXE).exists():
        print(f"  {R}✗{X} tsnet.exe not found at {TSNET_EXE}")
        print(f"\n  Build it first:")
        print(f"  {D}  python bootstrap.py --build-tsnet{X}")
        input("\n  Press Enter...")
        return endpoints

    print(f"  {D}Connecting via CF relay (may take ~10s)...{X}")
    print(f"  {D}If Tailscale auth is required, a URL will appear below — open it in your browser.{X}\n")
    peers = tsnet_status()

    if peers is None:
        print(f"  {R}✗{X} Could not get Tailscale status.")
        print(f"  Check that tsnet.exe is working:  bin\\tsnet.exe up")
        input("\n  Press Enter...")
        return endpoints

    if not peers:
        print(f"  {Y}!{X} No Tailscale peers found.")
        print(f"  Make sure your home machine is on the same Tailscale network.")
        input("\n  Press Enter...")
        return endpoints

    # Show peer list
    print(f"  {B}{'#':<4} {'Name':<24} {'IP':<16} {'OS':<10} Status{X}")
    hline()
    for i, p in enumerate(peers, 1):
        ip     = p.get("ips", ["?"])[0] if p.get("ips") else "?"
        status = f"{G}online{X}" if p.get("online") else f"{R}offline{X}"
        os_tag = p.get("os", "?")[:8]
        print(f"  {B}{i:<4}{X} {p.get('name','?'):<24} {ip:<16} {os_tag:<10} {status}")
    print()
    hline()
    print(f"  {B}B{X}  Back")
    hline()
    print()

    choice = input("  Peer [#]: ").strip().lower()
    if choice == "b" or choice == "":
        return endpoints

    if not choice.isdigit() or not (1 <= int(choice) <= len(peers)):
        print(err("Invalid choice")); time.sleep(1)
        return endpoints

    peer = peers[int(choice) - 1]
    peer_name = peer.get("dns") or peer.get("ips", [""])[0]
    if not peer_name:
        print(err("Peer has no address.")); time.sleep(1)
        return endpoints

    # Get/remember username per peer
    cfg = load_local_cfg()
    ts_users = cfg.get("ts_users", {})
    saved_user = ts_users.get(peer.get("name", ""), "")
    display = f" {D}[{saved_user}]{X}" if saved_user else ""
    user = input(f"  Username{display}: ").strip() or saved_user
    if not user:
        print(err("Username required.")); time.sleep(1)
        return endpoints

    # Remember username for next time
    ts_users[peer.get("name", "")] = user
    cfg["ts_users"] = ts_users
    save_local_cfg(cfg)

    port_str = input("  SSH port [22]: ").strip()
    port = int(port_str) if port_str.isdigit() else 22

    # Connect via tsnet ProxyCommand
    print(f"\n  Connecting to {B}{user}@{peer_name}{X} via Tailscale...")
    print(f"  {D}(tsnet routes through CF relay → Tailscale network){X}\n")

    proxy = f'"{TSNET_EXE}" proxy %h %p'
    cmd = [
        "ssh",
        "-o", f"ProxyCommand={proxy}",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-p", str(port),
        f"{user}@{peer_name}",
    ]

    try:
        subprocess.run(cmd)
    except Exception as e:
        print(warn(f"SSH error: {e}"))

    print(f"\n  {dim('Session ended.')}")
    input("  Press Enter to return to menu...")
    return endpoints


# ── main menu ─────────────────────────────────────────────────────────────────
def show_menu(cf: CF, ns: str, endpoints: dict, acct_name: str, session_only: bool):
    while True:
        os.system("cls")
        banner()
        print(f"\n  Account : {B}{acct_name}{X}  {dim('(' + cf.account_id[:8] + '...')}")
        auth_note = dim("session only — not stored") if session_only else dim("saved (DPAPI)")
        print(f"  Auth    : {auth_note}")
        print()
        hline()
        print(f"  {B}Endpoints{X}  {dim('(CF Tunnel → SSH)')}")
        hline()

        names = list(endpoints.keys())
        for i, name in enumerate(names, 1):
            ep  = endpoints[name]
            host = dim(ep.get("cf_host", "?"))
            user = f"{ep['username']}@" if ep.get("username") else dim("(no user) ")
            print(f"  {B}{i}{X}  {name:<16} {user}{host}")
            print(f"     {status_tag(ep)}")
            print()

        hline()
        ts_note = "" if Path(TSNET_EXE).exists() else f"  {D}(tsnet.exe not built yet){X}"
        print(f"  {B}A{X}  Add endpoint")
        print(f"  {B}T{X}  Tailscale peers{ts_note}")
        print(f"  {B}S{X}  Switch CF account")
        print(f"  {B}Q{X}  Quit")
        hline()
        print()

        choice = input("  Select: ").strip().lower()

        if choice == "q":
            break
        elif choice == "a":
            endpoints = add_endpoint(cf, ns, endpoints)
        elif choice == "t":
            endpoints = handle_tailscale(cf, ns, endpoints)
        elif choice == "s":
            return "switch"
        elif choice.isdigit() and 1 <= int(choice) <= len(names):
            name = names[int(choice) - 1]
            endpoints = handle_endpoint(cf, ns, endpoints, name)
        else:
            print(err("Invalid choice")); time.sleep(1)

    return "quit"

# ── endpoint flow ─────────────────────────────────────────────────────────────
def handle_endpoint(cf: CF, ns: str, endpoints: dict, name: str) -> dict:
    ep = endpoints[name]

    os.system("cls")
    banner()
    print(f"\n  {B}{name}{X}  ·  {ep.get('cf_host','?')}")
    print(f"  {status_tag(ep)}\n")
    hline()

    if is_golden(ep):
        auth_method = "SSH key" if ep.get("has_key") else "password"
        print(f"  Ready to connect as {B}{ep['username']}{X} using {auth_method}.")
        print()
        print(f"  {B}Enter{X}  Connect")
        print(f"  {B}S{X}      Settings")
        print(f"  {B}B{X}      Back")
        hline()
        choice = input("  > ").strip().lower()
        if choice == "":
            endpoints = do_connect(cf, ns, endpoints, name)
        elif choice == "s":
            endpoints = show_settings(cf, ns, endpoints, name)
        # b or anything else: back
    else:
        print(warn("Endpoint not fully configured. Opening settings."))
        time.sleep(1)
        endpoints = show_settings(cf, ns, endpoints, name)

    return endpoints

def do_connect(cf: CF, ns: str, endpoints: dict, name: str) -> dict:
    ep = endpoints[name]
    host = ep["cf_host"]
    user = ep["username"]
    port = ep.get("port", 22)

    print(f"\n  Connecting to {B}{user}@{host}{X} ...")

    tmp_key     = None
    tmp_askpass = None
    env         = os.environ.copy()

    # ── fetch SSH key from KV ─────────────────────────────────────────────────
    if ep.get("has_key"):
        raw_b64 = cf.kv_get(ns, f"key:{name}")
        if raw_b64:
            try:
                pem = base64.b64decode(raw_b64)
                fd, tmp_key = tempfile.mkstemp(suffix="_portal_key")
                os.write(fd, pem)
                os.close(fd)
                subprocess.run(
                    ["icacls", tmp_key, "/inheritance:r", "/grant:r",
                     f"{os.environ['USERNAME']}:F"],
                    capture_output=True
                )
            except Exception as e:
                print(warn(f"Could not load key from KV: {e}"))
                tmp_key = None

    # ── fetch password from KV and wire up SSH_ASKPASS ────────────────────────
    elif ep.get("has_password"):
        pw = cf.kv_get(ns, f"pass:{name}")
        if pw:
            # Write a minimal Python askpass helper that prints the password.
            # SSH_ASKPASS_REQUIRE=force tells OpenSSH to use it even with a TTY.
            fd, tmp_askpass = tempfile.mkstemp(suffix="_askpass.py")
            escaped = pw.replace("\\", "\\\\").replace("'", "\\'")
            os.write(fd, f"print('{escaped}')\n".encode())
            os.close(fd)
            env["SSH_ASKPASS"]         = f"{sys.executable} {tmp_askpass}"
            env["SSH_ASKPASS_REQUIRE"] = "force"
            env.pop("DISPLAY", None)   # suppress X11 forwarding on Windows
        else:
            print(warn("Password not found in KV — SSH will prompt."))

    # ── build SSH command ─────────────────────────────────────────────────────
    proxy = f'"{CLOUDFLARED}" access ssh --hostname {host}'
    cmd = [
        "ssh",
        "-o", f"ProxyCommand={proxy}",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        "-p", str(port),
    ]
    if tmp_key:
        cmd += ["-i", tmp_key]
    cmd.append(f"{user}@{host}")

    auth_note = "key from KV" if tmp_key else ("password from KV" if tmp_askpass else "password prompt")
    print(dim(f"  auth: {auth_note}"))
    print(dim("  Tip: once connected, run: tmux new -A -s work"))
    print()

    try:
        result = subprocess.run(cmd, env=env)
        if result.returncode == 0 or result.returncode == 130:
            ep["last_connected"] = datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
            ep["connect_count"]  = ep.get("connect_count", 0) + 1
            endpoints[name] = ep
            save_endpoints(cf, ns, endpoints)
    finally:
        for f in (tmp_key, tmp_askpass):
            if f:
                try: os.unlink(f)
                except: pass

    print(f"\n  {dim('Session ended.')}")
    input("  Press Enter to return to menu...")
    return endpoints

# ── settings ──────────────────────────────────────────────────────────────────
def show_settings(cf: CF, ns: str, endpoints: dict, name: str) -> dict:
    ep = dict(endpoints[name])

    os.system("cls")
    banner()
    print(f"\n  {B}Settings: {name}{X}\n")
    hline()

    def prompt(label, current, secret=False):
        display = dim(f"[{current}]") if current else dim("[not set]")
        if secret and current:
            display = dim("[saved]")
        fn = getpass.getpass if secret else input
        val = fn(f"  {label} {display}: ").strip()
        return val if val else current

    ep["cf_host"]  = prompt("CF hostname", ep.get("cf_host", ""))
    ep["username"] = prompt("Username",    ep.get("username", ""))
    port_str       = prompt("SSH port",    str(ep.get("port", 22)))
    try:    ep["port"] = int(port_str)
    except: ep["port"] = 22

    print()
    hline()
    print(f"  {B}Auth method{X}")
    print(f"  1. SSH key from CF KV  {'(' + G + 'stored' + X + ')' if ep.get('has_key') else dim('(none)')}")
    print(f"  2. Password in CF KV   {'(' + G + 'stored' + X + ')' if ep.get('has_password') else dim('(none)')}")
    print(f"  3. No saved auth — enter password each connect")
    if ep.get("has_key"):   print(f"  4. Clear saved key")
    if ep.get("has_password"): print(f"  5. Clear saved password")
    hline()
    auth_choice = input("  Auth [1/2/3]: ").strip()

    if auth_choice == "1":
        print()
        print("  SSH key options:")
        print("  A. Paste from clipboard")
        print("  B. Enter path to key file")
        print("  C. Generate new key + auto-install on home")
        key_src = input("  > ").strip().upper()

        key_pem = None
        if key_src == "A":
            import subprocess as _sp
            clip = _sp.run(
                ["powershell", "-NoProfile", "-Command", "Get-Clipboard"],
                capture_output=True, text=True
            ).stdout.strip().replace("\r", "")
            if clip: key_pem = clip
            else: print(warn("Clipboard empty."))

        elif key_src == "B":
            path = input("  Key file path: ").strip().strip('"')
            try:   key_pem = Path(path).read_text()
            except Exception as e: print(warn(f"Could not read file: {e}"))

        elif key_src == "C":
            import tempfile as _tf
            fd, tmppath = _tf.mkstemp(suffix="_newkey")
            os.close(fd)
            os.unlink(tmppath)
            subprocess.run(["ssh-keygen", "-t", "ed25519", "-f", tmppath, "-N", "", "-C", "cf-portal"])
            pub = Path(tmppath + ".pub").read_text().strip()
            key_pem = Path(tmppath).read_text()
            # auto-install public key on remote
            print(f"\n  Installing public key on {ep.get('cf_host','')} (enter password)...")
            proxy = f'"{CLOUDFLARED}" access ssh --hostname {ep["cf_host"]}'
            install_cmd = [
                "ssh",
                "-o", f"ProxyCommand={proxy}",
                "-o", "StrictHostKeyChecking=accept-new",
                "-p", str(ep.get("port", 22)),
                f"{ep['username']}@{ep['cf_host']}",
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
            ]
            proc = subprocess.run(install_cmd, input=pub + "\n", text=True)
            if proc.returncode == 0:
                print(ok("Public key installed on home machine"))
            else:
                print(warn("Auto-install may have failed — add key manually if needed"))
            # cleanup local temp files
            try: Path(tmppath).unlink()
            except: pass
            try: Path(tmppath + ".pub").unlink()
            except: pass

        if key_pem:
            b64 = base64.b64encode(key_pem.encode()).decode()
            cf.kv_put(ns, f"key:{name}", b64)
            ep["has_key"] = True
            ep["has_password"] = False
            print(ok("SSH key saved to CF KV"))

    elif auth_choice == "2":
        pw = getpass.getpass("  Password: ")
        if pw:
            cf.kv_put(ns, f"pass:{name}", pw)
            ep["has_password"] = True
            ep["has_key"] = False
            print(ok("Password saved to CF KV"))

    elif auth_choice == "3":
        ep["has_key"] = False
        ep["has_password"] = False

    elif auth_choice == "4" and ep.get("has_key"):
        cf.kv_del(ns, f"key:{name}")
        ep["has_key"] = False
        print(ok("Key cleared"))

    elif auth_choice == "5" and ep.get("has_password"):
        cf.kv_del(ns, f"pass:{name}")
        ep["has_password"] = False
        print(ok("Password cleared"))

    # fetch password at connect time if has_password
    if ep.get("has_password") and not ep.get("has_key"):
        # will be fetched from KV at connect time via SSH_ASKPASS is complex;
        # simplest: pass via sshpass or just let SSH prompt (stored in KV for reference)
        pass

    endpoints[name] = ep
    save_endpoints(cf, ns, endpoints)
    print(ok("Settings saved to CF KV"))
    input("\n  Press Enter to continue...")
    return endpoints

# ── add endpoint ──────────────────────────────────────────────────────────────
def add_endpoint(cf: CF, ns: str, endpoints: dict) -> dict:
    os.system("cls")
    banner()
    print(f"\n  {B}Add Endpoint{X}\n")
    hline()

    name = input("  Name (e.g. 'home', 'dev-server'): ").strip()
    if not name or name in endpoints:
        print(err("Name empty or already exists.")); time.sleep(1)
        return endpoints

    host = input("  CF hostname (e.g. ssh.mock1ng.workers.dev): ").strip()
    user = input("  Username: ").strip()
    port = input("  SSH port [22]: ").strip()

    endpoints[name] = {
        "cf_host": host,
        "username": user,
        "port": int(port) if port.isdigit() else 22,
        "has_key": False,
        "has_password": False,
        "last_connected": None,
        "connect_count": 0,
    }
    save_endpoints(cf, ns, endpoints)
    print(ok(f"Endpoint '{name}' added. Configure auth in settings."))
    input("  Press Enter to continue...")

    # go straight to settings to configure auth
    return show_settings(cf, ns, endpoints, name)

# ── switch account ────────────────────────────────────────────────────────────
def switch_account():
    CREDS_FILE.unlink(missing_ok=True)
    cfg = load_local_cfg()
    cfg.pop("account_id", None)
    cfg.pop("kv_ns_id", None)
    save_local_cfg(cfg)
    print(ok("Logged out. Restart portal to log in with a different account."))
    sys.exit(0)

# ── main ──────────────────────────────────────────────────────────────────────
def main():
    KEYS_DIR.mkdir(parents=True, exist_ok=True)

    reset_auth = "--reset-auth" in sys.argv

    while True:
        os.system("cls")
        banner()
        print()

        cf, acct_name, session_only = do_auth(reset=reset_auth)
        reset_auth = False

        ns = ensure_ns(cf)
        endpoints = load_endpoints(cf, ns)

        result = show_menu(cf, ns, endpoints, acct_name, session_only)

        if result == "switch":
            switch_account()
        else:
            break

    if session_only:
        print(dim("\n  Session ended — token not persisted.\n"))

if __name__ == "__main__":
    main()
