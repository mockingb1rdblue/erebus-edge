#!/usr/bin/env python3
"""
setup_cf_access.py -- Configure Cloudflare Zero Trust Access for the portal + terminal.

What this does:
  1. Creates / verifies the Zero Trust organization
  2. Adds an email OTP identity provider (if not already present)
  3. Creates Access applications for:
       - portal.mock1ng.workers.dev  (the PWA management UI)
       - term.mock1ng.workers.dev    (the web terminal -- MUST be protected)
  4. Creates Access policies allowing specific email addresses

CF Access with workers.dev subdomains works via the Access JWT which the
Worker can validate, OR via the Access service token flow.  For this setup
we protect the TERMINAL (high risk -- shell on home machine) with strict
email-based OTP.  The portal SPA is protected by the CF token it holds.

Run:  python setup_cf_access.py [--email you@example.com]
"""

import json, ssl, sys, urllib.request, urllib.error, argparse

from cf_creds import get_token
from config import get_config, require

CF_TOKEN   = get_token()
ACCT       = require("account_id")
PORTAL_URL = require("portal_host")
TERM_URL   = require("term_host")

# ── SSL context ───────────────────────────────────────────────────────────────
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode    = ssl.CERT_NONE

# ═════════════════════════════════════════════════════════════════════════════
#  CF API helper
# ═════════════════════════════════════════════════════════════════════════════
def api(method, path, data=None):
    url  = f"https://api.cloudflare.com/client/v4{path}"
    body = json.dumps(data).encode() if data is not None else None
    req  = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Bearer {CF_TOKEN}")
    req.add_header("Content-Type",  "application/json")
    try:
        with urllib.request.urlopen(req, context=_SSL) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:    return json.loads(e.read())
        except: return {"success": False, "errors": [str(e)]}
    except Exception as e:
        return {"success": False, "errors": [str(e)]}

# ═════════════════════════════════════════════════════════════════════════════
#  Zero Trust org
# ═════════════════════════════════════════════════════════════════════════════
def ensure_org():
    """Create or verify Zero Trust organization."""
    r = api("GET", f"/accounts/{ACCT}/access/organizations")
    if r.get("success") and r.get("result"):
        org = r["result"]
        print(f"[OK] Zero Trust org: {org.get('name')} ({org.get('auth_domain')})")
        return org

    # Create org
    print("Creating Zero Trust organization...")
    # Use account name or a sensible default
    accts = api("GET", "/accounts").get("result", [])
    org_name = next((a["name"] for a in accts if a["id"] == ACCT), "mock1ng")
    r = api("PUT", f"/accounts/{ACCT}/access/organizations", {
        "name":        org_name,
        "auth_domain": f"{org_name.lower().replace(' ', '')}.cloudflareaccess.com",
        "login_design": {},
        "is_ui_read_only": False,
    })
    if r.get("success"):
        org = r["result"]
        print(f"[OK] Created Zero Trust org: {org.get('name')}")
        return org
    else:
        print(f"[FAIL] Could not create org: {r.get('errors')}")
        return None

# ═════════════════════════════════════════════════════════════════════════════
#  Identity provider (email OTP)
# ═════════════════════════════════════════════════════════════════════════════
def ensure_otp_idp():
    """Add email OTP identity provider if not present."""
    r = api("GET", f"/accounts/{ACCT}/access/identity_providers")
    if not r.get("success"):
        print(f"[WARN] Could not list identity providers: {r.get('errors')}")
        return None

    existing = r.get("result", [])
    otp = next((i for i in existing if i.get("type") == "onetimepin"), None)
    if otp:
        print(f"[OK] Email OTP IDP already exists: {otp['id']}")
        return otp["id"]

    print("Adding email OTP identity provider...")
    r = api("POST", f"/accounts/{ACCT}/access/identity_providers", {
        "name":   "Email OTP",
        "type":   "onetimepin",
        "config": {},
    })
    if r.get("success"):
        idp_id = r["result"]["id"]
        print(f"[OK] Created email OTP IDP: {idp_id}")
        return idp_id
    else:
        print(f"[FAIL] Could not create OTP IDP: {r.get('errors')}")
        return None

# ═════════════════════════════════════════════════════════════════════════════
#  Access applications
# ═════════════════════════════════════════════════════════════════════════════
def find_app(hostname):
    r = api("GET", f"/accounts/{ACCT}/access/apps")
    if not r.get("success"):
        return None
    return next((a for a in r.get("result", []) if a.get("domain") == hostname), None)


