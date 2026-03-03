#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  erebus-edge -- WORK machine setup (Linux / macOS)
#  Run this on the machine you connect FROM (your work/office machine).
#  No admin/sudo required.
#
#  Usage:
#    chmod +x work_linux_mac.sh && ./work_linux_mac.sh --ssh-host <HOST>
#
#  bootstrap.py prints the exact command with your host.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────
SSH_HOST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ssh-host) SSH_HOST="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$SSH_HOST" ]]; then
    echo "Usage: $0 --ssh-host <HOST>"
    echo ""
    echo "Example: $0 --ssh-host ssh.myname.workers.dev"
    echo ""
    echo "Run 'python src/bootstrap.py' first -- it prints the exact command."
    exit 1
fi

INSTALL_DIR="${HOME}/.erebus-edge"

G='\033[0;32m'; Y='\033[1;33m'; X='\033[0m'
ok()   { echo -e "${G}[OK]${X}   $*"; }
info() { echo -e "${Y}[..]${X}   $*"; }

echo ""
echo "  ================================================"
echo "    erebus-edge -- Work Machine Setup (Linux/Mac)"
echo "  ================================================"
echo ""

mkdir -p "$INSTALL_DIR"

# ── 1. Download cloudflared (portable, no admin) ──────────────────
CF_BIN="$INSTALL_DIR/cloudflared"
if command -v cloudflared &>/dev/null; then
    ok "cloudflared already in PATH"
    CF_BIN=$(command -v cloudflared)
elif [[ -x "$CF_BIN" ]]; then
    ok "cloudflared already at $CF_BIN"
else
    ARCH=$(uname -m)
    OS=$(uname -s | tr A-Z a-z)
    case "$ARCH" in
        x86_64)        CF_ARCH="amd64" ;;
        aarch64|arm64) CF_ARCH="arm64" ;;
        armv7*)        CF_ARCH="arm" ;;
        *)             CF_ARCH="amd64" ;;
    esac
    if [[ "$OS" == "darwin" ]]; then
        info "Downloading cloudflared for macOS ($CF_ARCH)..."
        curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${CF_ARCH}.tgz" -o /tmp/cf.tgz
        tar xzf /tmp/cf.tgz -C "$INSTALL_DIR/"
        rm -f /tmp/cf.tgz
    else
        info "Downloading cloudflared for Linux ($CF_ARCH)..."
        curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" -o "$CF_BIN"
    fi
    chmod +x "$CF_BIN"
    ok "cloudflared installed to $CF_BIN"
fi

# ── 2. Create connect script ─────────────────────────────────────
CONNECT="$INSTALL_DIR/connect.sh"
cat > "$CONNECT" << SCRIPT
#!/usr/bin/env bash
SSH_HOST="$SSH_HOST"
CF_BIN="$CF_BIN"
read -rp "  Username on remote host: " USER
ssh -o "ProxyCommand=\$CF_BIN access ssh --hostname \$SSH_HOST" "\$USER@\$SSH_HOST"
SCRIPT
chmod +x "$CONNECT"
ok "Created $CONNECT"

# ── 3. SSH config entry ──────────────────────────────────────────
SSH_CFG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
if grep -q "$SSH_HOST" "$SSH_CFG" 2>/dev/null; then
    ok "SSH config already has $SSH_HOST entry"
else
    cat >> "$SSH_CFG" << EOF

# erebus-edge -- CF Tunnel SSH
Host $SSH_HOST
    ProxyCommand $CF_BIN access ssh --hostname %h
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    chmod 600 "$SSH_CFG"
    ok "Added SSH config entry for $SSH_HOST"
    info "Connect with:  ssh YOUR_USER@$SSH_HOST"
fi

echo ""
echo "  ================================================"
echo "    Done!  Work machine is ready."
echo "  ================================================"
echo ""
echo "  Connect to your home machine:"
echo "    Browser : https://$SSH_HOST  (email OTP login)"
echo "    CLI     : ssh YOUR_USER@$SSH_HOST"
echo "    Script  : $CONNECT"
echo ""
