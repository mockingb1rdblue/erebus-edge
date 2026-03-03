#!/usr/bin/env bash
# =============================================================================
# home_setup.sh  --  Set up Cloudflare Tunnel on your home Linux machine
# =============================================================================
# Run this ONCE on your home machine to install cloudflared and register the
# tunnel.  After that, the tunnel starts automatically at boot via systemd.
#
# What this does:
#   1. Installs cloudflared (if not already installed)
#   2. Registers the pre-created tunnel using the token
#   3. Installs a systemd service so the tunnel starts on boot
#   4. Confirms SSH is reachable via ssh.mock1ng.workers.dev
# =============================================================================

set -euo pipefail

# ── Token: pass as first arg or env var ───────────────────────────────────────
TUNNEL_TOKEN="${1:-${TUNNEL_TOKEN:-}}"
if [[ -z "$TUNNEL_TOKEN" ]]; then
    echo "Usage: bash home_setup.sh <TUNNEL_TOKEN>"
    echo "  Token is printed by: python bootstrap.py  (on your work machine)"
    echo "  Or set env: TUNNEL_TOKEN=... bash home_setup.sh"
    exit 1
fi
SERVICE_NAME="cloudflared-home"
TTYD_SERVICE="ttyd-portal"
TTYD_PORT=7681

# ── colours ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
info() { echo -e "${YELLOW}[INFO]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC}   $*"; }

echo ""
echo "=============================================="
echo "  Cloudflare Tunnel + ttyd -- Home Setup"
echo "=============================================="
echo ""

# ── 1. Install cloudflared ────────────────────────────────────────────────────
if command -v cloudflared &>/dev/null; then
    ok "cloudflared already installed: $(cloudflared --version 2>&1 | head -1)"
else
    info "Installing cloudflared..."

    if command -v apt-get &>/dev/null; then
        # Debian / Ubuntu
        curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
            | sudo tee /etc/apt/sources.list.d/cloudflared.list
        sudo apt-get update -qq
        sudo apt-get install -y cloudflared
        ok "cloudflared installed via apt"

    elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        # RHEL / Fedora / CentOS
        PKG_MGR=$(command -v dnf || echo yum)
        sudo "$PKG_MGR" install -y yum-utils 2>/dev/null || true
        sudo "$PKG_MGR" config-manager --add-repo \
            https://pkg.cloudflare.com/cloudflared-ascii.repo 2>/dev/null || true
        sudo "$PKG_MGR" install -y cloudflared
        ok "cloudflared installed via $PKG_MGR"

    elif command -v brew &>/dev/null; then
        # macOS
        brew install cloudflare/cloudflare/cloudflared
        ok "cloudflared installed via brew"

    else
        # Fallback: direct binary download
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

# ── 2. Make sure SSH is running on this machine ───────────────────────────────
info "Checking SSH daemon..."
if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    ok "SSH daemon is running"
else
    err "SSH daemon does not appear to be running!"
    echo "    Start it with:  sudo systemctl enable --now ssh"
    echo "    (or 'sshd' on some distros)"
    echo ""
    read -rp "Continue anyway? [y/N] " CONT
    [[ "$CONT" =~ ^[Yy]$ ]] || exit 1
fi

# ── 3. Install cloudflared as a systemd service ───────────────────────────────
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    ok "Tunnel service '$SERVICE_NAME' is already running"
    info "To restart it:  sudo systemctl restart $SERVICE_NAME"
elif systemctl list-unit-files | grep -q "$SERVICE_NAME"; then
    info "Service exists but is not running -- starting it..."
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "Service started"
else
    info "Installing tunnel as systemd service '$SERVICE_NAME'..."

    # Write the service file manually so we can use a custom service name
    # (cloudflared service install uses a fixed name 'cloudflared')
    sudo tee /etc/systemd/system/${SERVICE_NAME}.service >/dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel (home-ssh)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/env cloudflared tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "Tunnel service installed and started"
fi

# ── 4. Install ttyd (web terminal) ───────────────────────────────────────────
info "Setting up ttyd (web terminal, port ${TTYD_PORT})..."