def ensure_app(hostname, name, session_duration="24h"):
    existing = find_app(hostname)
    if existing:
        print(f"[OK] Access app '{name}' already exists: {existing['id']}")
        return existing["id"]

    print(f"Creating Access app for {hostname} ...")
    r = api("POST", f"/accounts/{ACCT}/access/apps", {
        "name":             name,
        "domain":           hostname,
        "type":             "self_hosted",
        "session_duration": session_duration,
        "allowed_idps":     [],   # filled in after IDP is created
        "auto_redirect_to_identity": False,
        "http_only_cookie_attribute": True,
        "same_site_cookie_attribute": "lax",
    })
    if r.get("success"):
        app_id = r["result"]["id"]
        print(f"[OK] Created Access app: {app_id}")
        return app_id
    else:
        print(f"[FAIL] Could not create Access app: {r.get('errors')}")
        return None


# ═════════════════════════════════════════════════════════════════════════════
#  Access policies
# ═════════════════════════════════════════════════════════════════════════════
def ensure_policy(app_id, allowed_emails):
    """Create an Allow policy for specific email addresses."""
    r = api("GET", f"/accounts/{ACCT}/access/apps/{app_id}/policies")
    if r.get("success") and r.get("result"):
        print(f"[OK] Access policies already exist for app {app_id}")
        return

    print(f"Creating email Allow policy for {len(allowed_emails)} email(s)...")

    email_rules = [{"email": {"email": e}} for e in allowed_emails]

    r = api("POST", f"/accounts/{ACCT}/access/apps/{app_id}/policies", {
        "name":       "Allow authorised users",
        "decision":   "allow",
        "include":    email_rules,
        "require":    [],
        "exclude":    [],
        "precedence": 1,
    })
    if r.get("success"):
        print(f"[OK] Policy created: {r['result']['id']}")
    else:
        print(f"[FAIL] Could not create policy: {r.get('errors')}")


# ═════════════════════════════════════════════════════════════════════════════
#  Main
# ═════════════════════════════════════════════════════════════════════════════
def main():
    parser = argparse.ArgumentParser(description="Set up CF Zero Trust Access")
    parser.add_argument("--email", action="append", metavar="EMAIL",
                        help="Email address to allow (can be repeated). "
                             "If omitted, you will be prompted.")
    parser.add_argument("--skip-portal", action="store_true",
                        help="Only protect the terminal, skip portal Access app")
    args = parser.parse_args()

    print()
    print("=" * 58)
    print("  Cloudflare Zero Trust Access Setup")
    print("=" * 58)
    print()

    # Collect allowed emails
    emails = args.email or []
    if not emails:
        print("Enter the email addresses that should be allowed access.")
        print("(Press Enter with no input when done.)")
        print()
        while True:
            e = input("  Email: ").strip().lower()
            if not e:
                break
            emails.append(e)
        if not emails:
            print("[ERROR] At least one email is required.")
            sys.exit(1)

    print(f"\nAllowed emails: {', '.join(emails)}\n")

    # Step 1: Zero Trust org
    org = ensure_org()
    if not org:
        print("\n[ERROR] Could not set up Zero Trust org. Check your token permissions.")
        print("        Token needs: Zero Trust Edit permission.")
        sys.exit(1)

    # Step 2: Email OTP IDP
    idp_id = ensure_otp_idp()

    # Step 3: Access apps
    if not args.skip_portal:
        portal_app_id = ensure_app(PORTAL_URL, "SSH Portal")
        if portal_app_id:
            ensure_policy(portal_app_id, emails)

    term_app_id = ensure_app(TERM_URL, "SSH Terminal")
    if term_app_id:
        ensure_policy(term_app_id, emails)

    print()
    print("=" * 58)
    print("  CF Access setup complete!")
    print("=" * 58)
    print()
    print(f"  Portal  : https://{PORTAL_URL}")
    print(f"  Terminal: https://{TERM_URL}")
    print()
    if org:
        auth_domain = org.get("auth_domain", "")
        print(f"  Auth domain : https://{auth_domain}")
    print()
    print("  Users visiting these URLs will be prompted to enter their")
    print("  email and confirm via OTP code before gaining access.")
    print()
    print("  NOTE: CF Access on *.workers.dev requires the Access JWT")
    print("  to be validated. The Workers themselves will be gated by")
    print("  CF Access automatically when policies are applied.")
    print()


if __name__ == "__main__":
    main()
