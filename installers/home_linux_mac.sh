#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  erebus-edge -- HOME machine setup (Linux / macOS)
#  Run this on the machine you want to SSH INTO (your home server).
#
#  Usage:
#    ./home_linux_mac.sh                           (auto-reads from config)
#    ./home_linux_mac.sh --sudo                    (full setup, auto-reads)
#    ./home_linux_mac.sh --restart                 (restart existing service)
#    ./home_linux_mac.sh --token <TOKEN> [OPTIONS]
#
#  If bootstrap was run on this machine, just run with no arguments.
# ═══════════════════════════════════════════════════════════════════
set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────
TOKEN=""
SSH_CA_KEY=""
SSH_HOST=""
FORCE_SUDO=false
FORCE_NO_SUDO=false
DO_RESTART=false

show_help() {
    cat <<'HELP'
Usage:
  ./home_linux_mac.sh                           (auto-reads from config)
  ./home_linux_mac.sh --sudo                    (install as boot service)
  ./home_linux_mac.sh --restart                 (restart existing service)
  ./home_linux_mac.sh --token <TOKEN> [OPTIONS]

Options:
  --token <TOKEN>       Cloudflare Tunnel token (from bootstrap output)
  --ca-key <KEY>        SSH CA public key for short-lived certificates
  --ssh-host <HOST>     Your SSH hostname (e.g. ssh.yourdomain.com)
  --sudo                Install as system service (auto-starts on boot)
  --no-sudo             Run in user mode even if launched with sudo
  --restart             Restart the existing cloudflared service
  --help, -h            Show this help

If you ran bootstrap from this repo, just run with no arguments.
The script auto-reads your config from portal_config.json.
HELP
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -token|--token)       TOKEN="$2";         shift 2 ;;
        -ca-key|--ca-key)     SSH_CA_KEY="$2";    shift 2 ;;
        -ssh-host|--ssh-host) SSH_HOST="$2";      shift 2 ;;
        -sudo|--sudo)         FORCE_SUDO=true;    shift ;;
        -no-sudo|--no-sudo)   FORCE_NO_SUDO=true; shift ;;
        -restart|--restart)   DO_RESTART=true;    shift ;;
        -help|--help|-h)      show_help ;;
        *) echo "Unknown argument: $1 (try --help)"; exit 1 ;;
    esac
done

# ── Colors and helpers ─────────────────────────────────────────
G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; D='\033[2m'; X='\033[0m'
ok()   { echo -e "${G}[OK]${X}   $*"; }
info() { echo -e "${Y}[..]${X}   $*"; }
err()  { echo -e "${R}[!!]${X}   $*" >&2; }

IS_MAC=false; [[ "$(uname -s)" == "Darwin" ]] && IS_MAC=true

# ── Handle --restart (quick path) ────────────────────────────────
if $DO_RESTART; then
    echo ""
    echo "  Restarting cloudflared service..."
    echo ""
    if $IS_MAC; then
        _PLIST="/Library/LaunchDaemons/com.cloudflare.cloudflared.plist"
        if [[ -f "$_PLIST" ]]; then
            sudo launchctl unload "$_PLIST" 2>/dev/null || true
            sleep 1
            sudo launchctl load "$_PLIST"
            sleep 3
            if pgrep -x cloudflared &>/dev/null; then
                ok "cloudflared service restarted"
            else
                err "Service did not start. Check: cat /var/log/cloudflared/cloudflared.err"
            fi
        else
            err "No service found at $_PLIST"
            err "Run the full installer first: sudo ./home_linux_mac.sh --sudo"
        fi
    else
        if systemctl is-enabled cloudflared &>/dev/null 2>&1; then
            sudo systemctl restart cloudflared
            sleep 3
            if systemctl is-active --quiet cloudflared 2>/dev/null; then
                ok "cloudflared service restarted"
            else
                err "Service did not start. Check: sudo systemctl status cloudflared"
            fi
        else
            err "No cloudflared service found."
            err "Run the full installer first: sudo ./home_linux_mac.sh --sudo"
        fi
    fi
    exit 0
fi

