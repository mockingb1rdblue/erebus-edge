#!/usr/bin/env python3
"""
home_setup.py — Cross-platform home endpoint setup

Installs cloudflared (+ ttyd on Mac/Linux) as auto-starting services so
your home machine is reachable via the CF Tunnel SSH portal.

Run once on your home machine:

  Linux / macOS:
    python3 home_setup.py --token <YOUR_TUNNEL_TOKEN>

  Windows (PowerShell):
    python home_setup.py --token <YOUR_TUNNEL_TOKEN>

  One-liner (Linux/Mac):
    python3 <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/home_setup.py) --token TOKEN

  Token source: printed by `python bootstrap.py` on your work machine,
                or found in Cloudflare Zero Trust dashboard > Access > Tunnels.

What it does:
  1. Downloads cloudflared if missing
  2. Downloads ttyd if missing (Mac/Linux only; no Windows binary)
  3. Starts both immediately
  4. Installs auto-start (launchd on Mac, systemd on Linux, Startup folder on Windows)
  5. Confirms the CF Tunnel endpoint is reachable
"""

import os
import sys
import platform
import subprocess
import urllib.request
import ssl
import stat
import shutil
import tempfile
import time
import argparse
from pathlib import Path


def _parse_args():
    p = argparse.ArgumentParser(description="Home machine setup for SSH portal")
    p.add_argument(
        "--token", "-t",
        default=os.environ.get("TUNNEL_TOKEN", ""),
        help="Cloudflare Tunnel token (or set env TUNNEL_TOKEN)",
    )
    p.add_argument(
        "--portal-url",
        default=os.environ.get("PORTAL_URL", ""),
        help="Portal URL (e.g. https://portal.SUB.workers.dev)",
    )
    p.add_argument(
        "--term-url",
        default=os.environ.get("TERM_URL", ""),
        help="Terminal URL (e.g. https://term.SUB.workers.dev)",
    )
    p.add_argument(
        "--ssh-host",
        default=os.environ.get("SSH_HOST", ""),
        help="SSH Worker hostname (e.g. ssh.SUB.workers.dev)",
    )
    args = p.parse_args()
    if not args.token:
        p.error(
            "Tunnel token required.\n"
            "  Pass --token TOKEN  or  set env TUNNEL_TOKEN=TOKEN\n"
            "  Token is printed by: python bootstrap.py  (on your work machine)"
        )
    return args


_ARGS = _parse_args()
TUNNEL_TOKEN = _ARGS.token
TTYD_PORT    = 7681
TTYD_VERSION = "1.7.7"
PORTAL_URL   = _ARGS.portal_url or "https://portal.SUBDOMAIN.workers.dev"
TERM_URL     = _ARGS.term_url   or "https://term.SUBDOMAIN.workers.dev"
SSH_HOST     = _ARGS.ssh_host   or "ssh.SUBDOMAIN.workers.dev"

# ── Platform detection ────────────────────────────────────────────────────────
IS_MAC   = sys.platform == "darwin"
IS_WIN   = sys.platform == "win32"
IS_LINUX = sys.platform.startswith("linux")

_machine = platform.machine().lower()
if _machine in ("x86_64", "amd64"):
    ARCH = "amd64"
elif _machine in ("aarch64", "arm64"):
    ARCH = "arm64"
elif _machine.startswith("arm"):
    ARCH = "arm"
else:
    ARCH = _machine

# On Mac, loopback is lo0; on Linux, lo
LOOPBACK = "lo0" if IS_MAC else "lo"

# ── SSL: bypass corporate MITM certs ─────────────────────────────────────────
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode    = ssl.CERT_NONE

# ── Output helpers ────────────────────────────────────────────────────────────
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
RED    = "\033[0;31m"
RESET  = "\033[0m"
if IS_WIN:
    # Windows console may not support ANSI; keep it simple
    GREEN = YELLOW = RED = RESET = ""

def ok(msg):   print("  [OK]  {}".format(msg))
def info(msg): print("  [..]  {}".format(msg))
def warn(msg): print("  [!!]  {}".format(msg), file=sys.stderr)
def hdr(msg):
    print("")
    print("  " + "─" * 48)
    print("    {}".format(msg))
    print("  " + "─" * 48)


