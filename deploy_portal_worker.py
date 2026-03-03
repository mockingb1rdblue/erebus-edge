#!/usr/bin/env python3
"""
deploy_portal_worker.py -- Deploy the SSH Portal PWA to Cloudflare Workers.

Portal at: https://portal.mock1ng.workers.dev
DYNAMIC: works for ANY Cloudflare account -- each user provides their own CF
API token. No account IDs are hardcoded in the Worker or SPA.

Run:  python deploy_portal_worker.py
"""

import json, ssl, sys, urllib.request, urllib.error
from cf_creds import get_token
from config import get_config, require

CF_TOKEN = get_token()
_cfg     = get_config()
ACCT     = require("account_id")
SCRIPT   = "portal"

# ── SSL context (bypass corporate revocation check) ───────────────────────────
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode    = ssl.CERT_NONE

# ═════════════════════════════════════════════════════════════════════════════
#  SPA assets (embedded in the Worker)
# ═════════════════════════════════════════════════════════════════════════════

SW_JS = """\
const CACHE = 'ssh-portal-v1';
self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(['/'])));
  self.skipWaiting();
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks =>
    Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))
  ));
  self.clients.claim();
});
self.addEventListener('fetch', e => {
  if (e.request.url.includes('/cf-api/')) return;
  e.respondWith(fetch(e.request).catch(() => caches.match(e.request)));
});
"""

MANIFEST = json.dumps({
    "name": "SSH Portal",
    "short_name": "Portal",
    "description": "Connect to your machines via Cloudflare Tunnel",
    "start_url": "/",
    "display": "standalone",
    "background_color": "#0d1117",
    "theme_color": "#0d1117",
    "icons": [{"src": "/icon.svg", "sizes": "any", "type": "image/svg+xml"}],
})

ICON_SVG = """\
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
  <rect width="100" height="100" rx="16" fill="#0d1117"/>
  <text x="12" y="78" font-size="70" font-family="monospace">&#x26A1;</text>
</svg>"""

