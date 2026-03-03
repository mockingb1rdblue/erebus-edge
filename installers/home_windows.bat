@echo off
setlocal enabledelayedexpansion
REM ═══════════════════════════════════════════════════════════════════
REM  erebus-edge -- HOME machine setup for Windows
REM  Run this on the machine you want to SSH INTO (your home server).
REM  Pure batch -- works even when PowerShell is blocked by GPO.
REM
REM  Usage:
REM    home_windows.bat <TUNNEL_TOKEN> [SSH_CA_PUBLIC_KEY] [SSH_HOST]
REM
REM  Right-click -> Run as Administrator
REM  bootstrap.py prints the exact command with your token.
REM ═══════════════════════════════════════════════════════════════════

set "TOKEN=%~1"
set "SSH_CA_KEY=%~2"
set "SSH_HOST=%~3"

if "%TOKEN%"=="" (
    echo.
    echo   Usage: home_windows.bat ^<TUNNEL_TOKEN^> [SSH_CA_PUBLIC_KEY] [SSH_HOST]
    echo.
    echo   Run "python src\bootstrap.py" first -- it prints the exact command.
    echo.
    pause
    exit /b 1
)

echo.
echo   ================================================
echo     erebus-edge -- Home Machine Setup (Windows)
echo   ================================================
echo.

REM ── 1. Ensure OpenSSH Server is installed + running ─────────────
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

REM ── 2. Download cloudflared ─────────────────────────────────────
set "CF_DIR=%ProgramFiles%\cloudflared"
set "CF_PATH=%CF_DIR%\cloudflared.exe"

where cloudflared >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  cloudflared already in PATH
    for /f "delims=" %%i in ('where cloudflared') do set "CF_PATH=%%i"
    goto :cf_done
)
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared found at %CF_PATH%
    goto :cf_done
)

echo   [..]  Downloading cloudflared...
if not exist "%CF_DIR%" mkdir "%CF_DIR%"
set "CF_URL=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"

REM Try curl first (Windows 10 1803+), then certutil, then bitsadmin
curl.exe -fsSL -o "%CF_PATH%" "%CF_URL%" 2>nul
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared downloaded via curl
    goto :cf_done
)
certutil -urlcache -split -f "%CF_URL%" "%CF_PATH%" >nul 2>&1
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared downloaded via certutil
    goto :cf_done
)
bitsadmin /transfer cf /download /priority high "%CF_URL%" "%CF_PATH%" >nul 2>&1
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared downloaded via bitsadmin
    goto :cf_done
)
echo   [!!]  Could not download cloudflared. Download manually:
echo         %CF_URL%
echo         Place at: %CF_PATH%
goto :cf_done

:cf_done

REM ── 3. Install tunnel service ───────────────────────────────────
echo   [..]  Installing cloudflared tunnel service...
"%CF_PATH%" service install %TOKEN% >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  cloudflared service installed
) else (
    REM May already be installed -- try uninstall + reinstall
    "%CF_PATH%" service uninstall >nul 2>&1
    timeout /t 2 /nobreak >nul
    "%CF_PATH%" service install %TOKEN% >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK]  cloudflared service reinstalled
    ) else (
        echo   [!!]  Service install failed -- ensure running as Administrator
    )
)

REM ── 4. SSH CA trust (short-lived certificates) ──────────────────
if "%SSH_CA_KEY%"=="" (
    echo   [..]  No SSH CA key -- short-lived certs not configured
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

REM ── 5. Verify ───────────────────────────────────────────────────
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