_install_ttyd_binary() {
    local arch
    arch=$(uname -m)
    local ttyd_arch
    case "$arch" in
        x86_64)  ttyd_arch="x86_64" ;;
        aarch64) ttyd_arch="aarch64" ;;
        armv7*)  ttyd_arch="arm" ;;
        *)       err "Unknown arch for ttyd binary: $arch"; return 1 ;;
    esac
    local ver="1.7.7"
    local url="https://github.com/tsl0922/ttyd/releases/download/${ver}/ttyd.${ttyd_arch}"
    info "Downloading ttyd ${ver} for ${ttyd_arch}..."
    curl -fsSL -o /usr/local/bin/ttyd "$url"
    chmod +x /usr/local/bin/ttyd
    ok "ttyd ${ver} installed to /usr/local/bin/ttyd"
}

if command -v ttyd &>/dev/null; then
    ok "ttyd already installed: $(ttyd --version 2>&1 | head -1)"
elif command -v apt-get &>/dev/null; then
    sudo apt-get install -y ttyd 2>/dev/null && ok "ttyd installed via apt" || _install_ttyd_binary
elif command -v dnf &>/dev/null; then
    sudo dnf install -y ttyd 2>/dev/null && ok "ttyd installed via dnf" || _install_ttyd_binary
elif command -v yum &>/dev/null; then
    sudo yum install -y ttyd 2>/dev/null && ok "ttyd installed via yum" || _install_ttyd_binary
elif command -v brew &>/dev/null; then
    brew install ttyd && ok "ttyd installed via brew"
else
    _install_ttyd_binary
fi

# ── 5. Install ttyd as a systemd service ─────────────────────────────────────
if systemctl is-active --quiet "$TTYD_SERVICE" 2>/dev/null; then
    ok "ttyd service '${TTYD_SERVICE}' is already running"
elif systemctl list-unit-files | grep -q "$TTYD_SERVICE"; then
    info "ttyd service exists but is not running -- starting it..."
    sudo systemctl enable --now "$TTYD_SERVICE"
    ok "ttyd service started"
else
    info "Installing ttyd as systemd service '${TTYD_SERVICE}'..."
    TTYD_BIN=$(command -v ttyd)
    CURRENT_USER=$(whoami)
    sudo tee /etc/systemd/system/${TTYD_SERVICE}.service >/dev/null <<EOF
[Unit]
Description=ttyd Web Terminal (SSH Portal)
After=network.target

[Service]
Type=simple
User=${CURRENT_USER}
ExecStart=${TTYD_BIN} -p ${TTYD_PORT} -i lo -t titleFixed=1 -t disableReconnect=1 tmux new-session -A -s work
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$TTYD_SERVICE"
    ok "ttyd service installed and started on port ${TTYD_PORT}"
fi

# ── 6. Wait for tunnel to connect ─────────────────────────────────────────────
info "Waiting for tunnel to connect (up to 15s)..."
for i in $(seq 1 15); do
    if cloudflared tunnel --credentials-file /dev/null info 2>/dev/null | grep -q "HEALTHY" 2>/dev/null; then
        ok "Tunnel is HEALTHY"
        break
    fi
    sleep 1
done

# ── 7. Show status ────────────────────────────────────────────────────────────
echo ""
echo "----------------------------------------------"
echo "  Service status"
echo "----------------------------------------------"
systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null || true
echo ""
systemctl status "$TTYD_SERVICE" --no-pager -l 2>/dev/null || true

echo ""
echo "----------------------------------------------"
echo "  Done!  Your home machine is ready."
echo "----------------------------------------------"
echo ""
echo "  Services running:"
echo "    cloudflared  -- CF Tunnel (SSH + web terminal)"
echo "    ttyd         -- Web terminal on localhost:${TTYD_PORT}"
echo ""
echo "  From your work machine (browser):"
echo "    https://portal.mock1ng.workers.dev   (portal PWA)"
echo "    https://term.mock1ng.workers.dev     (web terminal)"
echo ""
echo "  From your work machine (CLI SSH):"
echo "    connect.bat    (Windows cmd)"
echo "    ./connect.sh   (Git Bash)"
echo ""
echo "  This connects you to: $(whoami)@$(hostname)"
echo ""