# ── Auto-read config from bootstrap output if flags not provided ──
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
    local key="$1"; local val=""
    val=$(python3 -c "import json; d=json.load(open('$_CFG_FILE')); v=d.get('$key',''); print(v if v else '')" 2>/dev/null) \
        || val=$(python -c "import json; d=json.load(open('$_CFG_FILE')); v=d.get('$key',''); print(v if v else '')" 2>/dev/null) \
        || val=$(grep "\"$key\"" "$_CFG_FILE" 2>/dev/null | sed 's/.*: *"\([^"]*\)".*/\1/' | head -1) \
        || true
    echo "$val"
}

if [[ -n "$_CFG_FILE" ]]; then
    [[ -z "$TOKEN" ]]      && TOKEN=$(_json_val tunnel_token)
    [[ -z "$SSH_CA_KEY" ]] && SSH_CA_KEY=$(_json_val ssh_ca_public_key)
    [[ -z "$SSH_HOST" ]]   && SSH_HOST=$(_json_val ssh_host)
    if [[ -n "$TOKEN" ]]; then
        echo ""
        echo "  Auto-loaded config from: $_CFG_FILE"
    fi
fi

# ── Interactive prompt for token if still missing ────────────────
if [[ -z "$TOKEN" ]]; then
    if [[ -t 0 ]]; then
        echo ""
        echo "  ┌─────────────────────────────────────────────────────────┐"
        echo "  │  Tunnel token not found -- let's set it up.             │"
        echo "  └─────────────────────────────────────────────────────────┘"
        echo ""
        echo "  Your tunnel token is a long base64 string (starts with 'eyJ...')."
        echo ""
        echo "  Where to find it:"
        echo "    1. If you ran bootstrap, it printed the token at the end."
        echo "       It also saved it to: ../erebus-temp/keys/portal_config.json"
        echo ""
        echo "    2. In the Cloudflare Zero Trust dashboard:"
        echo "       one.dash.cloudflare.com -> Networks -> Tunnels"
        echo "       Click your tunnel -> Configure -> copy the token"
        echo ""
        echo "    3. If someone else set this up for you, ask them for"
        echo "       the tunnel token from their bootstrap output."
        echo ""
        read -rp "  Paste your tunnel token here: " TOKEN
        echo ""
    fi
fi

if [[ -z "$TOKEN" ]]; then
    echo ""
    echo "  Could not determine tunnel token."
    echo ""
    echo "  If you ran bootstrap on this machine, re-run from the repo"
    echo "  directory so the script can find the config automatically."
    echo ""
    echo "  Otherwise, pass it directly:"
    echo "    $0 --token <YOUR_TOKEN>"
    echo ""
    echo "  Use --help for all options."
    exit 1
fi

# ── Determine sudo mode ─────────────────────────────────────────
USE_SUDO=false

if $FORCE_NO_SUDO; then
    USE_SUDO=false
elif $FORCE_SUDO; then
    USE_SUDO=true
elif [[ $EUID -eq 0 ]]; then
    USE_SUDO=true
elif [[ -t 0 ]]; then
    echo ""
    echo -e "  ${B}Choose setup mode:${X}"
    echo ""
    echo -e "  ${C}[1]${X} Quick start ${D}(no sudo needed)${X}"
    echo -e "      Installs cloudflared to ~/.local/bin/"
    echo -e "      Runs tunnel in foreground (stops when terminal closes)"
    echo -e "      SSH CA trust: prints commands for you to run manually"
    echo ""
    echo -e "  ${C}[2]${X} Install as boot service ${D}(recommended, requires sudo)${X}"
    echo -e "      Installs cloudflared system-wide"
    echo -e "      Starts on boot automatically -- survives reboots"
    echo -e "      Starts the tunnel immediately after install"
    echo -e "      Configures SSH CA trust automatically"
    echo -e "      Enables SSH server if not running"
    echo ""
    echo -ne "  ${B}Choice [1/2]:${X} "
    read -r choice
    case "$choice" in
        2) USE_SUDO=true ;;
        *) USE_SUDO=false ;;
    esac
fi

echo ""
echo "  ================================================"
echo "    erebus-edge -- Home Machine Setup (Linux/Mac)"
echo "  ================================================"
if $USE_SUDO; then
    echo -e "    Mode: ${C}Boot service${X} (sudo)"
else
    echo -e "    Mode: ${C}Quick start${X} (no sudo)"
