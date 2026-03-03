"""
config.py -- Shared config loader for all portal scripts.

Config is populated by running:  python bootstrap.py

There are NO hardcoded defaults. If portal_config.json doesn't exist,
scripts will exit with a clear message telling the user to run bootstrap.py.

Shape of keys/portal_config.json (written by bootstrap.py):
{
    "account_id":   "<your CF account ID>",
    "subdomain":    "<your workers.dev subdomain>",
    "tunnel_id":    "<your tunnel ID>",
    "kv_ns_id":     "<your KV namespace ID>",
    "ssh_host":     "ssh.<subdomain>.workers.dev",
    "portal_host":  "portal.<subdomain>.workers.dev",
    "term_host":    "term.<subdomain>.workers.dev",
    "ts_relay_url": "https://ts-relay.<subdomain>.workers.dev"
}
"""

import json, sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
CFG_FILE   = SCRIPT_DIR / "keys" / "portal_config.json"


def get_config() -> dict:
    """Load config from file. Returns empty dict if file doesn't exist."""
    if CFG_FILE.exists():
        try:
            cfg = json.loads(CFG_FILE.read_text())
            # Derive host names from subdomain if scripts wrote them without explicit hosts
            sub = cfg.get("subdomain", "")
            if sub:
                cfg.setdefault("ssh_host",     f"ssh.{sub}.workers.dev")
                cfg.setdefault("portal_host",  f"portal.{sub}.workers.dev")
                cfg.setdefault("term_host",    f"term.{sub}.workers.dev")
                cfg.setdefault("ts_relay_url", f"https://ts-relay.{sub}.workers.dev")
            return cfg
        except Exception as e:
            print(f"[ERROR] Could not read {CFG_FILE}: {e}", file=sys.stderr)
    return {}


def save_config(updates: dict):
    """Merge updates into the saved config file."""
    existing = {}
    if CFG_FILE.exists():
        try:
            existing = json.loads(CFG_FILE.read_text())
        except Exception:
            pass
    existing.update(updates)
    CFG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CFG_FILE.write_text(json.dumps(existing, indent=2))


def require(key: str) -> str:
    """Get a required config value. Exits with a clear error if missing."""
    val = get_config().get(key)
    if not val:
        print(f"\n[ERROR] Config key '{key}' not found.", file=sys.stderr)
        print(f"        No config file at: {CFG_FILE}", file=sys.stderr)
        print(f"        Run:  python bootstrap.py", file=sys.stderr)
        print(f"        This sets up your own Cloudflare account — takes ~2 minutes.\n",
              file=sys.stderr)
        sys.exit(1)
    return val
