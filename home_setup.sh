#!/usr/bin/env bash
# =============================================================================
# home_setup.sh  --  Set up Cloudflare Tunnel on your home Linux machine
# =============================================================================
# Run this ONCE on your home machine.  For Mac/Windows, use home_setup.py.
#
# Usage:
#   bash home_setup.sh <TUNNEL_TOKEN> [SSH_CA_PUBLIC_KEY]
#
#   Both values are printed by:  python bootstrap.py  (on your work machine)
#
# What this does:
#   1. Installs cloudflared (if not already installed)
#   2. Registers cloudflared as a systemd service
#   3. Optionally configures sshd to trust CF's SSH CA (short-lived certs)
# =============================================================================

set -euo pipefail

# ── Token: pass as first arg or env var ───────────────────────────────────────
TUNNEL_TOKEN="${1:-${TUNNEL_TOKEN:-}}"
if [[ -z "$TUNNEL_TOKEN" ]]; then
    echo "Usage: bash home_setup.sh <TUNNEL_TOKEN> [SSH_CA_PUBLIC_KEY]"
    echo "  Token is printed by: python bootstrap.py  (on your work machine)"
    echo "  Or set env: TUNNEL_TOKEN=... bash home_setup.sh"
    exit 1
fi
SSH_CA_KEY="${2:-${SSH_CA_KEY:-}}"

# ── colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
info() { echo -e "${YELLOW}[INFO]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*"; }

echo ""
echo "=============================================="
echo "  erebus-edge -- Home Setup (Linux)"
echo "=============================================="
echo ""

# ── 1. Install cloudflared ────────────────────────────────────────────────────
if command -v cloudflared &>/dev/null; then
    ok "cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
else
    info "Installing cloudflared..."

    if command -v apt-get &>/dev/null; then
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
            | sudo tee /etc/apt/sources.list.d/cloudflared.list
        sudo apt-get update -qq
        sudo apt-get install -y cloudflared
        ok "cloudflared installed via apt"

    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        PKG_MGR=$(command -v dnf || echo yum)
        sudo "$PKG_MGR" install -y yum-utils 2>/dev/null || true
        sudo "$PKG_MGR" config-manager --add-repo \
            https://pkg.cloudflare.com/cloudflared-ascii.repo 2>/dev/null || true
        sudo "$PKG_MGR" install -y cloudflared
        ok "cloudflared installed via $PKG_MGR"

    else
        info "No package manager detected -- downloading binary directly"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64)  CF_ARCH="amd64" ;;
            aarch64) CF_ARCH="arm64" ;;
            armv7*)  CF_ARCH="arm"   ;;
            *)       err "Unknown arch: $ARCH"; exit 1 ;;
        esac
        curl -fsSL \
            "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
            -o /usr/local/bin/cloudflared
        chmod +x /usr/local/bin/cloudflared
        ok "cloudflared binary installed to /usr/local/bin/cloudflared"
    fi
fi

# ── 2. Install cloudflared service ────────────────────────────────────────────
info "Installing cloudflared service..."
if sudo cloudflared service install "$TUNNEL_TOKEN" 2>&1; then
    ok "cloudflared service installed and started"
else
    # May already be installed
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        ok "cloudflared service already running"
    else
        info "Reinstalling service..."
        sudo cloudflared service uninstall 2>/dev/null || true
        sudo cloudflared service install "$TUNNEL_TOKEN"
        ok "cloudflared service reinstalled"
    fi
fi

# ── 3. SSH CA trust (short-lived certificates) ───────────────────────────────
if [[ -n "$SSH_CA_KEY" ]]; then
    info "Configuring sshd to trust CF SSH CA..."
    CA_PATH="/etc/ssh/ca.pub"
    echo "$SSH_CA_KEY" | sudo tee "$CA_PATH" >/dev/null
    sudo chmod 600 "$CA_PATH"
    ok "CA public key written to $CA_PATH"

    if grep -q "TrustedUserCAKeys" /etc/ssh/sshd_config; then
        ok "sshd_config already has TrustedUserCAKeys"
    else
        echo "" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        echo "# Cloudflare Access short-lived SSH certificates" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        echo "TrustedUserCAKeys $CA_PATH" | sudo tee -a /etc/ssh/sshd_config >/dev/null
        ok "TrustedUserCAKeys added to sshd_config"
    fi

    # Restart sshd
    if sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null; then
        ok "sshd restarted with CF CA trust"
    else
        err "Could not restart sshd -- restart manually"
    fi
else
    info "No SSH CA key provided -- skipping short-lived cert setup"
    info "Pass as second argument to enable: bash home_setup.sh TOKEN 'ecdsa-sha2...'"
fi

# ── 4. Verify ─────────────────────────────────────────────────────────────────
info "Waiting for tunnel to connect (up to 10s)..."
sleep 10
if systemctl is-active --quiet cloudflared 2>/dev/null; then
    ok "cloudflared service is running"
else
    err "cloudflared service does not appear to be running"
    echo "    Check: sudo systemctl status cloudflared"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------"
echo "  Done!  Your home machine is ready."
echo "----------------------------------------------"
echo ""
echo "  From your work machine:"
echo "    Browser SSH  : https://ssh.SUB.workers.dev"
echo "    CLI SSH      : connect.bat / ./connect.sh"
echo ""
echo "  This connects you to: $(whoami)@$(hostname)"
echo ""