# ── Download helper ───────────────────────────────────────────────────────────
def _download(url, dest):
    """Download url to dest Path with progress indicator."""
    info("Downloading: {}".format(url))
    req = urllib.request.Request(url, headers={"User-Agent": "cloudflared/2024.1.0"})
    try:
        with urllib.request.urlopen(req, context=_SSL) as r:
            total = int(r.headers.get("Content-Length") or 0)
            downloaded = 0
            dest.parent.mkdir(parents=True, exist_ok=True)
            with open(dest, "wb") as f:
                while True:
                    chunk = r.read(65536)
                    if not chunk:
                        break
                    f.write(chunk)
                    downloaded += len(chunk)
                    if total > 0:
                        pct = min(100, downloaded * 100 // total)
                        mb  = downloaded // (1024 * 1024)
                        print("\r    {:3d}%  {:d}MB".format(pct, mb), end="", flush=True)
        print("")
    except Exception as e:
        print("")
        warn("Download failed: {}".format(e))
        raise


# ── cloudflared ───────────────────────────────────────────────────────────────
def _cf_url():
    base = "https://github.com/cloudflare/cloudflared/releases/latest/download/"
    if IS_WIN:
        return base + "cloudflared-windows-amd64.exe"
    if IS_MAC:
        return base + "cloudflared-darwin-{}.tgz".format(ARCH)
    return base + "cloudflared-linux-{}".format(ARCH)


def _cf_dest():
    if IS_WIN:
        return Path(os.environ.get("LOCALAPPDATA", "C:/Users/Public")) / "cloudflared" / "cloudflared.exe"
    return Path("/usr/local/bin/cloudflared")


def install_cloudflared():
    """Ensure cloudflared is installed; return Path to binary."""
    # Already in PATH?
    found = shutil.which("cloudflared")
    if found:
        ok("cloudflared already installed: {}".format(found))
        return Path(found)

    dest = _cf_dest()
    if dest.exists():
        ok("cloudflared found: {}".format(dest))
        return dest

    url = _cf_url()
    if IS_MAC and url.endswith(".tgz"):
        import tarfile
        tmp = Path(tempfile.mktemp(suffix=".tgz"))
        _download(url, tmp)
        with tarfile.open(tmp) as tf:
            tf.extractall(tmp.parent)
        # binary is named 'cloudflared' inside the archive
        extracted = tmp.parent / "cloudflared"
        if extracted.exists():
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(extracted), str(dest))
        tmp.unlink()
    else:
        _download(url, dest)

    if not IS_WIN:
        dest.chmod(dest.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)

    ok("cloudflared installed: {}".format(dest))
    return dest


# ── ttyd ──────────────────────────────────────────────────────────────────────
def _ttyd_url():
    if IS_WIN:
        return None
    base = "https://github.com/tsl0922/ttyd/releases/download/{}/".format(TTYD_VERSION)
    if IS_MAC:
        # ttyd releases have arm64 and x86_64 macOS binaries
        ttyd_arch = "arm64" if ARCH == "arm64" else "x86_64"
        return base + "ttyd.{}".format(ttyd_arch)
    # Linux
    ttyd_arch = {"amd64": "x86_64", "arm64": "aarch64", "arm": "arm"}.get(ARCH, ARCH)
    return base + "ttyd.{}".format(ttyd_arch)


def install_ttyd():
    """Ensure ttyd is installed; return Path to binary (or None on Windows)."""
    if IS_WIN:
        info("ttyd has no Windows binary -- web terminal skipped on Windows")
        return None

    found = shutil.which("ttyd")
    if found:
        ok("ttyd already installed: {}".format(found))
        return Path(found)

    dest = Path("/usr/local/bin/ttyd")
    if dest.exists():
        ok("ttyd found: {}".format(dest))
        return dest

    # Try package manager (Linux)
    if IS_LINUX:
        for pm, cmd in [
            ("apt-get", ["sudo", "apt-get", "install", "-y", "ttyd"]),
            ("dnf",     ["sudo", "dnf",     "install", "-y", "ttyd"]),
            ("yum",     ["sudo", "yum",     "install", "-y", "ttyd"]),
        ]:
            if shutil.which(pm):
                r = subprocess.run(cmd, capture_output=True)
                if r.returncode == 0:
                    found = shutil.which("ttyd")
                    if found:
                        ok("ttyd installed via {}".format(pm))
                        return Path(found)
                break  # only try the first available package manager

    # Try brew (macOS)
    if IS_MAC and shutil.which("brew"):
        r = subprocess.run(["brew", "install", "ttyd"], capture_output=True)
        if r.returncode == 0:
            found = shutil.which("ttyd")
            if found:
                ok("ttyd installed via brew")
                return Path(found)

    # Binary download fallback
    url = _ttyd_url()
    if not url:
        return None
    _download(url, dest)
    dest.chmod(dest.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    ok("ttyd installed: {}".format(dest))
    return dest


# ── macOS: launchd ────────────────────────────────────────────────────────────
CF_PLIST_LABEL   = "dev.sshportal.cloudflared"
TTYD_PLIST_LABEL = "dev.sshportal.ttyd"
LAUNCHD_DIR      = Path.home() / "Library" / "LaunchAgents"


def _write_plist(label, args, log_path):
    prog_args = "\n".join("    <string>{}</string>".format(a) for a in args)
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'
        ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        "  <key>Label</key><string>{label}</string>\n"
        "  <key>ProgramArguments</key>\n"
        "  <array>\n{args}\n  </array>\n"
        "  <key>RunAtLoad</key><true/>\n"
        "  <key>KeepAlive</key><true/>\n"
        "  <key>StandardOutPath</key><string>{log}</string>\n"
        "  <key>StandardErrorPath</key><string>{log}</string>\n"
        "</dict></plist>\n"
    ).format(label=label, args=prog_args, log=log_path)


