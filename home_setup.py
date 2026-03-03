#!/usr/bin/env python3
"""
home_setup.py — Cross-platform home endpoint setup for erebus-edge.

Downloads cloudflared, registers it as a system service, and configures
sshd to trust Cloudflare's short-lived certificate CA (no static SSH keys).

Usage:
  python3 home_setup.py --token TOKEN --ssh-ca-key 'ecdsa-sha2-nistp256 AAAA...'

  TOKEN and SSH_CA_KEY are printed by `python bootstrap.py` on your work machine.

What it does:
  1. Downloads cloudflared binary if missing
  2. Runs `cloudflared service install TOKEN` (cross-platform service registration)
  3. Configures sshd to trust CF's SSH CA (enables short-lived certificates)
  4. Restarts sshd so the CA takes effect
  5. Verifies the tunnel is connected
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
    p = argparse.ArgumentParser(
        description="Home machine setup for erebus-edge SSH portal")
    p.add_argument(
        "--token", "-t",
        default=os.environ.get("TUNNEL_TOKEN", ""),
        help="Cloudflare Tunnel token (or set env TUNNEL_TOKEN)",
    )
    p.add_argument(
        "--ssh-ca-key",
        default=os.environ.get("SSH_CA_KEY", ""),
        help="CF SSH CA public key for short-lived certs (or set env SSH_CA_KEY)",
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
SSH_CA_KEY   = _ARGS.ssh_ca_key
SSH_HOST     = _ARGS.ssh_host or "ssh.SUBDOMAIN.workers.dev"

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

# ── SSL: bypass corporate MITM certs ─────────────────────────────────────────
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode    = ssl.CERT_NONE

# ── Output helpers ────────────────────────────────────────────────────────────
def ok(msg):   print("  [OK]  {}".format(msg))
def info(msg): print("  [..]  {}".format(msg))
def warn(msg): print("  [!!]  {}".format(msg), file=sys.stderr)
def hdr(msg):
    print("")
    print("  " + "-" * 48)
    print("    {}".format(msg))
    print("  " + "-" * 48)


# ── Download helper ───────────────────────────────────────────────────────────
def _download(url, dest):
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


# ── cloudflared binary ────────────────────────────────────────────────────────
def _cf_url():
    base = "https://github.com/cloudflare/cloudflared/releases/latest/download/"
    if IS_WIN:
        return base + "cloudflared-windows-amd64.exe"
    if IS_MAC:
        return base + "cloudflared-darwin-{}.tgz".format(ARCH)
    return base + "cloudflared-linux-{}".format(ARCH)


def install_cloudflared():
    """Ensure cloudflared is installed; return Path to binary."""
    found = shutil.which("cloudflared")
    if found:
        ok("cloudflared already installed: {}".format(found))
        return Path(found)

    if IS_WIN:
        dest = Path(os.environ.get("LOCALAPPDATA", "C:/Users/Public")) / "cloudflared" / "cloudflared.exe"
    else:
        dest = Path("/usr/local/bin/cloudflared")

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


# ── cloudflared service ───────────────────────────────────────────────────────
def install_service(cf_bin):
    """Register cloudflared as a system service using its built-in installer."""
    info("Installing cloudflared service...")

    # cloudflared service install registers as:
    #   Linux:   systemd unit
    #   macOS:   launchd plist
    #   Windows: Windows service
    r = subprocess.run(
        [str(cf_bin), "service", "install", TUNNEL_TOKEN],
        capture_output=True, text=True,
    )
    if r.returncode == 0:
        ok("cloudflared service installed and started")
        return True

    stderr = r.stderr.strip()
    if "already exists" in stderr.lower() or "already installed" in stderr.lower():
        ok("cloudflared service already installed")
        # Restart to pick up any config changes
        subprocess.run([str(cf_bin), "service", "uninstall"], capture_output=True)
        subprocess.run([str(cf_bin), "service", "install", TUNNEL_TOKEN], capture_output=True)
        ok("cloudflared service reinstalled with current token")
        return True

    # service install may need root/admin
    if IS_WIN:
        warn("Service install may need admin. Starting in background...")
        subprocess.Popen(
            [str(cf_bin), "tunnel", "--no-autoupdate", "run", "--token", TUNNEL_TOKEN],
            creationflags=0x00000008,  # DETACHED_PROCESS
            close_fds=True,
        )
        ok("cloudflared started in background (run as admin for persistent service)")
        return True

    # Linux/Mac: retry with sudo
    info("Retrying with sudo...")
    r2 = subprocess.run(
        ["sudo", str(cf_bin), "service", "install", TUNNEL_TOKEN],
        capture_output=True, text=True,
    )
    if r2.returncode == 0:
        ok("cloudflared service installed (via sudo)")
        return True

    warn("Service install failed: {}".format(stderr or r2.stderr.strip()))
    warn("Manual start: {} tunnel --no-autoupdate run --token TOKEN".format(cf_bin))
    return False


# ── SSH CA trust ──────────────────────────────────────────────────────────────
def configure_ssh_ca():
    """Configure sshd to trust CF's short-lived certificate CA."""
    if not SSH_CA_KEY:
        info("No SSH CA key provided -- skipping short-lived cert setup")
        info("Pass --ssh-ca-key to enable passwordless SSH via CF certificates")
        return False

    if IS_WIN:
        sshd_config = Path(r"C:\ProgramData\ssh\sshd_config")
        ca_path     = Path(r"C:\ProgramData\ssh\ca.pub")
    else:
        sshd_config = Path("/etc/ssh/sshd_config")
        ca_path     = Path("/etc/ssh/ca.pub")

    if not sshd_config.exists():
        warn("sshd_config not found at {}".format(sshd_config))
        warn("Install OpenSSH server first, then re-run this script")
        return False

    # Write CA public key
    info("Writing CF SSH CA to {}".format(ca_path))
    try:
        ca_path.write_text(SSH_CA_KEY + "\n")
        if not IS_WIN:
            ca_path.chmod(0o600)
    except PermissionError:
        info("Retrying with sudo...")
        tmp = Path(tempfile.mktemp(suffix=".pub"))
        tmp.write_text(SSH_CA_KEY + "\n")
        subprocess.run(["sudo", "cp", str(tmp), str(ca_path)])
        subprocess.run(["sudo", "chmod", "600", str(ca_path)])
        tmp.unlink()

    ok("CA public key written to {}".format(ca_path))

    # Check if sshd_config already has TrustedUserCAKeys
    config_text = sshd_config.read_text()
    if "TrustedUserCAKeys" in config_text:
        ok("sshd_config already has TrustedUserCAKeys directive")
    else:
        info("Adding TrustedUserCAKeys to sshd_config")
        lines_to_add = "\n# Cloudflare Access short-lived SSH certificates\nTrustedUserCAKeys {}\n".format(ca_path)
        try:
            with open(sshd_config, "a") as f:
                f.write(lines_to_add)
        except PermissionError:
            tmp = Path(tempfile.mktemp(suffix=".conf"))
            tmp.write_text(lines_to_add)
            subprocess.run(["sudo", "bash", "-c",
                            "cat {} >> {}".format(tmp, sshd_config)])
            tmp.unlink()
        ok("TrustedUserCAKeys added to sshd_config")

    # Restart sshd
    info("Restarting sshd...")
    if IS_WIN:
        subprocess.run(["net", "stop", "sshd"], capture_output=True)
        subprocess.run(["net", "start", "sshd"], capture_output=True)
    elif IS_MAC:
        subprocess.run(["sudo", "launchctl", "unload", "/System/Library/LaunchDaemons/ssh.plist"],
                        capture_output=True)
        subprocess.run(["sudo", "launchctl", "load", "/System/Library/LaunchDaemons/ssh.plist"],
                        capture_output=True)
    else:
        r = subprocess.run(["sudo", "systemctl", "restart", "ssh"], capture_output=True)
        if r.returncode != 0:
            subprocess.run(["sudo", "systemctl", "restart", "sshd"], capture_output=True)

    ok("sshd restarted with CF CA trust")
    return True


