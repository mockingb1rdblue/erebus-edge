#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  erebus-edge -- HOME machine setup (Linux / macOS)
#  Run this on the machine you want to SSH INTO (your home server).
#
#  Usage:
#    sudo ./home_linux_mac.sh --token <TUNNEL_TOKEN> [--ca-key <KEY>] [--ssh-host <HOST>]
#    ./home_linux_mac.sh --no-sudo --token <TUNNEL_TOKEN> [--ssh-host <HOST>]
#
#  bootstrap.sh prints the exact command with your token.
#
#  Why sudo?
#    The default mode installs cloudflared as a system service (auto-starts
#    on boot) and configures SSH certificate trust in /etc/ssh/. These are
#    system-level operations that require root.
#
#    --no-sudo mode: installs cloudflared to ~/.local/bin/ and runs the
#    tunnel in the foreground (you'll need to keep a terminal open or set
#    up your own autostart). SSH CA trust is skipped (manual instructions
#    provided).
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────
TOKEN=""
SSH_CA_KEY=""
SSH_HOST=""
NO_SUDO=false

show_help() {
    cat <<'HELP'
Usage:
  sudo ./home_linux_mac.sh --token <TUNNEL_TOKEN> [OPTIONS]
  ./home_linux_mac.sh --no-sudo --token <TUNNEL_TOKEN> [OPTIONS]

Required:
  --token <TOKEN>       Cloudflare Tunnel token (from bootstrap.sh output)

Options:
  --ca-key <KEY>        SSH CA public key for short-lived certificates
  --ssh-host <HOST>     Your SSH hostname (e.g. ssh.you.workers.dev)
  --no-sudo             Install without root (user-local, foreground tunnel)
  --help, -h            Show this help

Why does the default mode need sudo?
  1. Installs cloudflared to /usr/local/bin/ (system PATH)
  2. Registers cloudflared as a system service (auto-starts on boot)
  3. Enables SSH server if not already running
  4. Writes SSH CA key to /etc/ssh/ (short-lived certificate trust)
  5. Restarts sshd to apply config changes

What --no-sudo does differently:
  - Installs cloudflared to ~/.local/bin/ (user PATH)
  - Runs tunnel in foreground (no auto-start on boot)
  - Skips SSH server check (you must ensure sshd is running)
  - Skips SSH CA config (prints manual instructions instead)
HELP
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)    TOKEN="$2";      shift 2 ;;
        --ca-key)   SSH_CA_KEY="$2"; shift 2 ;;
        --ssh-host) SSH_HOST="$2";   shift 2 ;;
        --no-sudo)  NO_SUDO=true;    shift ;;
        --help|-h)  show_help ;;
        *) echo "Unknown argument: $1 (try --help)"; exit 1 ;;
    esac
done

if [[ -z "$TOKEN" ]]; then
    echo "Usage: sudo $0 --token <TUNNEL_TOKEN> [--ca-key <KEY>] [--ssh-host <HOST>]"
    echo "       $0 --no-sudo --token <TUNNEL_TOKEN> [--ssh-host <HOST>]"
    echo ""
    echo "Run './installers/bootstrap.sh' first -- it prints the exact command."
    echo "Use --help for details on why sudo is needed and how to avoid it."
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
if $NO_SUDO; then
    info "Skipping SSH server check (--no-sudo mode)"
    info "Make sure SSH is enabled: System Settings -> General -> Sharing -> Remote Login (macOS)"
    info "                          sudo systemctl enable --now ssh (Linux)"
elif $IS_MAC; then
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
_USER_BIN="$HOME/.local/bin"

if command -v cloudflared &>/dev/null; then
    ok "cloudflared already installed ($(command -v cloudflared))"
else
    info "Installing cloudflared..."
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)        CF_ARCH="amd64" ;;
        aarch64|arm64) CF_ARCH="arm64" ;;
        armv7*)        CF_ARCH="arm" ;;
        *)             err "Unknown arch: $ARCH"; exit 1 ;;
    esac

    if $NO_SUDO; then
        # User-local install to ~/.local/bin/
        mkdir -p "$_USER_BIN"
        if $IS_MAC; then
            curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${CF_ARCH}.tgz" -o /tmp/cf.tgz
            tar xzf /tmp/cf.tgz -C "$_USER_BIN/"
            chmod +x "$_USER_BIN/cloudflared"
            rm -f /tmp/cf.tgz
        else
            curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
                -o "$_USER_BIN/cloudflared"
            chmod +x "$_USER_BIN/cloudflared"
        fi
        export PATH="$_USER_BIN:$PATH"
        ok "cloudflared installed to $_USER_BIN/cloudflared"
    else
        if $IS_MAC; then
            if command -v brew &>/dev/null; then
                brew install cloudflare/cloudflare/cloudflared 2>/dev/null && ok "Installed via brew" || true
            fi
            if ! command -v cloudflared &>/dev/null; then
                curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-${CF_ARCH}.tgz" -o /tmp/cf.tgz
                tar xzf /tmp/cf.tgz -C /tmp/
                sudo mv /tmp/cloudflared /usr/local/bin/
                sudo chmod +x /usr/local/bin/cloudflared
                rm -f /tmp/cf.tgz
                ok "cloudflared binary installed to /usr/local/bin/"
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
                ok "cloudflared binary installed to /usr/local/bin/"
            fi
        fi
    fi
fi

# ── 3. Register tunnel service ────────────────────────────────────
if $NO_SUDO; then
    info "Starting cloudflared tunnel in foreground (--no-sudo mode)..."
    info "The tunnel will run until you close this terminal or press Ctrl+C."
    info "To run in background:  nohup cloudflared tunnel run --token <TOKEN> &"
    echo ""
    cloudflared tunnel run --token "$TOKEN"
    # If we get here, cloudflared exited
    info "cloudflared tunnel stopped."
    exit 0
else
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
fi

# ── 4. SSH CA trust (short-lived certificates) ────────────────────
if [[ -n "$SSH_CA_KEY" ]]; then
    if $NO_SUDO; then
        info "SSH CA trust requires root to modify /etc/ssh/sshd_config."
        info "To configure manually, run these commands with sudo:"
        echo ""
        echo "    echo '$SSH_CA_KEY' | sudo tee /etc/ssh/ca.pub"
        echo "    echo 'TrustedUserCAKeys /etc/ssh/ca.pub' | sudo tee -a /etc/ssh/sshd_config"
        if $IS_MAC; then
            echo "    sudo launchctl unload /System/Library/LaunchDaemons/ssh.plist"
            echo "    sudo launchctl load /System/Library/LaunchDaemons/ssh.plist"
        else
            echo "    sudo systemctl restart sshd"
        fi
        echo ""
    else
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
