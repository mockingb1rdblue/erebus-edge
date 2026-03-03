#!/usr/bin/env python3
"""
deploy_ts_relay_worker.py -- Deploy the ts-relay Cloudflare Worker.

The relay Worker proxies Tailscale traffic through workers.dev, bypassing
corporate networks that block Tailscale directly.

  tsnet binary → ts-relay.SUB.workers.dev → controlplane.tailscale.com
                                           ↘ DERP relay (WebSocket)

*.workers.dev is in no_proxy on most corporate machines, so traffic goes
direct to Cloudflare without SSL inspection or proxy auth.

Routes handled by the Worker:
  /derpmap/default  →  custom DERP map (forces WebSocket DERP, points to this relay)
  /derp             →  WebSocket proxy to Tailscale DERP server
  /login*, /a/*     →  login.tailscale.com (auth flow)
  everything else   →  controlplane.tailscale.com
"""

import json, sys, urllib.request, urllib.error, ssl
from pathlib import Path

from config import require, get_config, save_config

_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode    = ssl.CERT_NONE


# ─────────────────────────────────────────────────────────────────────────────
#  CF API helper
# ─────────────────────────────────────────────────────────────────────────────
def _api(method, path, token, data=None, raw=False):
    url  = f"https://api.cloudflare.com/client/v4{path}"
    body = json.dumps(data).encode() if data is not None else None
    req  = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Bearer {token}")
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


# ─────────────────────────────────────────────────────────────────────────────
#  Worker JavaScript
# ─────────────────────────────────────────────────────────────────────────────
def _worker_js(relay_host: str) -> str:
    """
    Generate the ts-relay Worker JS.
    relay_host e.g. 'ts-relay.alice.workers.dev'
    """
    return f"""\
// ts-relay Worker — proxies Tailscale through workers.dev
// *.workers.dev is in no_proxy on most corporate machines → bypasses SSL inspection
//
// Routing:
//   /derpmap/default  → custom DERP map (ForceWebsocket, points to this relay)
//   /derp             → WebSocket proxy to Tailscale DERP server
//   /login*, /a/*     → login.tailscale.com  (Tailscale auth UI)
//   everything else   → controlplane.tailscale.com

const RELAY_HOST   = {json.dumps(relay_host)};
const CONTROL_HOST = 'controlplane.tailscale.com';
const LOGIN_HOST   = 'login.tailscale.com';
const DERP_SERVERS = ['derp1.tailscale.com', 'derp2.tailscale.com', 'derp3.tailscale.com'];

export default {{
  async fetch(request) {{
    const url  = new URL(request.url);
    const path = url.pathname;

    // ── DERP map interception ──────────────────────────────────────────────
    if (path === '/derpmap/default') return derpMap();

    // ── DERP WebSocket relay ───────────────────────────────────────────────
    if (path === '/derp' || path.startsWith('/derp?')) {{
      const upgrade = (request.headers.get('Upgrade') || '').toLowerCase();
      if (upgrade !== 'websocket')
        return new Response('DERP relay: WebSocket upgrade required', {{ status: 426 }});
      return proxyDerp(request);
    }}

    // ── Auth pages → login.tailscale.com ──────────────────────────────────
    if (path.startsWith('/login') || path.startsWith('/a/') ||
        path.startsWith('/oauth') || path.startsWith('/oidc'))
      return proxyHTTP(request, LOGIN_HOST);

    // ── Control plane → controlplane.tailscale.com ────────────────────────
    return proxyHTTP(request, CONTROL_HOST);
  }},
}};

// ── DERP map ─────────────────────────────────────────────────────────────────
function derpMap() {{
  return new Response(JSON.stringify({{
    Version: 2,
    Regions: {{
      900: {{
        RegionID:   900,
        RegionCode: 'cf-relay',
        RegionName: 'Cloudflare Relay',
        Nodes: [{{
          Name:           '900a',
          RegionID:       900,
          HostName:       RELAY_HOST,
          DERPPort:       443,
          STUNPort:       -1,
          ForceWebsocket: true,
        }}],
      }},
    }},
  }}), {{ headers: {{ 'Content-Type': 'application/json' }} }});
}}

// ── HTTP reverse proxy ────────────────────────────────────────────────────────
async function proxyHTTP(request, destHost) {{
  const url  = new URL(request.url);
  const dest = `https://${{destHost}}${{url.pathname}}${{url.search}}`;
  const headers = new Headers();
  for (const [k, v] of request.headers)
    if (!/^(cf-|x-forwarded-|x-real-ip)/i.test(k)) headers.set(k, v);
  headers.set('Host', destHost);
  try {{
    return await fetch(dest, {{
      method:   request.method,
      headers,
      body:     ['GET', 'HEAD'].includes(request.method) ? undefined : request.body,
      redirect: 'follow',
    }});
  }} catch (e) {{
    return new Response(`Relay error: ${{e.message}}`, {{ status: 502 }});
  }}
}}

// ── DERP WebSocket proxy ──────────────────────────────────────────────────────
// tsnet sets ForceWebsocket in our custom DERP map, so all DERP traffic
// arrives here as WebSocket upgrades. We proxy to a real Tailscale DERP server.
async function proxyDerp(request) {{
  const pair = new WebSocketPair();
  const [client, server] = Object.values(pair);

  // Try each DERP server in order
  let upstream = null;
  for (const host of DERP_SERVERS) {{
    try {{
      const resp = await fetch(`https://${{host}}/derp`, {{
        headers: {{ Upgrade: 'websocket', Connection: 'Upgrade' }},
        method:  'GET',
      }});
      if (resp.webSocket) {{ upstream = resp.webSocket; break; }}
    }} catch (_) {{}}
  }}

  if (!upstream)
    return new Response('Could not reach Tailscale DERP server', {{ status: 502 }});

  server.accept();
  upstream.accept();

  server.addEventListener('message',  e => {{ try {{ upstream.send(e.data); }} catch (_) {{}} }});
  upstream.addEventListener('message', e => {{ try {{ server.send(e.data);   }} catch (_) {{}} }});
  server.addEventListener('close',    e => {{ try {{ upstream.close(e.code, e.reason); }} catch (_) {{}} }});
  upstream.addEventListener('close',  e => {{ try {{ server.close(e.code, e.reason);  }} catch (_) {{}} }});
  server.addEventListener('error',  () => {{ try {{ upstream.close(); }} catch (_) {{}} }});
  upstream.addEventListener('error', () => {{ try {{ server.close();  }} catch (_) {{}} }});

  return new Response(null, {{ status: 101, webSocket: client }});
}}
"""


