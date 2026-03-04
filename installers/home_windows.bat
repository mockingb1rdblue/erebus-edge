@echo off
setlocal enabledelayedexpansion
REM ═══════════════════════════════════════════════════════════════════
REM  erebus-edge -- HOME machine setup for Windows
REM  Run this on the machine you want to SSH INTO (your home server).
REM  Pure batch -- works even when PowerShell is blocked by GPO.
REM
REM  Usage:
REM    home_windows.bat --token <TOKEN> [--ca-key <KEY>] [--ssh-host <HOST>]
REM    home_windows.bat --no-admin --token <TOKEN> [--ssh-host <HOST>]
REM
REM  By default: asks whether to do Quick start (no admin) or Full setup.
REM  bootstrap.sh / bootstrap.bat prints the exact command with your token.
REM ═══════════════════════════════════════════════════════════════════

set "TOKEN="
set "SSH_CA_KEY="
set "SSH_HOST="
set "FORCE_ADMIN="
set "FORCE_NO_ADMIN="

REM ── Parse arguments ──────────────────────────────────────────────
:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--token"    ( set "TOKEN=%~2"      & shift & shift & goto :parse_args )
if /i "%~1"=="--ca-key"   ( set "SSH_CA_KEY=%~2"  & shift & shift & goto :parse_args )
if /i "%~1"=="--ssh-host" ( set "SSH_HOST=%~2"    & shift & shift & goto :parse_args )
if /i "%~1"=="--admin"    ( set "FORCE_ADMIN=1"   & shift & goto :parse_args )
if /i "%~1"=="--no-admin" ( set "FORCE_NO_ADMIN=1" & shift & goto :parse_args )
if /i "%~1"=="--help"     goto :show_help
if /i "%~1"=="-h"         goto :show_help
REM Legacy positional args: TOKEN [CA_KEY] [HOST]
if "%TOKEN%"=="" ( set "TOKEN=%~1" & shift & goto :parse_args )
if "%SSH_CA_KEY%"=="" ( set "SSH_CA_KEY=%~1" & shift & goto :parse_args )
if "%SSH_HOST%"=="" ( set "SSH_HOST=%~1" & shift & goto :parse_args )
shift
goto :parse_args

:show_help
echo.
echo   Usage:
echo     home_windows.bat --token ^<TOKEN^> [OPTIONS]
echo.
echo   Required:
echo     --token ^<TOKEN^>       Cloudflare Tunnel token (from bootstrap output)
echo.
echo   Options:
echo     --ca-key ^<KEY^>        SSH CA public key for short-lived certificates
echo     --ssh-host ^<HOST^>     Your SSH hostname (e.g. ssh.you.workers.dev)
echo     --admin               Run in full system mode (install service, configure sshd)
echo     --no-admin            Run in user mode (no admin rights needed)
echo     --help, -h            Show this help
echo.
echo   Default behavior (no admin):
echo     - Installs cloudflared to %%USERPROFILE%%\.local\bin\
echo     - Runs the tunnel in the foreground (Ctrl+C to stop)
echo     - Prints SSH CA trust commands for you to run manually
echo     - No system files are modified
echo.
echo   With admin (full system setup):
echo     1. Installs/enables OpenSSH Server
echo     2. Installs cloudflared to Program Files
echo     3. Registers cloudflared as a Windows service (auto-starts on boot)
echo     4. Writes SSH CA key to %%ProgramData%%\ssh\ca.pub
echo     5. Adds TrustedUserCAKeys to sshd_config
echo     6. Restarts sshd service
echo.
exit /b 0

:args_done

REM ── Auto-read config from bootstrap output if flags not provided ──
set "_CFG_FILE="
if exist "%~dp0..\erebus-temp\keys\portal_config.json" set "_CFG_FILE=%~dp0..\erebus-temp\keys\portal_config.json"
if "%_CFG_FILE%"=="" if exist "%~dp0..\..\erebus-temp\keys\portal_config.json" set "_CFG_FILE=%~dp0..\..\erebus-temp\keys\portal_config.json"

if not "%_CFG_FILE%"=="" (
    REM Use PowerShell to read JSON values (only if PowerShell available)
    for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content '%_CFG_FILE%' | ConvertFrom-Json).tunnel_token" 2^>nul`) do (
        if "%TOKEN%"=="" set "TOKEN=%%v"
    )
    for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content '%_CFG_FILE%' | ConvertFrom-Json).ssh_ca_public_key" 2^>nul`) do (
        if "%SSH_CA_KEY%"=="" set "SSH_CA_KEY=%%v"
    )
    for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content '%_CFG_FILE%' | ConvertFrom-Json).ssh_host" 2^>nul`) do (
        if "%SSH_HOST%"=="" set "SSH_HOST=%%v"
    )
    if not "%TOKEN%"=="" (
        echo.
        echo   Auto-loaded config from: %_CFG_FILE%
    )
)

