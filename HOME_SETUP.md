# Home machine setup (macOS)

## Before you start

1. **Enable Remote Login** (SSH server):
   - System Settings → General → Sharing → Remote Login → ON
   - Make sure your user is in the allowed users list

2. **Verify SSH works locally** (quick sanity check):
   ```bash
   ssh $(whoami)@localhost
   ```
   If this doesn't work, the tunnel won't help. Fix SSH first.

---

## Step 1: Pull the repo

```bash
cd ~/Documents  # or wherever you want it
git clone https://github.com/YOUR_USER/erebus-edge.git
cd erebus-edge
```

If you already cloned it:
```bash
cd erebus-edge && git pull
```

---

## Step 2: Run bootstrap

```bash
./installers/bootstrap.sh --email YOUR_EMAIL@example.com
```

Replace with the email you want for login OTP codes.

The wizard will:
1. Open your browser to create a CF API token — follow the on-screen steps
2. Create a tunnel
3. Create DNS records
4. Set up Zero Trust Access (email OTP + browser SSH)

Everything saves to `../erebus-temp/` (outside the repo).

---

## Step 3: Install tunnel service

```bash
./installers/home_linux_mac.sh --sudo
```

This installs a LaunchDaemon so the tunnel survives reboots. Needs `sudo`.

---

## Step 4: Install web terminal (ttyd)

```bash
brew install ttyd
sudo cp installers/com.ttyd.terminal.plist /Library/LaunchDaemons/
sudo launchctl load /Library/LaunchDaemons/com.ttyd.terminal.plist
```

Verify it's running:
```bash
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:7681
# Should print: 200
```

---

## Step 5: Verify

```bash
# Check tunnel is running
sudo launchctl list | grep cloudflared

# Check ttyd is running
pgrep -fl ttyd

# Check it responds
curl -s http://localhost:7681 | head -1
# Should print: <!DOCTYPE html>
```

Then from any browser, open your `edge-sync` Workers URL
(printed at the end of bootstrap). You should see a terminal.

---

## Troubleshooting

**"Connection refused" in browser terminal:**
- ttyd isn't running: `pgrep -fl ttyd`
- Restart: `sudo launchctl kickstart -k system/com.ttyd.terminal`

**Can see terminal but can't type:**
- ttyd was started without `-W` flag. Check: `pgrep -fl ttyd`
- If it shows `login` instead of `/bin/zsh`, the plist is outdated.
- Fix: unload, copy updated plist, reload.

**Tunnel not connecting:**
- Check: `sudo launchctl list | grep cloudflared`
- Restart: `sudo launchctl kickstart -k system/com.cloudflare.cloudflared`
- Logs: `cat /var/log/cloudflared/cloudflared.log`

**DNS doesn't resolve (`nslookup ssh.yourdomain.com`):**
- Wait a few minutes for propagation
- Check CF Dashboard → DNS for the CNAME record

**OTP email never arrives:**
- Check spam. CF sends from `noreply@notify.cloudflare.com`
