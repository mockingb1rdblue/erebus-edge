#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# connect.sh  –  SSH to home via Cloudflare Tunnel (Git Bash / bash version)
# SSH key stored DPAPI-encrypted (tied to your Windows login, not plaintext).
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/bin"
KEYS_DIR="$SCRIPT_DIR/keys"
KEY_ENC="$KEYS_DIR/home_key.dpapi"
KEY_PUB="$KEYS_DIR/home_key.pub"
CF_HOST="ssh.mock1ng.workers.dev"
CFG="$SCRIPT_DIR/cf_config.txt"

# ── load saved config ──────────────────────────────────────────────────────────
[[ -f "$CFG" ]] && source <(grep -E '^[A-Z_]+=\S' "$CFG" | sed 's/=/ /1' | awk '{print $1"="$2}')

# ── first-run: ask for username ────────────────────────────────────────────────
if [[ -z "${HOME_USER:-}" ]]; then
    read -rp "Home machine username: " HOME_USER
    read -rp "SSH port on home machine [22]: " SSH_PORT
    SSH_PORT="${SSH_PORT:-22}"
    printf 'HOME_USER=%s\nSSH_PORT=%s\n' "$HOME_USER" "$SSH_PORT" > "$CFG"
    echo "[saved to cf_config.txt]"
fi
SSH_PORT="${SSH_PORT:-22}"

# ── DPAPI helpers (call PowerShell from Git Bash) ─────────────────────────────
dpapi_encrypt() {
    local src="$1" dst="$2"
    powershell.exe -NoProfile -Command "
        Add-Type -AssemblyName System.Security
        \$b = [IO.File]::ReadAllBytes('$(cygpath -w "$src")')
        \$e = [Security.Cryptography.ProtectedData]::Protect(\$b, \$null, 'CurrentUser')
        [IO.File]::WriteAllBytes('$(cygpath -w "$dst")', \$e)
    " 2>/dev/null
}

dpapi_decrypt_to_tmp() {
    local src="$1"
    powershell.exe -NoProfile -Command "
        Add-Type -AssemblyName System.Security
        try {
            \$e = [IO.File]::ReadAllBytes('$(cygpath -w "$src")')
            \$d = [Security.Cryptography.ProtectedData]::Unprotect(\$e, \$null, 'CurrentUser')
            \$t = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllBytes(\$t, \$d)
            \$t
        } catch { '' }
    " 2>/dev/null | tr -d '\r'
}

# ── SSH key setup ──────────────────────────────────────────────────────────────
mkdir -p "$KEYS_DIR"

if [[ ! -f "$KEY_ENC" ]]; then
    echo ""
    echo "No SSH key found."
    echo "  1. Generate new key + auto-install on home  (password auth once)"
    echo "  2. Paste from clipboard"
    echo "  3. Import from file"
    echo "  4. Skip - use password auth every time"
    echo ""
    read -rp "Choice [1/2/3/4]: " KEY_CHOICE
    echo ""

    PLAIN_TMP="$KEYS_DIR/home_key.tmp"

    case "$KEY_CHOICE" in
        1)
            ssh-keygen -t ed25519 -f "$PLAIN_TMP" -N "" -C "cf-portable"
            cp "$PLAIN_TMP.pub" "$KEY_PUB"
            echo ""
            echo "[key generated - connecting to install on home machine...]"
            echo "Enter your home machine password when prompted."
            echo ""
            ssh \
                -o "ProxyCommand='$BIN/cloudflared.exe' access ssh --hostname $CF_HOST" \
                -o "StrictHostKeyChecking=accept-new" \
                -p "$SSH_PORT" \
                "${HOME_USER}@${CF_HOST}" \
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
                < "$KEY_PUB"
            if [[ $? -eq 0 ]]; then
                echo ""
                echo "[public key installed - future logins will use the key]"
            else
                echo ""
                echo "[auto-install failed - add manually:]"
                cat "$KEY_PUB"
            fi
            echo ""
            ;;
        2)
            CLIP=$(powershell.exe -NoProfile -Command "Get-Clipboard" 2>/dev/null | tr -d '\r')
            if [[ -n "$CLIP" ]]; then
                printf '%s\n' "$CLIP" > "$PLAIN_TMP"
            else
                echo "[clipboard empty or could not read - skipping]"
            fi
            ;;
        3)
            read -rp "Path to private key: " KEY_SRC
            cp "$KEY_SRC" "$PLAIN_TMP"
            ;;
    esac

    # DPAPI-encrypt and delete plaintext
    if [[ -f "$PLAIN_TMP" ]]; then
        dpapi_encrypt "$PLAIN_TMP" "$KEY_ENC"
        rm -f "$PLAIN_TMP"
        echo "[key encrypted with DPAPI - no plaintext stored]"
        echo ""
    fi
fi

# ── decrypt key to temp for this session ──────────────────────────────────────
TMP_KEY=""
if [[ -f "$KEY_ENC" ]]; then
    TMP_KEY_WIN=$(dpapi_decrypt_to_tmp "$KEY_ENC")
    if [[ -n "$TMP_KEY_WIN" ]]; then
        TMP_KEY=$(cygpath -u "$TMP_KEY_WIN" 2>/dev/null || echo "$TMP_KEY_WIN")
    fi
fi

# ── connect ────────────────────────────────────────────────────────────────────
echo ""
echo "Connecting to home via Cloudflare Tunnel..."
echo "  Endpoint : $CF_HOST  (direct - no corporate proxy)"
echo "  User     : $HOME_USER"
if [[ -n "$TMP_KEY" ]]; then
    echo "  Key      : DPAPI-encrypted (temp file, deleted after connect)"
else
    echo "  Key      : none - password auth"
fi
echo ""
echo "Tip: once connected, run:  tmux new -A -s work"
echo ""

KEY_OPT=()
[[ -n "$TMP_KEY" ]] && KEY_OPT=(-i "$TMP_KEY")

ssh \
    -o "ProxyCommand='$BIN/cloudflared.exe' access ssh --hostname $CF_HOST" \
    -o "StrictHostKeyChecking=accept-new" \
    -o "ServerAliveInterval=30" \
    -o "ServerAliveCountMax=3" \
    "${KEY_OPT[@]}" \
    -p "$SSH_PORT" \
    "${HOME_USER}@${CF_HOST}"

# clean up decrypted temp key
[[ -n "$TMP_KEY" ]] && rm -f "$TMP_KEY"