if "%TOKEN%"=="" (
    echo.
    echo   Usage: home_windows.bat [--admin] [--token ^<TOKEN^>] [--ca-key ^<KEY^>] [--ssh-host ^<HOST^>]
    echo.
    echo   If you ran bootstrap.bat from this repo, just run:
    echo     installers\home_windows.bat
    echo.
    echo   It auto-reads the token, SSH CA key, and host from ..\erebus-temp\.
    echo   Use --help for all options.
    echo.
    pause
    exit /b 1
)

REM ── Determine admin mode ─────────────────────────────────────────
set "USE_ADMIN=0"

if defined FORCE_NO_ADMIN goto :mode_decided
if defined FORCE_ADMIN ( set "USE_ADMIN=1" & goto :mode_decided )

REM Check if running as admin
net session >nul 2>&1
if !errorlevel! equ 0 (
    REM Already admin -- honour it
    set "USE_ADMIN=1"
    goto :mode_decided
)

REM Interactive: ask the user
echo.
echo   Choose setup mode:
echo.
echo   [1] Quick start (default, no admin needed)
echo       Installs cloudflared to %%USERPROFILE%%\.local\bin\
echo       Runs tunnel in foreground (stops when window closes)
echo       SSH CA trust: prints commands for you to run manually
echo.
echo   [2] Full system setup (requires Run as Administrator)
echo       Installs cloudflared system-wide
echo       Registers as a Windows service (auto-starts on boot)
echo       Configures SSH CA trust in sshd_config automatically
echo       Installs/enables OpenSSH Server
echo.
set /p "MODE_CHOICE=  Choice [1/2]: "
if "%MODE_CHOICE%"=="2" (
    REM Check if actually admin
    net session >nul 2>&1
    if !errorlevel! neq 0 (
        echo.
        echo   [!!]  Not running as Administrator.
        echo         Right-click this file -^> Run as Administrator, or use --no-admin.
        echo.
        pause
        exit /b 1
    )
    set "USE_ADMIN=1"
)

:mode_decided

echo.
echo   ================================================
echo     erebus-edge -- Home Machine Setup (Windows)
if "%USE_ADMIN%"=="1" (
    echo     Mode: Full system setup (admin)
) else (
    echo     Mode: Quick start (no admin)
)
echo   ================================================
echo.

REM ── 1. Ensure OpenSSH Server is running ──────────────────────────
if "%USE_ADMIN%"=="0" (
    echo   [..]  Skipping SSH server check (no-admin mode)
    echo   [..]  Make sure OpenSSH Server is enabled:
    echo         Settings -^> Apps -^> Optional Features -^> OpenSSH Server
    goto :ssh_done
)

echo   [..]  Checking OpenSSH Server...
sc query sshd >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  OpenSSH Server service exists
) else (
    echo   [..]  Installing OpenSSH Server via DISM...
    dism /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 /NoRestart >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK]  OpenSSH Server installed
    ) else (
        echo   [!!]  DISM install failed -- install OpenSSH Server manually
        echo         Settings -^> Apps -^> Optional Features -^> OpenSSH Server
    )
)
net start sshd >nul 2>&1
sc config sshd start=auto >nul 2>&1
echo   [OK]  sshd service running (auto-start enabled)

:ssh_done

REM ── 2. Install cloudflared ───────────────────────────────────────
if "%USE_ADMIN%"=="0" (
    set "CF_DIR=%USERPROFILE%\.local\bin"
) else (
    set "CF_DIR=%ProgramFiles%\cloudflared"
)
set "CF_PATH=!CF_DIR!\cloudflared.exe"

where cloudflared >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  cloudflared already in PATH
    for /f "delims=" %%i in ('where cloudflared') do set "CF_PATH=%%i"
    goto :cf_done
)
if exist "!CF_PATH!" (
    echo   [OK]  cloudflared found at !CF_PATH!
    goto :cf_done
)

echo   [..]  Downloading cloudflared to !CF_DIR!...
if not exist "!CF_DIR!" mkdir "!CF_DIR!"
set "CF_URL=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"