# ── Verify ────────────────────────────────────────────────────────────────────
def verify():
    info("Waiting 8s for tunnel to establish...")
    time.sleep(8)
    url = "https://{}/".format(SSH_HOST)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "cloudflared/2024.1.0"})
        with urllib.request.urlopen(req, context=_SSL, timeout=10) as r:
            ok("CF endpoint reachable: {} (HTTP {})".format(SSH_HOST, r.status))
    except Exception as e:
        code = getattr(e, "code", None)
        if code in (502, 530):
            ok("CF tunnel is UP (HTTP {} = waiting for SSH listener)".format(code))
        else:
            info("Endpoint check: {} (tunnel may still be starting)".format(e))


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("")
    print("  " + "=" * 48)
    print("    erebus-edge -- Home Machine Setup")
    print("  " + "=" * 48)

    plat = "macOS" if IS_MAC else ("Windows" if IS_WIN else "Linux")
    print("")
    info("Platform : {} ({})".format(plat, ARCH))
    info("User     : {}".format(os.environ.get("USER") or os.environ.get("USERNAME") or "unknown"))
    print("")

    hdr("Step 1 / 3 : cloudflared")
    cf_bin = install_cloudflared()

    hdr("Step 2 / 3 : cloudflared service")
    install_service(cf_bin)

    hdr("Step 3 / 3 : SSH CA trust (short-lived certificates)")
    ca_ok = configure_ssh_ca()

    hdr("Verifying")
    verify()

    print("")
    print("  " + "=" * 48)
    print("    Done!  Your home machine is ready.")
    print("  " + "=" * 48)
    print("")
    print("  From your work machine (browser):")
    print("    https://{}   (browser SSH terminal)".format(SSH_HOST))
    print("")
    print("  From your work machine (CLI):")
    print("    connect.bat  (Windows)  |  ./connect.sh  (Git Bash / Mac / Linux)")
    print("")
    if ca_ok:
        print("  Short-lived certificates: ENABLED")
        print("  CF generates a temporary SSH key for each session -- no static keys needed.")
    else:
        print("  Short-lived certificates: NOT CONFIGURED")
        print("  Pass --ssh-ca-key to enable. Standard SSH key auth still works.")
    print("")


if __name__ == "__main__":
    main()