# ── SPA HTML (pure vanilla JS, no build step, no dependencies) ────────────────
SPA_HTML = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>SSH Portal</title>
<link rel="manifest" href="/manifest.json">
<meta name="theme-color" content="#0d1117">
<meta name="apple-mobile-web-app-capable" content="yes">
<style>
:root{--bg:#0d1117;--sf:#161b22;--bd:#30363d;--tx:#e6edf3;--dm:#8b949e;--ac:#58a6ff;--gn:#3fb950;--ye:#d29922;--rd:#f85149}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--tx);font-family:'SF Mono','Fira Code',Consolas,monospace;min-height:100vh;font-size:14px}
a{color:var(--ac)}
.view{display:none;min-height:100vh;flex-direction:column}
.view.active{display:flex}

/* Auth */
#v-auth{align-items:center;justify-content:center;padding:2rem 1rem;gap:1rem}
.brand{font-size:1.5rem;font-weight:700;color:var(--ac);text-align:center}
.brand span{color:var(--tx)}
.card{background:var(--sf);border:1px solid var(--bd);border-radius:8px;padding:1.5rem;width:100%;max-width:420px}
.card h2{font-size:.9rem;color:var(--dm);margin-bottom:1.2rem;font-weight:400}
.field{margin-bottom:.9rem}
.field label{display:block;margin-bottom:.35rem;color:var(--dm);font-size:.82rem}
.field input[type=password],.field input[type=text],.field input[type=number],.field select{width:100%;padding:.55rem .75rem;background:var(--bg);border:1px solid var(--bd);border-radius:4px;color:var(--tx);font-family:inherit;font-size:.9rem}
.field input:focus,.field select:focus{outline:none;border-color:var(--ac)}
.field.check{display:flex;align-items:center;gap:.6rem;margin-bottom:.9rem}
.field.check input{width:auto}
.field textarea{width:100%;padding:.55rem .75rem;background:var(--bg);border:1px solid var(--bd);border-radius:4px;color:var(--tx);font-family:inherit;font-size:.82rem;resize:vertical;min-height:90px}
.field textarea:focus{outline:none;border-color:var(--ac)}
.btn{display:inline-flex;align-items:center;gap:.4rem;padding:.5rem 1rem;border:none;border-radius:4px;cursor:pointer;font-family:inherit;font-size:.88rem;font-weight:500;transition:opacity .15s;text-decoration:none}
.btn:hover{opacity:.82}
.btn-primary{background:var(--ac);color:#0d1117}
.btn-ghost{background:transparent;border:1px solid var(--bd);color:var(--tx)}
.btn-danger{background:var(--rd);color:#fff}
.btn-sm{padding:.3rem .65rem;font-size:.8rem}
.help{color:var(--dm);font-size:.78rem;margin-top:.9rem;line-height:1.6}
.err{color:var(--rd);font-size:.82rem;margin-top:.5rem;display:none}

/* Topbar */
.topbar{background:var(--sf);border-bottom:1px solid var(--bd);padding:.65rem 1.1rem;display:flex;align-items:center;gap:.8rem;position:sticky;top:0;z-index:10}
.topbar .brand{font-size:.95rem;margin:0;flex-shrink:0}
.acct{color:var(--dm);font-size:.78rem;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}

/* Endpoints */
#v-home{padding-bottom:5rem}
.section{padding:.9rem 1.1rem}
.section h3{font-size:.75rem;color:var(--dm);text-transform:uppercase;letter-spacing:.06em;margin-bottom:.7rem}
.ep-card{background:var(--sf);border:1px solid var(--bd);border-radius:6px;margin-bottom:.55rem}
.ep-head{display:flex;align-items:center;gap:.75rem;padding:.75rem .9rem}
.ep-dot{width:9px;height:9px;border-radius:50%;flex-shrink:0}
.dot-g{background:var(--gn)}.dot-y{background:var(--ye)}.dot-r{background:var(--rd)}
.ep-info{flex:1;min-width:0}
.ep-name{font-weight:600;font-size:.92rem}
.ep-sub{color:var(--dm);font-size:.78rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.ep-acts{display:flex;gap:.35rem;flex-shrink:0}
.ep-foot{padding:.15rem .9rem .6rem;font-size:.76rem;color:var(--dm)}
.ep-foot .ok{color:var(--gn)}

/* FAB */
.fab{position:fixed;bottom:1.4rem;right:1.4rem;width:50px;height:50px;border-radius:50%;background:var(--ac);color:#0d1117;font-size:1.5rem;border:none;cursor:pointer;display:flex;align-items:center;justify-content:center;box-shadow:0 4px 14px rgba(0,0,0,.5)}
.fab:hover{opacity:.88}

/* Settings */
#v-settings,#v-add{padding-bottom:4rem}
.s-body{padding:.9rem 1.1rem;flex:1;overflow-y:auto}
.s-body h3{font-size:.75rem;color:var(--dm);text-transform:uppercase;letter-spacing:.06em;margin-bottom:.7rem;margin-top:1.3rem}
.s-body h3:first-child{margin-top:0}
.radio-grp{display:flex;flex-direction:column;gap:.35rem}
.radio-opt{display:flex;align-items:center;gap:.6rem;padding:.45rem .75rem;background:var(--bg);border:1px solid var(--bd);border-radius:4px;cursor:pointer;font-size:.88rem}
.radio-opt input{margin:0;cursor:pointer}
.radio-opt.sel{border-color:var(--ac)}
.actbar{padding:.9rem 1.1rem;border-top:1px solid var(--bd);display:flex;gap:.5rem;flex-wrap:wrap;background:var(--sf)}

/* Loading */
.spinner{display:inline-block;width:18px;height:18px;border:2px solid var(--bd);border-top-color:var(--ac);border-radius:50%;animation:spin .55s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.overlay{position:fixed;inset:0;background:rgba(13,17,23,.88);display:none;align-items:center;justify-content:center;z-index:100}
.overlay.on{display:flex}

/* Toast */
.toast{position:fixed;bottom:4.5rem;left:50%;transform:translateX(-50%);background:var(--sf);border:1px solid var(--bd);color:var(--tx);padding:.55rem 1.1rem;border-radius:6px;font-size:.82rem;opacity:0;transition:opacity .2s;pointer-events:none;z-index:200;white-space:nowrap}
.toast.on{opacity:1}

/* Acct picker */
.acct-list{display:flex;flex-direction:column;gap:.4rem;margin-top:.5rem}
.acct-opt{padding:.5rem .75rem;background:var(--bg);border:1px solid var(--bd);border-radius:4px;cursor:pointer;font-size:.88rem;transition:border-color .15s}
.acct-opt:hover{border-color:var(--ac)}
</style>
</head>
<body>

<!-- ── Auth ──────────────────────────────────────────────── -->
<div id="v-auth" class="view active">
  <div class="brand">&#x26A1; <span>SSH Portal</span></div>
  <div class="card">
    <h2>Cloudflare API Token</h2>
    <div class="field">
      <label for="tok">Token</label>
      <input type="password" id="tok" placeholder="xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" autocomplete="off" spellcheck="false">
    </div>
    <div class="field check">
      <input type="checkbox" id="remember" checked>
      <label for="remember">Remember token (localStorage)</label>
    </div>
    <button class="btn btn-primary" id="auth-btn" style="width:100%;justify-content:center">Connect</button>
    <div class="err" id="auth-err"></div>
    <div class="help">
      Get a token: CF Dashboard &#x2192; My Profile &#x2192; API Tokens<br>
      Permissions needed:<br>
      &nbsp;&nbsp;&#x2022; Workers KV Storage Edit<br>
      &nbsp;&nbsp;&#x2022; Cloudflare Tunnel Edit<br>
      &nbsp;&nbsp;&#x2022; Workers Script Edit<br>
      &nbsp;&nbsp;&#x2022; Zero Trust Edit&nbsp;<em>(optional)</em>
    </div>
  </div>
</div>

<!-- ── Account picker (shown when multiple accounts) ────── -->
<div id="v-accts" class="view">
  <div class="topbar">
    <div class="brand">&#x26A1; Portal</div>
    <div class="acct">Select account</div>
    <button class="btn btn-ghost btn-sm" id="acct-logout">Logout</button>
  </div>
  <div class="s-body">
    <h3>Your Cloudflare Accounts</h3>
    <div class="acct-list" id="acct-list"></div>
  </div>
</div>

<!-- ── Home ──────────────────────────────────────────────── -->
<div id="v-home" class="view">
  <div class="topbar">
    <div class="brand">&#x26A1; Portal</div>
    <div class="acct" id="acct-label"></div>
    <button class="btn btn-ghost btn-sm" id="logout-btn">Logout</button>
  </div>
  <div class="section">
    <h3>Endpoints</h3>
    <div id="ep-list"></div>
  </div>
  <button class="fab" id="add-btn" title="Add endpoint">+</button>
</div>

<!-- ── Settings ───────────────────────────────────────────── -->
<div id="v-settings" class="view">
  <div class="topbar">
    <button class="btn btn-ghost btn-sm" id="back-btn">&#x2190; Back</button>
    <div class="brand" style="flex:1;text-align:center" id="s-title">Settings</div>
    <div style="width:70px"></div>
  </div>
  <div class="s-body" id="s-body"></div>
  <div class="actbar" id="s-acts"></div>
</div>

<!-- ── Add Endpoint ───────────────────────────────────────── -->
<div id="v-add" class="view">
  <div class="topbar">
    <button class="btn btn-ghost btn-sm" id="add-back">&#x2190; Back</button>
    <div class="brand" style="flex:1;text-align:center">Add Endpoint</div>
    <div style="width:70px"></div>
  </div>
  <div class="s-body">
    <h3>Details</h3>
    <div class="field"><label>Name</label><input type="text" id="a-name" placeholder="home"></div>
    <div class="field">
      <label>Terminal URL <span style="color:var(--dm)">(ttyd via CF Tunnel)</span></label>
      <input type="text" id="a-term" placeholder="https://term.youraccount.workers.dev">
    </div>
    <div class="field">
      <label>CF SSH Hostname <span style="color:var(--dm)">(for SSH ProxyCommand via portal.py CLI)</span></label>
      <input type="text" id="a-host" placeholder="ssh.youraccount.workers.dev">
    </div>
    <div class="field"><label>Username</label><input type="text" id="a-user" placeholder="john"></div>
    <div class="field"><label>SSH Port</label><input type="number" id="a-port" value="22" min="1" max="65535"></div>
  </div>
  <div class="actbar">
    <button class="btn btn-primary" id="a-save">Save</button>
    <button class="btn btn-ghost" id="a-cancel">Cancel</button>
  </div>
</div>

<div class="overlay" id="overlay"><div class="spinner"></div></div>
<div class="toast" id="toast"></div>

<script>
// ── State ──────────────────────────────────────────────────────────────
const S = { token:null, accountId:null, accountName:'', kvNsId:null, endpoints:{}, persist:true };

// ── Storage ────────────────────────────────────────────────────────────
const store = {
  get: k => localStorage.getItem(k) ?? sessionStorage.getItem(k),
  set(k,v){ S.persist ? localStorage.setItem(k,v) : sessionStorage.setItem(k,v) },
  del(k){ localStorage.removeItem(k); sessionStorage.removeItem(k) },
};

// ── UI helpers ─────────────────────────────────────────────────────────
function showView(id){
  document.querySelectorAll('.view').forEach(v=>v.classList.remove('active'));
  document.getElementById(id).classList.add('active');
}
function loading(on){ document.getElementById('overlay').classList.toggle('on',on) }
let _tt;
function toast(msg,ms=2600){
  const el=document.getElementById('toast');
  el.textContent=msg; el.classList.add('on');
  clearTimeout(_tt); _tt=setTimeout(()=>el.classList.remove('on'),ms);
}
function esc(s){ return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;') }
function showErr(id,msg){ const el=document.getElementById(id); el.textContent=msg; el.style.display=msg?'block':'none' }

// ── CF API via Worker proxy ────────────────────────────────────────────
async function cfApi(method, path, body){
  const opts={ method, headers:{ 'x-cf-token':S.token, 'Content-Type':'application/json' } };
  if(body!==undefined && method!=='GET') opts.body=JSON.stringify(body);
  const r=await fetch('/cf-api'+path, opts);
  return r.json();
}
async function kvGet(key){
  const r=await fetch(
    `/cf-api/accounts/${S.accountId}/storage/kv/namespaces/${S.kvNsId}/values/${encodeURIComponent(key)}`,
    {headers:{'x-cf-token':S.token}}
  );
  if(!r.ok) return null;
  return r.text();
}
async function kvPut(key,value){
  await fetch(
    `/cf-api/accounts/${S.accountId}/storage/kv/namespaces/${S.kvNsId}/values/${encodeURIComponent(key)}`,
    {method:'PUT',headers:{'x-cf-token':S.token,'Content-Type':'text/plain'},body:value}
  );
}
async function kvDel(key){
  await fetch(
    `/cf-api/accounts/${S.accountId}/storage/kv/namespaces/${S.kvNsId}/values/${encodeURIComponent(key)}`,
    {method:'DELETE',headers:{'x-cf-token':S.token}}
  );
}

// ── Auth ───────────────────────────────────────────────────────────────
async function doAuth(token, persist){
  S.token=token; S.persist=persist;
  showErr('auth-err','');

  const data=await cfApi('GET','/accounts');
  if(!data.success||!data.result?.length)
    throw new Error(data.errors?.[0]?.message||'Invalid token or no accounts found');

  const accts=data.result;

  if(accts.length===1){
    await selectAccount(accts[0]);
  } else {
    // Show account picker
    const stored=store.get('portal_account_id');
    const found=accts.find(a=>a.id===stored);
    if(found){ await selectAccount(found); return; }
    // Render picker
    document.getElementById('acct-list').innerHTML=accts.map((a,i)=>
      `<div class="acct-opt" data-i="${i}">${esc(a.name)} <span style="color:var(--dm);font-size:.78rem">${a.id.slice(0,8)}...</span></div>`
    ).join('');
    showView('v-accts');
    // click handled globally
    window._authAccts=accts;
  }
}

async function selectAccount(acct){
  S.accountId=acct.id; S.accountName=acct.name;

  // Find/create KV namespace
  const storedNs=store.get('portal_kv_ns_id');
  if(storedNs && store.get('portal_account_id')===acct.id){
    S.kvNsId=storedNs;
  } else {
    loading(true);
    const nsData=await cfApi('GET',`/accounts/${acct.id}/storage/kv/namespaces`);
    const ns=nsData.result?.find(n=>n.title==='ssh-portal');
    if(ns){
      S.kvNsId=ns.id;
    } else {
      const cr=await cfApi('POST',`/accounts/${acct.id}/storage/kv/namespaces`,{title:'ssh-portal'});
      if(!cr.success) throw new Error('Could not create KV namespace');
      S.kvNsId=cr.result.id;
    }
    loading(false);
  }

  // Load endpoints
  const raw=await kvGet('endpoints');
  S.endpoints=raw?JSON.parse(raw):{};

  // Persist
  store.set('portal_token',S.token);
  store.set('portal_account_id',S.accountId);
  store.set('portal_kv_ns_id',S.kvNsId);

  showHome();
}

function doLogout(){
  store.del('portal_token');
  store.del('portal_account_id');
  store.del('portal_kv_ns_id');
  S.token=null; S.accountId=null; S.kvNsId=null; S.endpoints={};
  showView('v-auth');
}

// ── Home ───────────────────────────────────────────────────────────────
function isGolden(ep){ return ep.username&&(ep.has_key||ep.has_password) }
function dot(ep){ return isGolden(ep)?'dot-g':ep.username?'dot-y':'dot-r' }
function foot(ep){
  if(isGolden(ep)){
    const last=ep.last_connected?ep.last_connected.slice(0,10):'never';
    return `<span class="ok">&#x2713; ready</span> &middot; last: ${last} &middot; auth: ${ep.has_key?'key':'password'}`;
  }
  return ep.username?'&#x25CB; no auth saved':'&#x25CB; not configured';
}
function showHome(){
  document.getElementById('acct-label').textContent=S.accountName;
  renderEps();
  showView('v-home');
}
function renderEps(){
  const list=document.getElementById('ep-list');
  const names=Object.keys(S.endpoints);
  if(!names.length){
    list.innerHTML='<div style="color:var(--dm);padding:.4rem 0">No endpoints yet. Tap + to add one.</div>';
    return;
  }
  list.innerHTML=names.map(name=>{
    const ep=S.endpoints[name];
    const canConnect=ep.term_url;
    return `<div class="ep-card">
<div class="ep-head">
  <div class="ep-dot ${dot(ep)}"></div>
  <div class="ep-info">
    <div class="ep-name">${esc(name)}</div>
    <div class="ep-sub">${esc(ep.username||'')}${ep.username?'@':''}${esc(ep.term_url||ep.cf_host||'not configured')}</div>
  </div>
  <div class="ep-acts">
    ${canConnect?`<button class="btn btn-primary btn-sm" onclick="connect('${esc(name)}')">Connect</button>`:''}
    <button class="btn btn-ghost btn-sm" onclick="openSettings('${esc(name)}')">&#x2699;</button>
  </div>
</div>
<div class="ep-foot">${foot(ep)}</div>
</div>`;
  }).join('');
}

function connect(name){
  const ep=S.endpoints[name];
  if(!ep.term_url){ toast('No terminal URL configured'); return; }
  window.open(ep.term_url,'_blank','noopener');
  ep.last_connected=new Date().toISOString().slice(0,19)+'Z';
  ep.connect_count=(ep.connect_count||0)+1;
  S.endpoints[name]=ep;
  kvPut('endpoints',JSON.stringify(S.endpoints)).catch(()=>{});
  renderEps();
}

// ── Settings ───────────────────────────────────────────────────────────
let editName=null;
function openSettings(name){
  editName=name;
  const ep={...S.endpoints[name]};
  document.getElementById('s-title').textContent=name;

  const keyBadge=ep.has_key?`<span style="color:var(--gn)">&#x2713; stored</span>`:`<span style="color:var(--dm)">none</span>`;
  const pwBadge=ep.has_password?`<span style="color:var(--gn)">&#x2713; stored</span>`:`<span style="color:var(--dm)">none</span>`;

  document.getElementById('s-body').innerHTML=`
<h3>Connection</h3>
<div class="field"><label>Terminal URL (opens on Connect)</label>
  <input type="text" id="s-term" value="${esc(ep.term_url||'')}" placeholder="https://term.youraccount.workers.dev"></div>
<div class="field"><label>CF SSH Hostname</label>
  <input type="text" id="s-host" value="${esc(ep.cf_host||'')}" placeholder="ssh.youraccount.workers.dev"></div>
<div class="field"><label>Username</label>
  <input type="text" id="s-user" value="${esc(ep.username||'')}"></div>
<div class="field"><label>SSH Port</label>
  <input type="number" id="s-port" value="${ep.port||22}" min="1" max="65535"></div>
<h3>Authentication (stored in CF KV, used by portal.py CLI)</h3>
<div class="radio-grp">
  <label class="radio-opt${!ep.has_key&&!ep.has_password?' sel':''}">
    <input type="radio" name="auth" value="none" ${!ep.has_key&&!ep.has_password?'checked':''}> No saved auth
  </label>
  <label class="radio-opt${ep.has_key?' sel':''}">
    <input type="radio" name="auth" value="key" ${ep.has_key?'checked':''}> SSH Key (CF KV) ${keyBadge}
  </label>
  <label class="radio-opt${ep.has_password?' sel':''}">
    <input type="radio" name="auth" value="pass" ${ep.has_password?'checked':''}> Password (CF KV) ${pwBadge}
  </label>
</div>
<div id="auth-detail" style="margin-top:.9rem"></div>
`;

  // Radio change
  document.querySelectorAll('input[name=auth]').forEach(r=>{
    r.addEventListener('change', ()=>{
      document.querySelectorAll('.radio-opt').forEach(l=>l.classList.remove('sel'));
      r.closest('label').classList.add('sel');
      renderAuthDetail();
    });
  });
  renderAuthDetail();

  document.getElementById('s-acts').innerHTML=`
<button class="btn btn-primary" id="s-save">Save</button>
<button class="btn btn-danger btn-sm" id="s-del">Delete</button>
`;
  document.getElementById('s-save').onclick=saveSettings;
  document.getElementById('s-del').onclick=deleteEndpoint;
  showView('v-settings');
}

function renderAuthDetail(){
  const val=document.querySelector('input[name=auth]:checked')?.value;
  const detail=document.getElementById('auth-detail');
  if(!detail) return;
  if(val==='key'){
    detail.innerHTML=`<div class="field"><label>SSH Private Key (PEM) &mdash; leave blank to keep existing</label>
<textarea id="s-key" placeholder="-----BEGIN OPENSSH PRIVATE KEY-----&#10;...&#10;-----END OPENSSH PRIVATE KEY-----"></textarea></div>
<div class="help">Key stored in CF KV. Never written to disk by the portal.</div>`;
  } else if(val==='pass'){
    detail.innerHTML=`<div class="field"><label>Password &mdash; leave blank to keep existing</label>
<input type="password" id="s-pass" placeholder="(unchanged)"></div>
<div class="help">Password stored in CF KV.</div>`;
  } else {
    detail.innerHTML='';
  }
}

async function saveSettings(){
  loading(true);
  try{
    const ep={...S.endpoints[editName]};
    ep.term_url=(document.getElementById('s-term')?.value.trim())||ep.term_url;
    ep.cf_host =(document.getElementById('s-host')?.value.trim())||ep.cf_host;
    ep.username=(document.getElementById('s-user')?.value.trim())||ep.username;
    ep.port    =parseInt(document.getElementById('s-port')?.value)||22;

    const authVal=document.querySelector('input[name=auth]:checked')?.value;
    if(authVal==='key'){
      const pem=document.getElementById('s-key')?.value.trim();
      if(pem){
        await kvPut('key:'+editName, btoa(unescape(encodeURIComponent(pem))));
        ep.has_key=true; ep.has_password=false;
      }
    } else if(authVal==='pass'){
      const pw=document.getElementById('s-pass')?.value;
      if(pw){
        await kvPut('pass:'+editName, pw);
        ep.has_password=true; ep.has_key=false;
      }
    } else {
      if(ep.has_key){ await kvDel('key:'+editName); ep.has_key=false; }
      if(ep.has_password){ await kvDel('pass:'+editName); ep.has_password=false; }
    }

    S.endpoints[editName]=ep;
    await kvPut('endpoints', JSON.stringify(S.endpoints));
    toast('Settings saved \u2713');
    showHome();
  } catch(e){
    toast('Error: '+e.message);
  } finally { loading(false) }
}

async function deleteEndpoint(){
  if(!confirm(`Delete endpoint "${editName}"?`)) return;
  loading(true);
  try{
    await kvDel('key:'+editName);
    await kvDel('pass:'+editName);
    delete S.endpoints[editName];
    await kvPut('endpoints', JSON.stringify(S.endpoints));
    toast('Deleted');
    showHome();
  } catch(e){ toast('Error: '+e.message) }
  finally{ loading(false) }
}

// ── Add Endpoint ───────────────────────────────────────────────────────
async function addEndpoint(){
  const name=document.getElementById('a-name').value.trim();
  const term=document.getElementById('a-term').value.trim();
  const host=document.getElementById('a-host').value.trim();
  const user=document.getElementById('a-user').value.trim();
  const port=parseInt(document.getElementById('a-port').value)||22;
  if(!name){ toast('Name required'); return; }
  if(S.endpoints[name]){ toast('Name already exists'); return; }
  loading(true);
  try{
    S.endpoints[name]={ term_url:term, cf_host:host, username:user, port, has_key:false, has_password:false, last_connected:null, connect_count:0 };
    await kvPut('endpoints', JSON.stringify(S.endpoints));
    toast('Endpoint added');
    ['a-name','a-term','a-host','a-user'].forEach(id=>document.getElementById(id).value='');
    document.getElementById('a-port').value='22';
    showHome();
  } catch(e){ toast('Error: '+e.message) }
  finally{ loading(false) }
}

// ── Wire events ────────────────────────────────────────────────────────
document.getElementById('auth-btn').onclick=async()=>{
  const tok=document.getElementById('tok').value.trim();
  const persist=document.getElementById('remember').checked;
  if(!tok){ showErr('auth-err','Token required'); return; }
  loading(true);
  try{ await doAuth(tok,persist) }
  catch(e){ showErr('auth-err',e.message) }
  finally{ loading(false) }
};
document.getElementById('tok').addEventListener('keydown',e=>{ if(e.key==='Enter') document.getElementById('auth-btn').click() });
document.getElementById('logout-btn').onclick=doLogout;
document.getElementById('acct-logout').onclick=doLogout;
document.getElementById('add-btn').onclick=()=>showView('v-add');
document.getElementById('back-btn').onclick=showHome;
document.getElementById('add-back').onclick=showHome;
document.getElementById('a-cancel').onclick=showHome;
document.getElementById('a-save').onclick=addEndpoint;

// Acct picker delegation
document.getElementById('acct-list').addEventListener('click', async e=>{
  const opt=e.target.closest('.acct-opt');
  if(!opt||!window._authAccts) return;
  loading(true);
  try{ await selectAccount(window._authAccts[parseInt(opt.dataset.i)]) }
  catch(e){ toast('Error: '+e.message) }
  finally{ loading(false) }
});

// ── Auto-login ─────────────────────────────────────────────────────────
(async()=>{
  const tok=store.get('portal_token');
  if(!tok) return;
  loading(true);
  try{ await doAuth(tok, localStorage.getItem('portal_token')!==null) }
  catch{ store.del('portal_token'); store.del('portal_account_id'); store.del('portal_kv_ns_id') }
  finally{ loading(false) }
})();

// ── Service Worker ─────────────────────────────────────────────────────
if('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(()=>{});
</script>
</body>
</html>
"""

# ═════════════════════════════════════════════════════════════════════════════
#  Worker JavaScript (ES module)
# ═════════════════════════════════════════════════════════════════════════════
# We JSON-encode each asset so backticks / special chars are safe in the JS.
_html_js     = json.dumps(SPA_HTML)
_sw_js       = json.dumps(SW_JS)
_manifest_js = json.dumps(MANIFEST)
_icon_js     = json.dumps(ICON_SVG)

WORKER_CODE = f"""\
const HTML     = {_html_js};
const SW_SRC   = {_sw_js};
const MANIFEST = {_manifest_js};
const ICON     = {_icon_js};

const CORS = {{
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'x-cf-token, Content-Type',
}};

export default {{
  async fetch(request, env) {{
    const url = new URL(request.url);

    if (request.method === 'OPTIONS')
      return new Response(null, {{ headers: CORS }});

    if (url.pathname === '/manifest.json')
      return new Response(MANIFEST, {{ headers: {{ 'Content-Type': 'application/manifest+json', ...CORS }} }});

    if (url.pathname === '/sw.js')
      return new Response(SW_SRC, {{ headers: {{ 'Content-Type': 'application/javascript', ...CORS }} }});

    if (url.pathname === '/icon.svg')
      return new Response(ICON, {{ headers: {{ 'Content-Type': 'image/svg+xml', ...CORS }} }});

    if (url.pathname.startsWith('/cf-api/'))
      return proxyCF(request, url);

    return new Response(HTML, {{ headers: {{ 'Content-Type': 'text/html; charset=utf-8' }} }});
  }}
}};

async function proxyCF(request, url) {{
  const token = request.headers.get('x-cf-token');
  if (!token)
    return new Response(JSON.stringify({{ error: 'Missing x-cf-token header' }}),
      {{ status: 401, headers: {{ 'Content-Type': 'application/json', ...CORS }} }});

  const cfPath = url.pathname.replace('/cf-api', '');
  const cfUrl  = 'https://api.cloudflare.com/client/v4' + cfPath + url.search;
  const ct     = request.headers.get('Content-Type') || 'application/json';

  try {{
    const resp = await fetch(cfUrl, {{
      method:  request.method,
      headers: {{ Authorization: `Bearer ${{token}}`, 'Content-Type': ct, 'User-Agent': 'ssh-portal/1.0' }},
      body:    ['GET','HEAD'].includes(request.method) ? undefined : request.body,
    }});
    return new Response(resp.body, {{
      status:  resp.status,
      headers: {{ 'Content-Type': resp.headers.get('Content-Type') || 'application/json', ...CORS }},
    }});
  }} catch (e) {{
    return new Response(JSON.stringify({{ error: e.message }}),
      {{ status: 502, headers: {{ 'Content-Type': 'application/json', ...CORS }} }});
  }}
}}
"""

# ═════════════════════════════════════════════════════════════════════════════
#  Deploy helpers
# ═════════════════════════════════════════════════════════════════════════════
BOUNDARY = "----PortalWorkerBoundary7x3k"

def mp(name, value, filename=None, ctype="text/plain"):
    cd = f'Content-Disposition: form-data; name="{name}"'
    if filename:
        cd += f'; filename="{filename}"'
    part  = f"--{BOUNDARY}\r\n"
    part += f"{cd}\r\nContent-Type: {ctype}\r\n\r\n"
    return part.encode() + value.encode() + b"\r\n"

def api(method, path, data=None, raw_body=None, ctype="application/json"):
    url  = f"https://api.cloudflare.com/client/v4{path}"
    body = raw_body if raw_body is not None else (json.dumps(data).encode() if data else None)
    req  = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", f"Bearer {CF_TOKEN}")
    req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, context=_SSL) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:    return json.loads(e.read())
        except: return {"success": False, "errors": [str(e)]}
    except Exception as e:
        return {"success": False, "errors": [str(e)]}

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

    url = f"https://api.cloudflare.com/client/v4/accounts/{ACCT}/workers/scripts/{SCRIPT}"
    req = urllib.request.Request(url, data=body, method="PUT")
    req.add_header("Authorization", f"Bearer {CF_TOKEN}")
    req.add_header("Content-Type",  f"multipart/form-data; boundary={BOUNDARY}")

    print(f"Deploying Worker '{SCRIPT}' -> https://{SCRIPT}.mock1ng.workers.dev ...")
    try:
        with urllib.request.urlopen(req, context=_SSL) as r:
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
    sub_url  = f"https://api.cloudflare.com/client/v4/accounts/{ACCT}/workers/scripts/{SCRIPT}/subdomain"
    sub_req  = urllib.request.Request(
        sub_url, data=json.dumps({"enabled": True}).encode(), method="POST")
    sub_req.add_header("Authorization", f"Bearer {CF_TOKEN}")
    sub_req.add_header("Content-Type",  "application/json")
    print("Enabling workers.dev subdomain ...")
    try:
        with urllib.request.urlopen(sub_req, context=_SSL) as r:
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

if __name__ == "__main__":
    deploy()
    subdomain = _cfg.get("subdomain", "?")
    print()
    print(f"Portal URL : https://portal.{subdomain}.workers.dev")
    print()
    print("The portal is DYNAMIC -- any CF user can log in with their own API token.")
    print("No account IDs are hardcoded in the Worker.")
