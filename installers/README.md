# Installers

Self-contained scripts that set up erebus-edge. No Python or other
dependencies needed -- just bash (macOS/Linux) or cmd (Windows).

## Quick start

### 1. Bootstrap (run once, on any machine)

```bash
# macOS / Linux
./bootstrap.sh --email you@example.com

# Windows
bootstrap.bat --email you@example.com
```

Creates your CF tunnel, Workers, and Zero Trust Access. Prints the exact
commands for the next two steps with your tokens filled in.

### 2. Home machine (the one you SSH into)

```bash
# macOS / Linux
./home_linux_mac.sh --token <TOKEN> --ca-key "<KEY>" --ssh-host <HOST>

# Windows
home_windows.bat --token <TOKEN> --ca-key "<KEY>" --ssh-host <HOST>
```

### 3. Work machine (the one you connect from)

```bash
# macOS / Linux
./work_linux_mac.sh --ssh-host <HOST>

# Windows
work_windows.bat <HOST>
```

## Troubleshooting

### "command not found" or "permission denied"

Shell scripts need the executable bit set. Git preserves this, but some
zip tools or file transfers strip it. Fix:

```bash
chmod +x bootstrap.sh home_linux_mac.sh work_linux_mac.sh
```

Or run with bash directly:

```bash
bash ./bootstrap.sh --email you@example.com
```

### "sudo: a terminal is required to read the password"

You're running in a non-interactive shell (e.g. from an IDE or CI).
Run in a real terminal, or use `--no-sudo` to skip root operations.

### Scripts use `--help`

Every script supports `--help` (or `-h`) to show all available flags:

```bash
./bootstrap.sh --help
./home_linux_mac.sh --help
home_windows.bat --help
```

## What each script does

| Script | Platform | Purpose |
|--------|----------|---------|
| `bootstrap.sh` | macOS/Linux | Full setup wizard: CF auth, tunnel, Workers, Access |
| `bootstrap.bat` | Windows | Same as above, uses PowerShell for HTTP |
| `home_linux_mac.sh` | macOS/Linux | Install cloudflared + tunnel service on home machine |
| `home_windows.bat` | Windows | Same as above, uses DISM for OpenSSH |
| `work_linux_mac.sh` | macOS/Linux | Install cloudflared + SSH config on work machine |
| `work_windows.bat` | Windows | Same as above, works even when GPO blocks PowerShell |

## Where do artifacts go?

Bootstrap writes config and downloaded binaries to `../erebus-temp/`
(a sibling directory outside the repo). This keeps the git repo clean.

```
../erebus-temp/
  keys/portal_config.json   Account IDs, tunnel ID, SSH CA key, etc.
  bin/cloudflared           Downloaded if not already in PATH
  cf_config.txt             SSH host for connect scripts
```

This directory is only used by the bootstrap script (for `--redeploy`
and config persistence). The home/work installers get everything they
need via command-line flags -- they don't read from `../erebus-temp/`.

No secrets are stored in the repo. Tokens are passed as arguments.
The CF API token is stored in your platform's credential store
(macOS Keychain / Linux file 0600 / Windows DPAPI).
