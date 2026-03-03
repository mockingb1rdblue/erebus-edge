@echo off
setlocal enabledelayedexpansion
REM ═══════════════════════════════════════════════════════════════════
REM  erebus-edge -- WORK machine setup for Windows
REM  Run this on the machine you connect FROM (your work/office machine).
REM  Pure batch -- works even when PowerShell is blocked by GPO.
REM  No admin needed. Downloads cloudflared to your user directory.
REM
REM  Usage:
REM    work_windows.bat <SSH_HOST>
REM
REM  Example:
REM    work_windows.bat ssh.myname.workers.dev
REM
REM  Double-click or run from cmd.
REM  bootstrap.py prints the exact command with your host.
REM ═══════════════════════════════════════════════════════════════════

set "SSH_HOST=%~1"

if "%SSH_HOST%"=="" (
    echo.
    echo   Usage: work_windows.bat ^<SSH_HOST^>
    echo.
    echo   Example: work_windows.bat ssh.myname.workers.dev
    echo.
    echo   Run "python src\bootstrap.py" first -- it prints the exact command.
    echo.
    pause
    exit /b 1
)

set "INSTALL_DIR=%LOCALAPPDATA%\erebus-edge"

echo.
echo   ================================================
echo     erebus-edge -- Work Machine Setup (Windows)
echo   ================================================
echo.

if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%"

REM ── 1. Download cloudflared (portable, no admin) ────────────────
set "CF_PATH=%INSTALL_DIR%\cloudflared.exe"

where cloudflared >nul 2>&1
if !errorlevel! equ 0 (
    echo   [OK]  cloudflared already in PATH
    for /f "delims=" %%i in ('where cloudflared') do set "CF_PATH=%%i"
    goto :cf_done
)
if exist "%CF_PATH%" (
    echo   [OK]  cloudflared already at %CF_PATH%
    goto :cf_done
)

echo   [..]  Downloading cloudflared...
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
echo   [!!]  Could not download cloudflared automatically.
echo         Download manually from:
echo           %CF_URL%
echo         Save to: %CF_PATH%
goto :cf_done

:cf_done

REM ── 2. Create connect.bat ───────────────────────────────────────
set "CONNECT=%INSTALL_DIR%\connect.bat"
(
    echo @echo off
    echo set /p RUSER=Username on remote host:
    echo ssh -o "ProxyCommand=""%CF_PATH%"" access ssh --hostname %SSH_HOST%" %%RUSER%%@%SSH_HOST%
) > "%CONNECT%"
echo   [OK]  Created %CONNECT%

REM ── 3. SSH config entry ─────────────────────────────────────────
set "SSH_DIR=%USERPROFILE%\.ssh"
set "SSH_CFG=%SSH_DIR%\config"
if not exist "%SSH_DIR%" mkdir "%SSH_DIR%"

if exist "%SSH_CFG%" (
    findstr /C:"%SSH_HOST%" "%SSH_CFG%" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK]  SSH config already has %SSH_HOST% entry
        goto :ssh_done
    )
)

echo.>> "%SSH_CFG%"
echo # erebus-edge -- CF Tunnel SSH>> "%SSH_CFG%"
echo Host %SSH_HOST%>> "%SSH_CFG%"
echo     ProxyCommand "%CF_PATH%" access ssh --hostname %%h>> "%SSH_CFG%"
echo     StrictHostKeyChecking no>> "%SSH_CFG%"
echo     UserKnownHostsFile NUL>> "%SSH_CFG%"
echo   [OK]  Added SSH config entry for %SSH_HOST%
echo   [..]  Connect with:  ssh YOUR_USER@%SSH_HOST%

:ssh_done

echo.
echo   ================================================
echo     Done!  Work machine is ready.
echo   ================================================
echo.
echo   Connect to your home machine:
echo     Browser : https://%SSH_HOST%  (email OTP login)
echo     CLI     : ssh YOUR_USER@%SSH_HOST%
echo     Script  : %CONNECT%
echo.
endlocal
