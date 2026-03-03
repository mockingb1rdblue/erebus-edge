#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  erebus-edge -- HOME machine setup (Linux / macOS)
#  Run this on the machine you want to SSH INTO (your home server).
#
#  Usage:
#    sudo ./home_linux_mac.sh --token <TUNNEL_TOKEN> [--ca-key <SSH_CA_PUB_KEY>] [--ssh-host <HOST>]
#
#  bootstrap.py prints the exact command with your token.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────
TOKEN=""
SSH_CA_KEY=""
SSH_HOST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)    TOKEN="$2";    shift 2 ;;
        --ca-key)   SSH_CA_KEY="$2"; shift 2 ;;
        --ssh-host) SSH_HOST="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$TOKEN" ]]; then
    echo "Usage: sudo $0 --token <TUNNEL_TOKEN> [--ca-key <SSH_CA_PUB_KEY>] [--ssh-host <HOST>]"
    echo ""
    echo "Run 'python src/bootstrap.py' first -- it prints the exact command."
    exit 1
fi

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; X='\033[0m'
ok()   { echo -e "${G}[OK]${X}   $*"; }
info() { echo -e "${Y}[..]${X}   $*"; }
err()  { echo -e "${R}[!!]${X}   $*" >&2; }

IS_MAC=false; [[ "$(uname -s)" == "Darwin" ]] && IS_MAC=true

echo ""
echo "  ================================================"
echo "    erebus-edge -- Home Machine Setup (Linux/Mac)"
echo "  ================================================"
echo ""

# ── 1. Ensure SSH server is running ───────────────────────────────
if $IS_MAC; then
    if systemsetup -getremotelogin 2>/dev/null | grep -qi "on"; then
        ok "Remote Login (SSH) is enabled"
    else
        info "Enabling Remote Login (SSH)..."
        sudo systemsetup -setremotelogin on 2>/dev/null || {
            err "Could not enable Remote Login automatically"
            err "Enable manually: System Settings -> General -> Sharing -> Remote Login"
        }
    fi
else
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        ok "SSH server is running"
    else
        info "Starting SSH server..."
        sudo systemctl enable --now ssh 2>/dev/null || sudo systemctl enable --now sshd 2>/dev/null || {
            err "Could not start sshd. Install: sudo apt install openssh-server"
        }
    fi
fi

# ── 2. Install cloudflared ────────────────────────────────────────
if command -v cloudflared &>/dev/null; then
    ok "cloudflared already installed"
else
    info "Installing cloudflared..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)        CF_ARCH="amd64" ;;
        aarch64|arm64) CF_ARCH="arm64" ;;
        armv7*)        CF_ARCH="arm" ;;
        *)             err "Unknown arch: $ARCH"; exit 1 ;;
    esac
    if $IS_MAC; then
        if command -v brew &>/dev/null; then
            brew install cloudflare/cloudflare/cloudflared 2>/dev/null && ok "Installed via brew" || true
        fi
        if ! command -v cloudflared &>/dev/null; then
            curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${CF_ARCH}.tgz" -o /tmp/cf.tgz
            tar xzf /tmp/cf.tgz -C /usr/local/bin/ cloudflared 2>/dev/null || tar xzf /tmp/cf.tgz -C /tmp/ && sudo mv /tmp/cloudflared /usr/local/bin/
            sudo chmod +x /usr/local/bin/cloudflared
            rm -f /tmp/cf.tgz
            ok "cloudflared binary installed"
        fi
    else
        if command -v apt-get &>/dev/null; then
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
                | sudo tee /etc/apt/sources.list.d/cloudflared.list
            sudo apt-get update -qq && sudo apt-get install -y cloudflared 2>/dev/null && ok "Installed via apt"
        elif command -v dnf &>/dev/null; then
            sudo dnf install -y cloudflared 2>/dev/null && ok "Installed via dnf"
        fi
        if ! command -v cloudflared &>/dev/null; then
            sudo curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
                -o /usr/local/bin/cloudflared
            sudo chmod +x /usr/local/bin/cloudflared
            ok "cloudflared binary installed"
        fi
    fi
fi

# ── 3. Register tunnel service ────────────────────────────────────
info "Installing cloudflared tunnel service..."
if sudo cloudflared service install "$TOKEN" 2>/dev/null; then
    ok "Tunnel service installed and started"
else
    if pgrep -x cloudflared &>/dev/null; then
        info "Reinstalling with current token..."
        sudo cloudflared service uninstall 2>/dev/null || true
        sudo cloudflared service install "$TOKEN"
        ok "Service reinstalled"
    else
        err "Service install failed"
    fi
fi

# ── 4. SSH CA trust (short-lived certificates) ────────────────────
if [[ -n "$SSH_CA_KEY" ]]; then
    info "Configuring sshd to trust CF SSH CA..."
    CA_PATH="/etc/ssh/ca.pub"
    SSHD_CFG="/etc/ssh/sshd_config"

    echo "$SSH_CA_KEY" | sudo tee "$CA_PATH" >/dev/null
    sudo chmod 600 "$CA_PATH"
    ok "CA key written to $CA_PATH"

    if grep -q "TrustedUserCAKeys" "$SSHD_CFG" 2>/dev/null; then
        ok "sshd_config already has TrustedUserCAKeys"
    else
        printf '\n# Cloudflare Access short-lived SSH certificates\nTrustedUserCAKeys %s\n' "$CA_PATH" \
            | sudo tee -a "$SSHD_CFG" >/dev/null
        ok "TrustedUserCAKeys added to sshd_config"
    fi

    if $IS_MAC; then
        sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
        sudo launchctl load /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true
        ok "sshd restarted (launchd)"
    else
        sudo systemctl restart ssh 2>/dev/null || sudo systemctl restart sshd 2>/dev/null
        ok "sshd restarted"
    fi
else
    info "No SSH CA key provided -- short-lived certs not configured"
fi

# ── 5. Verify ─────────────────────────────────────────────────────
info "Waiting for tunnel..."
sleep 5
if pgrep -x cloudflared &>/dev/null; then
    ok "cloudflared is running"
else
    err "cloudflared may not be running -- check: sudo systemctl status cloudflared"
fi

echo ""
echo "  ================================================"
echo "    Done!  Home machine is ready."
echo "  ================================================"
echo ""
echo "  Now run the WORK machine installer on the machine"
echo "  you connect FROM."
if [[ -n "$SSH_HOST" ]]; then
    echo "    Browser : https://$SSH_HOST"
    echo "    CLI     : ssh YOUR_USER@$SSH_HOST"
fi
echo ""
