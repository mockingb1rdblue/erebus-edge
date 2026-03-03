#!/usr/bin/env python3
"""
deploy_term_worker.py -- Deploy the Terminal proxy Worker to Cloudflare Workers.

Worker at: https://term.mock1ng.workers.dev
Proxies HTTP + WebSocket traffic to ttyd (port 7681) on the home machine
via the Cloudflare Tunnel.

Run:  python deploy_term_worker.py
"""

import json, ssl, sys, urllib.request, urllib.error
from cf_creds import get_token
from config import get_config, require

CF_TOKEN  = get_token()
_cfg      = get_config()
ACCT      = require("account_id")
TUNNEL_ID = require("tunnel_id")
TERM_HOST = require("term_host")
SCRIPT    = "term"

# ── SSL context ───────────────────────────────────────────────────────────────
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode    = ssl.CERT_NONE

# ═════════════════════════════════════════════════════════════════════════════
#  Worker JavaScript
#
#  The Worker proxies all traffic (HTTP + WebSocket) to the CF Tunnel endpoint.
#  It overrides the Host header so the cloudflared ingress rule matches
#  term.mock1ng.workers.dev -> http://localhost:7681
# ═════════════════════════════════════════════════════════════════════════════
WORKER_CODE = f"""\
// Terminal proxy Worker
// Forwards all traffic to the CF Tunnel, which routes to ttyd (port 7681)
// on the home machine based on the Host header.

const TUNNEL   = '{TUNNEL_ID}.cfargotunnel.com';
const TERM_HOST = '{TERM_HOST}';

export default {{
  async fetch(request) {{
    const url  = new URL(request.url);
    const dest = new URL(url.pathname + url.search, `https://${{TUNNEL}}`);

    // Build forwarded headers, overriding Host so the tunnel routes correctly
    const headers = new Headers();
    for (const [k, v] of request.headers) {{
      // Skip CF-injected headers that the backend doesn't need
      if (/^(cf-|x-forwarded-|x-real-ip)/i.test(k)) continue;
      headers.set(k, v);
    }}
    headers.set('Host', TERM_HOST);

    try {{
      const resp = await fetch(dest.toString(), {{
        method:   request.method,
        headers,
        body:     ['GET','HEAD'].includes(request.method) ? undefined : request.body,
        redirect: 'manual',
      }});
      return resp;
    }} catch (e) {{
      return new Response(
        `<html><body style="font-family:monospace;background:#0d1117;color:#e6edf3;padding:2rem">
          <h2 style="color:#f85149">&#x26A1; Terminal unreachable</h2>
          <p>Could not reach the home machine via CF Tunnel.</p>
          <p style="color:#8b949e">Make sure cloudflared and ttyd are running on your home machine.</p>
          <p style="color:#8b949e">Error: ${{e.message}}</p>
          <p><a href="/" style="color:#58a6ff">&#x2190; Back to portal</a></p>
        </body></html>`,
        {{ status: 503, headers: {{ 'Content-Type': 'text/html' }} }}
      );
    }}
  }}
}};
"""

# ═════════════════════════════════════════════════════════════════════════════
#  Deploy helpers
# ═════════════════════════════════════════════════════════════════════════════
BOUNDARY = "----TermWorkerBoundary4p9z"

def mp(name, value, filename=None, ctype="text/plain"):
    cd = f'Content-Disposition: form-data; name="{name}"'
    if filename:
        cd += f'; filename="{filename}"'
    part  = f"--{BOUNDARY}\r\n"
    part += f"{cd}\r\nContent-Type: {ctype}\r\n\r\n"
    return part.encode() + value.encode() + b"\r\n"