fi
if [[ -n "$SSH_HOST" ]]; then
    echo "    SSH host: $SSH_HOST"
fi
echo ""

# ── 1. Ensure SSH server is running ───────────────────────────────
if ! $USE_SUDO; then
    info "Skipping SSH server check (no-sudo mode)"
    if $IS_MAC; then
        info "Make sure SSH is enabled: System Settings -> General -> Sharing -> Remote Login"
    else
        info "Make sure sshd is running: sudo systemctl enable --now ssh"
    fi
elif $IS_MAC; then
    if sudo systemsetup -getremotelogin 2>/dev/null | grep -qi "on"; then
        ok "Remote Login (SSH) is already enabled"
    else
        info "Enabling Remote Login (SSH)..."
        sudo systemsetup -setremotelogin on 2>/dev/null || {
            err "Could not enable Remote Login automatically"
            err "Enable manually: System Settings -> General -> Sharing -> Remote Login"
        }
        ok "Remote Login (SSH) enabled"
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

    if ! $USE_SUDO; then
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
                info "Installing cloudflared via brew (this may take a moment)..."
                HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
                    brew install cloudflare/cloudflare/cloudflared >/dev/null 2>&1 \
                    && ok "Installed via brew" || true
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

# ── 3. SSH CA trust (short-lived certificates) ────────────────────
# Do this BEFORE starting the tunnel (in no-sudo mode the tunnel blocks)
if [[ -n "$SSH_CA_KEY" ]]; then
    if ! $USE_SUDO; then
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

# ── 4. Start tunnel ──────────────────────────────────────────────
_CF_BIN=$(command -v cloudflared)

if ! $USE_SUDO; then
    echo ""
    echo -e "  ${G}${B}Setup complete! Starting tunnel...${X}"
    echo ""
    if [[ -n "$SSH_HOST" ]]; then
        echo -e "  Browser : ${C}https://$SSH_HOST${X}"
        echo -e "  CLI     : ssh YOUR_USER@$SSH_HOST"
        echo ""
    fi
    info "Tunnel runs in foreground. Press Ctrl+C to stop."
    info "To run in background:  nohup cloudflared tunnel run --token <TOKEN> &"
    info ""
    info "Want it to survive reboots? Re-run with --sudo to install as a service."
    echo ""
    info "ttyd (web terminal) not installed in no-sudo mode."
    info "To install manually:"
    if $IS_MAC; then
        echo "    brew install ttyd"
        echo "    ttyd -W -p 7681 -i 127.0.0.1 /bin/zsh"
    else
        echo "    sudo apt-get install -y ttyd   # or download from GitHub"
        echo "    ttyd -W -p 7681 -i 127.0.0.1 /bin/bash"
    fi
    echo ""
    cloudflared tunnel run --token "$TOKEN"
    info "cloudflared tunnel stopped."
    exit 0
fi

# ── sudo mode: install as system service ──────────────────────────
info "Installing cloudflared tunnel service..."

# Stop any existing service/process first
if pgrep -x cloudflared &>/dev/null; then
    info "Stopping existing cloudflared..."
    if $IS_MAC; then
        sudo launchctl unload /Library/LaunchDaemons/com.cloudflare.cloudflared.plist 2>/dev/null || true
    else
        sudo systemctl stop cloudflared 2>/dev/null || true
    fi
    sleep 2
    # Force kill if still running
    if pgrep -x cloudflared &>/dev/null; then
        sudo pkill -x cloudflared 2>/dev/null || true
        sleep 1
    fi
fi

if $IS_MAC; then
    _PLIST="/Library/LaunchDaemons/com.cloudflare.cloudflared.plist"
    _LOG_DIR="/var/log/cloudflared"
    sudo mkdir -p "$_LOG_DIR"

    sudo tee "$_PLIST" >/dev/null <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.cloudflared</string>
    <key>ProgramArguments</key>
    <array>
        <string>${_CF_BIN}</string>
        <string>tunnel</string>
        <string>run</string>
        <string>--token</string>
        <string>${TOKEN}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${_LOG_DIR}/cloudflared.log</string>
    <key>StandardErrorPath</key>
    <string>${_LOG_DIR}/cloudflared.err</string>
</dict>
</plist>
PLIST

    sudo launchctl load "$_PLIST"
    ok "Service installed (starts on boot + started now)"
    ok "Logs: $_LOG_DIR/cloudflared.log"
