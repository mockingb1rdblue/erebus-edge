#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  erebus-edge -- WORK machine setup (Linux / macOS)
#  Run this on the machine you connect FROM (your work/office machine).
#  No admin/sudo required.
#
#  Usage:
#    ./work_linux_mac.sh                          (auto-reads from ../erebus-temp/)
#    ./work_linux_mac.sh --ssh-host <HOST>         (skip prompt)
#
#  If bootstrap was run on this machine, just run with no arguments.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────
SSH_HOST=""

show_help() {
    cat <<'HELP'
Usage:
  ./work_linux_mac.sh                          (auto-reads from ../erebus-temp/)
  ./work_linux_mac.sh --ssh-host <HOST>

Options:
  --ssh-host <HOST>     Your SSH hostname (e.g. ssh.yourdomain.com)
  --help, -h            Show this help

If you ran bootstrap.sh from this repo, just run with no arguments.
The script auto-reads your SSH host from ../erebus-temp/keys/portal_config.json.
HELP
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -ssh-host|--ssh-host) SSH_HOST="$2"; shift 2 ;;
        -help|--help|-h)      show_help ;;
        *) echo "Unknown argument: $1 (try --help)"; exit 1 ;;
    esac
done

# ── Auto-read config from bootstrap output if not provided ───────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CFG_FILE=""
# Check relative to installers/ dir (running from repo)
[[ -f "$_SCRIPT_DIR/../erebus-temp/keys/portal_config.json" ]] && \
    _CFG_FILE="$(cd "$_SCRIPT_DIR/.." && pwd)/erebus-temp/keys/portal_config.json"
# Check relative to repo root (running from repo root)
[[ -z "$_CFG_FILE" && -f "$_SCRIPT_DIR/../../erebus-temp/keys/portal_config.json" ]] && \
    _CFG_FILE="$(cd "$_SCRIPT_DIR/../.." && pwd)/erebus-temp/keys/portal_config.json"
# Check keys/ inside repo (legacy location)
[[ -z "$_CFG_FILE" && -f "$_SCRIPT_DIR/../keys/portal_config.json" ]] && \
    _CFG_FILE="$(cd "$_SCRIPT_DIR/.." && pwd)/keys/portal_config.json"

_json_val() {
    local key="$1"
    local val=""
    # Try python3, then python, then grep+sed
    val=$(python3 -c "import json; d=json.load(open('$_CFG_FILE')); v=d.get('$key',''); print(v if v else '')" 2>/dev/null) \
        || val=$(python -c "import json; d=json.load(open('$_CFG_FILE')); v=d.get('$key',''); print(v if v else '')" 2>/dev/null) \
        || val=$(grep "\"$key\"" "$_CFG_FILE" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' | head -1) \
        || true
    echo "$val"
}

if [[ -n "$_CFG_FILE" && -z "$SSH_HOST" ]]; then
    SSH_HOST=$(_json_val ssh_host)
    if [[ -n "$SSH_HOST" ]]; then
        echo ""
        echo "  Auto-loaded config from: $_CFG_FILE"
    fi
fi

# ── Interactive prompt if still missing ──────────────────────────
if [[ -z "$SSH_HOST" ]]; then
    if [[ -t 0 ]]; then
        echo ""
        echo "  ┌─────────────────────────────────────────────────────────┐"
        echo "  │  SSH host not found -- let's set it up.                 │"
        echo "  └─────────────────────────────────────────────────────────┘"
        echo ""
        echo "  Your SSH host looks like:  ssh.yourdomain.com"
        echo ""
        echo "  Where to find it:"
        echo "    1. If you ran bootstrap, it printed your endpoints at the end."
        echo "       Look for the line:  Browser SSH : https://ssh.yourdomain.com"
        echo ""
        echo "    2. If someone else set this up for you, ask them for the SSH"
        echo "       host -- they'll have it from their bootstrap output."
        echo ""
        echo "    3. If you ran the home/server installer, it showed your SSH"
        echo "       host in the banner at the top and the summary at the end."
        echo ""
        echo "    4. You can also find it in the Cloudflare dashboard:"
        echo "       dash.cloudflare.com -> DNS -> look for a CNAME record named 'ssh'"
        echo "       The full hostname is: ssh.yourdomain.com"
        echo ""
        read -rp "  Paste your SSH host here: " SSH_HOST
        echo ""
    fi
fi

if [[ -z "$SSH_HOST" ]]; then
    echo ""
    echo "  Could not determine SSH host."
    echo ""
    echo "  If you ran bootstrap on this machine, re-run from the repo"
    echo "  directory so the script can find the config automatically."
    echo ""
    echo "  Otherwise, pass it directly:"
    echo "    $0 --ssh-host ssh.yourdomain.com"
    echo ""
    echo "  Use --help for all options."
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
echo "    SSH host: $SSH_HOST"
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