def setup_mac(cf_bin, ttyd_bin):
    LAUNCHD_DIR.mkdir(parents=True, exist_ok=True)
    log_dir = Path.home() / "Library" / "Logs"

    # cloudflared plist
    cf_plist = LAUNCHD_DIR / "{}.plist".format(CF_PLIST_LABEL)
    cf_plist.write_text(_write_plist(
        CF_PLIST_LABEL,
        [str(cf_bin), "tunnel", "--no-autoupdate", "run", "--token", TUNNEL_TOKEN],
        str(log_dir / "cloudflared-home.log"),
    ))
    subprocess.run(["launchctl", "unload", str(cf_plist)], capture_output=True)
    r = subprocess.run(["launchctl", "load", str(cf_plist)])
    if r.returncode == 0:
        ok("cloudflared auto-start registered (launchd)")
    else:
        warn("launchctl load failed for cloudflared")

    if ttyd_bin:
        ttyd_plist = LAUNCHD_DIR / "{}.plist".format(TTYD_PLIST_LABEL)
        ttyd_plist.write_text(_write_plist(
            TTYD_PLIST_LABEL,
            [
                str(ttyd_bin),
                "-p", str(TTYD_PORT),
                "-i", LOOPBACK,
                "-t", "titleFixed=1",
                "-t", "disableReconnect=1",
                "tmux", "new-session", "-A", "-s", "work",
            ],
            str(log_dir / "ttyd-portal.log"),
        ))
        subprocess.run(["launchctl", "unload", str(ttyd_plist)], capture_output=True)
        r = subprocess.run(["launchctl", "load", str(ttyd_plist)])
        if r.returncode == 0:
            ok("ttyd auto-start registered (launchd)")
        else:
            warn("launchctl load failed for ttyd")


# ── Linux: systemd ────────────────────────────────────────────────────────────
def setup_linux(cf_bin, ttyd_bin):
    is_root = (os.geteuid() == 0)

    if is_root:
        svc_dir = Path("/etc/systemd/system")
        ctl     = ["systemctl"]
        reload_cmd  = ["systemctl", "daemon-reload"]
        enable_pfx  = ["systemctl", "enable", "--now"]
    else:
        svc_dir = Path.home() / ".config" / "systemd" / "user"
        ctl     = ["systemctl", "--user"]
        reload_cmd  = ["systemctl", "--user", "daemon-reload"]
        enable_pfx  = ["systemctl", "--user", "enable", "--now"]
        # Enable lingering so services survive after user logs out
        subprocess.run(["loginctl", "enable-linger"], capture_output=True)

    svc_dir.mkdir(parents=True, exist_ok=True)

    def _write_unit(name, content):
        path = svc_dir / name
        if is_root and not os.access(str(svc_dir), os.W_OK):
            tmp = Path(tempfile.mktemp(suffix=".service"))
            tmp.write_text(content)
            subprocess.run(["sudo", "mv", str(tmp), str(path)])
        else:
            path.write_text(content)

    want = "multi-user.target" if is_root else "default.target"

    # cloudflared unit
    _write_unit("cloudflared-home.service", (
        "[Unit]\n"
        "Description=Cloudflare Tunnel (SSH Portal)\n"
        "After=network-online.target\n"
        "Wants=network-online.target\n\n"
        "[Service]\n"
        "ExecStart={bin} tunnel --no-autoupdate run --token {token}\n"
        "Restart=on-failure\n"
        "RestartSec=5s\n\n"
        "[Install]\n"
        "WantedBy={want}\n"
    ).format(bin=cf_bin, token=TUNNEL_TOKEN, want=want))

    subprocess.run(reload_cmd)
    subprocess.run(enable_pfx + ["cloudflared-home"])
    ok("cloudflared service enabled (systemd)")

    # ttyd unit
    if ttyd_bin:
        _write_unit("ttyd-portal.service", (
            "[Unit]\n"
            "Description=ttyd Web Terminal (SSH Portal)\n"
            "After=network.target\n\n"
            "[Service]\n"
            "ExecStart={bin} -p {port} -i {lo} -t titleFixed=1"
            " -t disableReconnect=1 tmux new-session -A -s work\n"
            "Restart=on-failure\n"
            "RestartSec=5s\n\n"
            "[Install]\n"
            "WantedBy={want}\n"
        ).format(bin=ttyd_bin, port=TTYD_PORT, lo=LOOPBACK, want=want))

        subprocess.run(reload_cmd)
        subprocess.run(enable_pfx + ["ttyd-portal"])
        ok("ttyd service enabled (systemd)")