else
    if sudo cloudflared service install "$TOKEN" 2>/dev/null; then
        ok "Service installed (starts on boot + started now)"
    else
        info "Reinstalling with current token..."
        sudo cloudflared service uninstall 2>/dev/null || true
        sleep 1
        sudo cloudflared service install "$TOKEN"
        ok "Service reinstalled"
    fi
fi

# ── 5. Verify ─────────────────────────────────────────────────────
info "Waiting for tunnel to connect..."
sleep 5

_tunnel_ok=false
if pgrep -x cloudflared &>/dev/null; then
    if $IS_MAC && [[ -f "/var/log/cloudflared/cloudflared.err" ]]; then
        _last_err=$(tail -3 /var/log/cloudflared/cloudflared.err 2>/dev/null)
        if echo "$_last_err" | grep -qi "not valid\|error\|failed"; then
            err "cloudflared is running but has errors:"
            echo "$_last_err" | sed 's/^/    /'
            echo ""
            err "This usually means the tunnel token is invalid or truncated."
            err "Re-run: sudo ./installers/home_linux_mac.sh --sudo"
        else
            _tunnel_ok=true
        fi
    elif $IS_MAC && [[ -f "/var/log/cloudflared/cloudflared.log" ]]; then
        _tunnel_ok=true
    else
        _tunnel_ok=true
    fi
else
    if $IS_MAC; then
        if [[ -f "/var/log/cloudflared/cloudflared.err" ]]; then
            _last_err=$(tail -3 /var/log/cloudflared/cloudflared.err 2>/dev/null)
            err "cloudflared is not running. Last error:"
            echo "$_last_err" | sed 's/^/    /'
            echo ""
        else
            err "cloudflared is not running."
        fi
        err "Check: sudo launchctl list | grep cloudflare"
        err "Logs:  cat /var/log/cloudflared/cloudflared.err"
    else
        err "cloudflared may not be running -- check: sudo systemctl status cloudflared"
    fi
fi

# ── 6. Install and configure ttyd (web terminal) ─────────────────
info "Setting up ttyd (web terminal)..."

_TTYD_BIN=""
if command -v ttyd &>/dev/null; then
    _TTYD_BIN=$(command -v ttyd)
    ok "ttyd already installed ($_TTYD_BIN)"
else
    info "Installing ttyd..."
    ARCH=$(uname -m)
    if $IS_MAC; then
        if command -v brew &>/dev/null; then
            info "Installing ttyd via brew..."
            HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
                brew install ttyd >/dev/null 2>&1 \
                && ok "Installed ttyd via brew" || true
        fi
        if ! command -v ttyd &>/dev/null; then
            case "$ARCH" in
                x86_64)        _TTYD_ARCH="x86_64" ;;
                aarch64|arm64) _TTYD_ARCH="aarch64" ;;
                *)             err "Unknown arch for ttyd: $ARCH" ;;
            esac
            if [[ -n "${_TTYD_ARCH:-}" ]]; then
                sudo curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${_TTYD_ARCH}" \
                    -o /usr/local/bin/ttyd
                sudo chmod +x /usr/local/bin/ttyd
                ok "ttyd binary installed to /usr/local/bin/"
            fi
        fi
    else
        if command -v apt-get &>/dev/null; then
            sudo apt-get install -y ttyd 2>/dev/null && ok "Installed ttyd via apt" || true
        fi
        if ! command -v ttyd &>/dev/null; then
            case "$ARCH" in
                x86_64)        _TTYD_ARCH="x86_64" ;;
                aarch64|arm64) _TTYD_ARCH="aarch64" ;;
                *)             err "Unknown arch for ttyd: $ARCH" ;;
            esac
            if [[ -n "${_TTYD_ARCH:-}" ]]; then
                sudo curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/ttyd.${_TTYD_ARCH}" \
                    -o /usr/local/bin/ttyd
                sudo chmod +x /usr/local/bin/ttyd
                ok "ttyd binary installed to /usr/local/bin/"
            fi
        fi
    fi
    # Re-detect after install
    command -v ttyd &>/dev/null && _TTYD_BIN=$(command -v ttyd)
fi

