# Home machine setup (Mac Mini)

## Before you start

1. **Enable Remote Login** (SSH server):
   - System Settings -> General -> Sharing -> Remote Login -> ON
   - Make sure your user (`mock1ng`) is in the allowed users list

2. **Verify SSH works locally** (quick sanity check):
   ```bash
   ssh mock1ng@localhost
   ```
   If this doesn't work, the tunnel won't help. Fix SSH first.

---

## Step 1: Pull the repo

```bash
cd ~/Documents  # or wherever you want it
git clone https://github.com/mockingb1rdblue/erebus-edge.git
cd erebus-edge
```

If you already cloned it before:
```bash
cd erebus-edge
git pull
```

---

## Step 2: Run bootstrap

```bash
./installers/bootstrap.sh --domain mock1ngbb.com --email YOUR_EMAIL@example.com
```

Replace `YOUR_EMAIL@example.com` with the email you want for login OTP codes.

The wizard will:
1. Open CF Dashboard to create an API token -- follow the on-screen steps
2. Create a tunnel named `home-ssh`
3. Create DNS: `ssh.mock1ngbb.com` -> tunnel (proxied through CF)
4. Set up Zero Trust Access (email OTP + browser SSH)

Everything saves to `../erebus-temp/` (outside the repo).

---

## Step 3: Install tunnel service

```bash
./installers/home_linux_mac.sh
```

Pick **Boot service** when prompted -- this installs a LaunchDaemon so the
tunnel survives reboots. Needs `sudo` (it'll ask for your password).

Or skip the prompt:
```bash
./installers/home_linux_mac.sh --sudo
```

---

## Step 4: Verify

```bash
# Check tunnel is running
sudo launchctl list | grep cloudflared

# Check it's connected to CF
curl -s http://localhost:45679/ready 2>/dev/null && echo "Tunnel healthy" || echo "Tunnel not responding"
```

Then from any browser (phone works too), go to:

```
https://ssh.mock1ngbb.com
```

1. Enter your email -> get OTP code -> enter code
2. Browser SSH terminal should appear
3. Log in as `mock1ng`

If the terminal appears and you can type commands, you're done.

---

## Troubleshooting

**"Connection refused" in browser terminal:**
- Remote Login is off. Enable it in System Settings.

**Browser shows CF error page (502/504):**
- Tunnel isn't running. Check: `sudo launchctl list | grep cloudflared`
- Restart it: `sudo launchctl kickstart -k system/com.cloudflare.cloudflared`

**DNS doesn't resolve (`nslookup ssh.mock1ngbb.com`):**
- Wait a few minutes for propagation, or check CF Dashboard -> DNS for the CNAME record.

**OTP email never arrives:**
- Check spam. CF sends from `noreply@notify.cloudflare.com`.
- Make sure the email matches what you passed to `--email`.

**Everything works from phone but not from work:**
- Corporate proxy may be blocking the custom domain. Test: `curl -I https://ssh.mock1ngbb.com` from work Git Bash.
- If blocked, we'll need to investigate proxy bypass options.