REM Try curl first (Windows 10 1803+), then certutil, then bitsadmin
curl.exe -fsSL -o "!CF_PATH!" "%CF_URL%" 2>nul
if exist "!CF_PATH!" (
    echo   [OK]  cloudflared downloaded via curl
    goto :cf_done
)
certutil -urlcache -split -f "%CF_URL%" "!CF_PATH!" >nul 2>&1
if exist "!CF_PATH!" (
    echo   [OK]  cloudflared downloaded via certutil
    goto :cf_done
)
bitsadmin /transfer cf /download /priority high "%CF_URL%" "!CF_PATH!" >nul 2>&1
if exist "!CF_PATH!" (
    echo   [OK]  cloudflared downloaded via bitsadmin
    goto :cf_done
)
echo   [!!]  Could not download cloudflared. Download manually:
echo         %CF_URL%
echo         Place at: !CF_PATH!
goto :cf_done

:cf_done

REM ── 3. SSH CA trust (short-lived certificates) ───────────────────
REM Do this BEFORE starting tunnel (no-admin mode blocks in foreground)
if "%SSH_CA_KEY%"=="" (
    echo   [..]  No SSH CA key -- short-lived certs not configured
    goto :ca_done
)

if "%USE_ADMIN%"=="0" (
    echo   [..]  SSH CA trust requires admin to modify sshd_config.
    echo   [..]  To configure manually, run as Administrator:
    echo.
    echo         echo %SSH_CA_KEY% ^> "%ProgramData%\ssh\ca.pub"
    echo         echo TrustedUserCAKeys %ProgramData%\ssh\ca.pub ^>^> "%ProgramData%\ssh\sshd_config"
    echo         net stop sshd ^& net start sshd
    echo.
    goto :ca_done
)

echo   [..]  Configuring sshd to trust CF SSH CA...
set "SSH_DIR=%ProgramData%\ssh"
set "CA_PATH=%SSH_DIR%\ca.pub"
set "SSHD_CFG=%SSH_DIR%\sshd_config"

echo %SSH_CA_KEY%> "%CA_PATH%"
echo   [OK]  CA key written to %CA_PATH%

if not exist "%SSHD_CFG%" (
    echo   [!!]  sshd_config not found at %SSHD_CFG%
    goto :ca_done
)

findstr /C:"TrustedUserCAKeys" "%SSHD_CFG%" >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  sshd_config already has TrustedUserCAKeys
) else (
    echo.>> "%SSHD_CFG%"
    echo # Cloudflare Access short-lived SSH certificates>> "%SSHD_CFG%"
    echo TrustedUserCAKeys %CA_PATH%>> "%SSHD_CFG%"
    echo   [OK]  TrustedUserCAKeys added to sshd_config
)

net stop sshd >nul 2>&1
net start sshd >nul 2>&1
echo   [OK]  sshd restarted with CF CA trust

:ca_done

REM ── 4. Start tunnel ──────────────────────────────────────────────
if "%USE_ADMIN%"=="0" (
    echo.
    echo   ================================================
    echo     Setup complete! Starting tunnel...
    echo   ================================================
    echo.
    if not "%SSH_HOST%"=="" (
        echo   Browser : https://%SSH_HOST%
        echo   CLI     : ssh YOUR_USER@%SSH_HOST%
        echo.
    )
    echo   [..]  Tunnel runs in foreground. Press Ctrl+C to stop.
    echo   [..]  To run in background, use admin mode (--admin) for a Windows service.
    echo.
    "!CF_PATH!" tunnel run --token %TOKEN%
    echo   [..]  cloudflared tunnel stopped.
    goto :eof
)

echo   [..]  Installing cloudflared tunnel service...
"!CF_PATH!" service install %TOKEN% >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  cloudflared service installed
) else (
    REM May already be installed -- try uninstall + reinstall
    "!CF_PATH!" service uninstall >nul 2>&1
    timeout /t 2 /nobreak >nul
    "!CF_PATH!" service install %TOKEN% >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK]  cloudflared service reinstalled
    ) else (
        echo   [!!]  Service install failed -- ensure running as Administrator
    )
)

REM ── 5. Verify (admin mode only) ─────────────────────────────────
echo   [..]  Waiting for tunnel...
timeout /t 5 /nobreak >nul
sc query cloudflared | findstr /C:"RUNNING" >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  cloudflared is running
) else (
    echo   [!!]  cloudflared may not be running -- check: sc query cloudflared
)

echo.
echo   ================================================
echo     Done!  Home machine is ready.
echo   ================================================
echo.
echo   Now run the WORK machine installer on the machine
echo   you connect FROM.
if not "%SSH_HOST%"=="" (
    echo     Browser : https://%SSH_HOST%
    echo     CLI     : ssh YOUR_USER@%SSH_HOST%
)
echo.
endlocal