if [[ -n "$_TTYD_BIN" ]]; then
    info "Installing ttyd as system service..."

    if $IS_MAC; then
        _TTYD_PLIST="/Library/LaunchDaemons/com.ttyd.terminal.plist"
        _TTYD_PLIST_SRC="$_SCRIPT_DIR/com.ttyd.terminal.plist"

        # Stop existing service
        sudo launchctl unload "$_TTYD_PLIST" 2>/dev/null || true

        if [[ -f "$_TTYD_PLIST_SRC" ]]; then
            # Copy from repo and replace placeholder with detected path
            sudo cp "$_TTYD_PLIST_SRC" "$_TTYD_PLIST"
            sudo sed -i '' "s|__TTYD_BIN__|${_TTYD_BIN}|g" "$_TTYD_PLIST"
        else
            # Generate plist inline
            sudo tee "$_TTYD_PLIST" >/dev/null <<TTYD_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ttyd.terminal</string>
    <key>ProgramArguments</key>
    <array>
        <string>${_TTYD_BIN}</string>
        <string>-W</string>
        <string>-p</string>
        <string>7681</string>
        <string>-i</string>
        <string>127.0.0.1</string>
        <string>/bin/zsh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/var/log/ttyd.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/ttyd.log</string>
</dict>
</plist>
TTYD_PLIST
        fi

        sudo launchctl load "$_TTYD_PLIST"
        ok "ttyd service installed (starts on boot + started now)"
        ok "Logs: /var/log/ttyd.log"
    else
        # Linux: create systemd unit
        sudo tee /etc/systemd/system/ttyd.service >/dev/null <<TTYD_UNIT
[Unit]
Description=ttyd - web terminal
After=network.target

[Service]
Type=simple
ExecStart=${_TTYD_BIN} -W -p 7681 -i 127.0.0.1 /bin/bash
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
TTYD_UNIT

        sudo systemctl daemon-reload
        sudo systemctl enable ttyd
        sudo systemctl restart ttyd
        ok "ttyd service installed (starts on boot + started now)"
    fi

    # Verify ttyd is running
    info "Verifying ttyd is responding..."
    sleep 2
    _ttyd_status=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7681 2>/dev/null || echo "000")
    if [[ "$_ttyd_status" == "200" ]]; then
        ok "ttyd is running on http://127.0.0.1:7681"
    else
        err "ttyd not responding (HTTP $_ttyd_status). Check logs:"
        if $IS_MAC; then
            echo "    cat /var/log/ttyd.log"
        else
            echo "    sudo journalctl -u ttyd -f"
        fi
    fi
else
    err "ttyd could not be installed. Install manually and re-run."
fi

if $_tunnel_ok; then
    ok "cloudflared is running"
    echo ""
    echo "  ================================================"
    echo -e "    ${G}${B}Done!  Home machine is ready.${X}"
    echo "  ================================================"
    echo ""
    if [[ -n "$SSH_HOST" ]]; then
        echo "  Your SSH endpoint: $SSH_HOST"
        echo ""
        echo "  Connect from your work machine:"
        echo "    Browser : https://$SSH_HOST  (email OTP login)"
        echo "    CLI     : ssh YOUR_USER@$SSH_HOST"
    fi
    # Display browser terminal URL from portal_config.json
    _EDGE_SYNC_URL=""
    if [[ -n "$_CFG_FILE" ]]; then
        _EDGE_SYNC_URL=$(_json_val edge_sync_url)
    fi
    if [[ -n "$_EDGE_SYNC_URL" ]]; then
        echo ""
        echo "  Browser terminal: $_EDGE_SYNC_URL"
        echo "    (open from your work machine — no setup needed)"
    fi
    echo ""
    echo "  Service management:"
    if $IS_MAC; then
        echo "    Restart : sudo ./installers/home_linux_mac.sh --restart"
        echo "    Logs    : cat /var/log/cloudflared/cloudflared.log"
        echo "    Stop    : sudo launchctl unload /Library/LaunchDaemons/com.cloudflare.cloudflared.plist"
    else
        echo "    Restart : sudo ./installers/home_linux_mac.sh --restart"
        echo "    Logs    : sudo journalctl -u cloudflared -f"
        echo "    Stop    : sudo systemctl stop cloudflared"
    fi
    echo ""
fi