# ─────────────────────────────────────────────────────────────────────────────
#  Deploy
# ─────────────────────────────────────────────────────────────────────────────
def deploy(acct_id: str, subdomain: str, token: str) -> bool:
    """Deploy ts-relay Worker and enable workers.dev subdomain. Returns True on success."""
    relay_host   = f"ts-relay.{subdomain}.workers.dev"
    worker_code  = _worker_js(relay_host)
    script_name  = "ts-relay"
    boundary     = "----TsRelayBoundary"

    meta = json.dumps({
        "main_module":        "worker.js",
        "compatibility_date": "2024-09-23",
        "bindings":           [],
        "logpush":            False,
    })

    def _part(name, val, fn=None, ct="text/plain"):
        cd = f'Content-Disposition: form-data; name="{name}"'
        if fn: cd += f'; filename="{fn}"'
        return (f"--{boundary}\r\n{cd}\r\nContent-Type: {ct}\r\n\r\n".encode()
                + val.encode() + b"\r\n")

    body  = _part("metadata", meta, "metadata.json", "application/json")
    body += _part("worker.js", worker_code, "worker.js", "application/javascript+module")
    body += f"--{boundary}--\r\n".encode()

    url = (f"https://api.cloudflare.com/client/v4"
           f"/accounts/{acct_id}/workers/scripts/{script_name}")
    req = urllib.request.Request(url, data=body, method="PUT")
    req.add_header("Authorization", f"Bearer {token}")
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
        print(f"[ERROR] Worker deploy failed: {result.get('errors')}", file=sys.stderr)
        return False

    # Enable workers.dev subdomain
    sub_url = (f"https://api.cloudflare.com/client/v4"
               f"/accounts/{acct_id}/workers/scripts/{script_name}/subdomain")
    sub_req = urllib.request.Request(
        sub_url, data=json.dumps({"enabled": True}).encode(), method="POST")
    sub_req.add_header("Authorization", f"Bearer {token}")
    sub_req.add_header("Content-Type",  "application/json")
    try:
        with urllib.request.urlopen(sub_req, context=_SSL) as r:
            json.loads(r.read())
    except urllib.error.HTTPError as e:
        body_txt = e.read().decode()
        if e.code not in (409,) and "already" not in body_txt and "10054" not in body_txt:
            print(f"[WARN] Could not enable workers.dev for '{script_name}': {e.code}",
                  file=sys.stderr)
    except Exception:
        pass

    return True


# ─────────────────────────────────────────────────────────────────────────────
#  Standalone
# ─────────────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    from cf_creds import get_token

    ACCT      = require("account_id")
    SUBDOMAIN = require("subdomain")
    TOKEN     = get_token()

    relay_host = f"ts-relay.{SUBDOMAIN}.workers.dev"
    print(f"Deploying ts-relay Worker -> https://{relay_host} ...", end=" ", flush=True)
    if deploy(ACCT, SUBDOMAIN, TOKEN):
        save_config({"ts_relay_url": f"https://{relay_host}"})
        print("OK")
        print(f"[ok]  https://{relay_host}")
        print("[ok]  ts_relay_url saved to config")
    else:
        print("FAILED")
        sys.exit(1)