def deploy():
    meta = json.dumps({
        "main_module":        "worker.js",
        "compatibility_date": "2024-09-23",
        "bindings":           [],
        "logpush":            False,
    })
    body  = mp("metadata", meta, "metadata.json", "application/json")
    body += mp("worker.js", WORKER_CODE, "worker.js", "application/javascript+module")
    body += f"--{BOUNDARY}--\r\n".encode()

    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE

    url = f"https://api.cloudflare.com/client/v4/accounts/{ACCT}/workers/scripts/{SCRIPT}"
    req = urllib.request.Request(url, data=body, method="PUT")
    req.add_header("Authorization", f"Bearer {CF_TOKEN}")
    req.add_header("Content-Type",  f"multipart/form-data; boundary={BOUNDARY}")

    print(f"Deploying Worker '{SCRIPT}' -> https://{SCRIPT}.mock1ng.workers.dev ...")
    try:
        with urllib.request.urlopen(req, context=ctx) as r:
            data = json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:    data = json.loads(e.read())
        except: data = {"success": False, "errors": [str(e)]}
    except Exception as e:
        data = {"success": False, "errors": [str(e)]}

    if not data.get("success"):
        print("[FAIL]", data.get("errors"))
        sys.exit(1)
    print("[OK] Worker deployed")

    # Enable workers.dev subdomain
    sub_url = f"https://api.cloudflare.com/client/v4/accounts/{ACCT}/workers/scripts/{SCRIPT}/subdomain"
    sub_req = urllib.request.Request(
        sub_url, data=json.dumps({"enabled": True}).encode(), method="POST")
    sub_req.add_header("Authorization", f"Bearer {CF_TOKEN}")
    sub_req.add_header("Content-Type",  "application/json")
    print("Enabling workers.dev subdomain ...")
    try:
        with urllib.request.urlopen(sub_req, context=ctx) as r:
            sd = json.loads(r.read())
            if sd.get("success"):
                print(f"[OK] https://{SCRIPT}.mock1ng.workers.dev is live")
            else:
                print("[FAIL]", sd.get("errors"))
    except urllib.error.HTTPError as e:
        body_txt = e.read().decode()
        if e.code == 409 or "already" in body_txt or "10054" in body_txt:
            print("[OK] subdomain already enabled")
        else:
            print("HTTP error:", e.code, body_txt)


def update_tunnel_ingress():
    """
    Update the CF Tunnel ingress config (remotely managed) to add the term route.
    cloudflared on the home machine will pick this up automatically.
    """
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode    = ssl.CERT_NONE

    # GET current config first
    url = f"https://api.cloudflare.com/client/v4/accounts/{ACCT}/cfd_tunnel/{TUNNEL_ID}/configurations"
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {CF_TOKEN}")
    try:
        with urllib.request.urlopen(req, context=ctx) as r:
            current = json.loads(r.read())
    except Exception as e:
        print(f"[WARN] Could not fetch tunnel config: {e}")
        current = {"result": {"config": {"ingress": []}}}

    existing_ingress = current.get("result", {}).get("config", {}).get("ingress", [])

    # Check if term ingress already exists
    has_term = any(
        r.get("hostname") == TERM_HOST
        for r in existing_ingress
        if isinstance(r, dict)
    )
    has_ssh = any(
        r.get("hostname") == "ssh.mock1ng.workers.dev"
        for r in existing_ingress
        if isinstance(r, dict)
    )

    if has_term:
        print("[OK] Tunnel ingress for 'term' already configured")
        return

    # Build new ingress list (keep existing, add term before catch-all)
    new_ingress = [r for r in existing_ingress if isinstance(r, dict) and r.get("hostname")]
    if not has_ssh:
        new_ingress.insert(0, {
            "hostname": "ssh.mock1ng.workers.dev",
            "service":  "ssh://localhost:22",
        })
    new_ingress.append({
        "hostname": TERM_HOST,
        "service":  "http://localhost:7681",
    })
    new_ingress.append({"service": "http_status:404"})  # catch-all

    payload = json.dumps({"config": {"ingress": new_ingress}}).encode()
    put_req = urllib.request.Request(url, data=payload, method="PUT")
    put_req.add_header("Authorization", f"Bearer {CF_TOKEN}")
    put_req.add_header("Content-Type", "application/json")

    print(f"Updating tunnel ingress to add {TERM_HOST} -> http://localhost:7681 ...")
    try:
        with urllib.request.urlopen(put_req, context=ctx) as r:
            result = json.loads(r.read())
        if result.get("success"):
            print("[OK] Tunnel ingress updated -- cloudflared will pick this up automatically")
        else:
            print("[FAIL]", result.get("errors"))
            print("      You may need to update the tunnel ingress manually.")
    except urllib.error.HTTPError as e:
        print(f"[WARN] Tunnel config update failed ({e.code}): {e.read().decode()}")
        print("       Update tunnel ingress manually if needed.")
    except Exception as e:
        print(f"[WARN] Tunnel config update failed: {e}")


if __name__ == "__main__":
    deploy()
    print()
    update_tunnel_ingress()
    subdomain = _cfg.get("subdomain","?")
    print()
    print(f"Terminal URL : https://term.{subdomain}.workers.dev")
    print()
    print("NOTE: ttyd must be running on the home machine (port 7681).")
    print("      Run home_setup.sh on the home machine if you haven't already.")