# ── Windows ───────────────────────────────────────────────────────────────────
def setup_windows(cf_bin):
    # Strategy 1: try cloudflared's built-in Windows service installer (needs admin)
    info("Attempting Windows service install (needs admin)...")
    r = subprocess.run(
        [str(cf_bin), "service", "install", TUNNEL_TOKEN],
        capture_output=True, text=True,
    )
    if r.returncode == 0:
        ok("cloudflared Windows service installed")
        subprocess.run(["net", "start", "cloudflared"], capture_output=True)
        ok("cloudflared service started")
        return

    # Strategy 2: install in Windows Startup folder (no admin, runs at login)
    startup = Path(os.environ.get("APPDATA", "")) / "Microsoft" / "Windows" / "Start Menu" / "Programs" / "Startup"
    bat = startup / "cloudflared-home.bat"
    bat.write_text(
        "@echo off\n"
        'start "" /B "{bin}" tunnel --no-autoupdate run --token {token}\n'.format(
            bin=cf_bin, token=TUNNEL_TOKEN
        )
    )
    ok("Startup shortcut created: {}".format(bat))
    info("cloudflared will auto-start at next login (no admin needed)")

    # Start immediately in background
    subprocess.Popen(
        [str(cf_bin), "tunnel", "--no-autoupdate", "run", "--token", TUNNEL_TOKEN],
        creationflags=0x00000008,  # DETACHED_PROCESS
        close_fds=True,
    )
    ok("cloudflared started in background")


# ── Verify endpoint ───────────────────────────────────────────────────────────
def verify():
    info("Waiting 8s for tunnel to establish...")
    time.sleep(8)
    url = "https://{}/".format(SSH_HOST)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cloudflared/2024.1.0"})
        with urllib.request.urlopen(req, context=_SSL, timeout=10) as r:
            ok("CF endpoint reachable: {} (HTTP {})".format(SSH_HOST, r.status))
    except Exception as e:
        # 502 is expected if home SSH isn't exposed yet — tunnel still works
        code = getattr(e, "code", None)
        if code in (502, 530):
            ok("CF tunnel is UP (HTTP {} = no home SSH listener yet, that's fine)".format(code))
        else:
            info("Endpoint check result: {} (tunnel may still be starting)".format(e))


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("")
    print("  " + "=" * 48)
    print("    SSH Portal -- Home Machine Setup")
    print("  " + "=" * 48)

    plat = "macOS" if IS_MAC else ("Windows" if IS_WIN else "Linux")
    print("")
    info("Platform : {} ({})".format(plat, ARCH))
    info("User     : {}".format(os.environ.get("USER") or os.environ.get("USERNAME") or "unknown"))
    print("")

    hdr("Step 1 / 3 : cloudflared")
    cf_bin = install_cloudflared()

    hdr("Step 2 / 3 : ttyd  (web terminal)")
    ttyd_bin = install_ttyd()

    hdr("Step 3 / 3 : auto-start services")
    if IS_MAC:
        setup_mac(cf_bin, ttyd_bin)
    elif IS_LINUX:
        setup_linux(cf_bin, ttyd_bin)
    elif IS_WIN:
        setup_windows(cf_bin)
    else:
        warn("Unknown OS -- services not configured. Run manually:")
        warn("  {} tunnel --no-autoupdate run --token {}".format(cf_bin, TUNNEL_TOKEN[:20] + "..."))

    hdr("Verifying")
    verify()

    print("")
    print("  " + "=" * 48)
    print("    Done!  Your home machine is ready.")
    print("  " + "=" * 48)
    print("")
    print("  From your work machine (browser):")
    print("    {}".format(PORTAL_URL))
    print("    {}   (web terminal)".format(TERM_URL))
    print("")
    print("  From your work machine (CLI):")
    print("    connect.bat  (Windows)  |  ./connect.sh  (Git Bash / Mac / Linux)")
    print("")
    if IS_WIN:
        print("  Note: web terminal (ttyd) is not available on Windows home machines.")
        print("  Direct SSH still works fine via the CF Tunnel.")
        print("")


if __name__ == "__main__":
    main()
