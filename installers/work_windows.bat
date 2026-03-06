@echo off
setlocal enabledelayedexpansion
REM ═══════════════════════════════════════════════════════════════════
REM  erebus-edge -- WORK machine setup for Windows
REM  Run this on the machine you connect FROM (your work/office machine).
REM  Pure batch -- works even when PowerShell is blocked by GPO.
REM  No admin needed. Downloads cloudflared to your user directory.
REM
REM  Usage:
REM    work_windows.bat                              (auto-reads config)
REM    work_windows.bat --ssh-host ssh.yourdomain.com   (skip prompt)
REM    work_windows.bat ssh.yourdomain.com              (positional)
REM
REM  If bootstrap was run on this machine, just double-click -- no args needed.
REM ═══════════════════════════════════════════════════════════════════

set "SSH_HOST="

REM ── Parse arguments ───────────────────────────────────────────
:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--ssh-host" ( set "SSH_HOST=%~2" & shift & shift & goto :parse_args )
if /i "%~1"=="-ssh-host"  ( set "SSH_HOST=%~2" & shift & shift & goto :parse_args )
if /i "%~1"=="--help"     goto :show_help
if /i "%~1"=="-help"      goto :show_help
if /i "%~1"=="-h"         goto :show_help
REM Legacy positional arg
if "%SSH_HOST%"=="" ( set "SSH_HOST=%~1" & shift & goto :parse_args )
shift
goto :parse_args

:show_help
echo.
echo   Usage:
echo     work_windows.bat                                  (auto-reads config)
echo     work_windows.bat --ssh-host ^<HOST^>                (skip prompt)
echo     work_windows.bat ^<HOST^>                           (positional)
echo.
echo   Options:
echo     --ssh-host ^<HOST^>    Your SSH hostname (e.g. ssh.yourdomain.com)
echo     --help, -h           Show this help
echo.
echo   If you ran bootstrap on this machine, just double-click with no arguments.
echo   The script auto-reads your SSH host from the bootstrap config.
echo.
exit /b 0

:args_done

REM ── Auto-read config from bootstrap output if not provided ────
set "_CFG_FILE="
if exist "%~dp0..\erebus-temp\keys\portal_config.json" set "_CFG_FILE=%~dp0..\erebus-temp\keys\portal_config.json"
if "%_CFG_FILE%"=="" if exist "%~dp0..\..\erebus-temp\keys\portal_config.json" set "_CFG_FILE=%~dp0..\..\erebus-temp\keys\portal_config.json"
REM Check keys/ inside repo (legacy location)
if "%_CFG_FILE%"=="" if exist "%~dp0..\keys\portal_config.json" set "_CFG_FILE=%~dp0..\keys\portal_config.json"

if not "%_CFG_FILE%"=="" if "%SSH_HOST%"=="" (
    REM Try PowerShell first for JSON parsing
    for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content '%_CFG_FILE%' | ConvertFrom-Json).ssh_host" 2^>nul`) do (
        set "SSH_HOST=%%v"
    )
    REM Fallback: simple findstr extraction if PowerShell is blocked
    if "!SSH_HOST!"=="" (
        for /f "tokens=2 delims=:," %%v in ('findstr /C:"ssh_host" "%_CFG_FILE%" 2^>nul') do (
            set "_RAW=%%v"
            REM Strip quotes and spaces
            set "_RAW=!_RAW: =!"
            set "_RAW=!_RAW:"=!"
            set "SSH_HOST=!_RAW!"
        )
    )
    if not "!SSH_HOST!"=="" (
        echo.
        echo   Auto-loaded config from: %_CFG_FILE%
    )
)

REM ── Interactive prompt if still missing ───────────────────────
if "%SSH_HOST%"=="" (
    echo.
    echo   +-----------------------------------------------------------+
    echo   ^|  SSH host not found -- let's set it up.                   ^|
    echo   +-----------------------------------------------------------+
    echo.
    echo   Your SSH host looks like:  ssh.yourdomain.com
    echo.
    echo   Where to find it:
    echo     1. If you ran bootstrap, it printed your endpoints at the end.
    echo        Look for the line:  Browser SSH : https://ssh.XXXX.com
    echo.
    echo     2. If someone else set this up for you, ask them for the SSH
    echo        host -- they'll have it from their bootstrap output.
    echo.
    echo     3. If you ran the home/server installer, it showed your SSH
    echo        host in the banner at the top and the summary at the end.
    echo.
    echo     4. You can also find it in the Cloudflare dashboard:
    echo        dash.cloudflare.com -^> DNS -^> look for a CNAME record named 'ssh'
    echo        The full hostname is: ssh.yourdomain.com
    echo.
    set /p "SSH_HOST=  Paste your SSH host here: "
    echo.
)

if "%SSH_HOST%"=="" (
    echo.
    echo   Could not determine SSH host.
    echo.
    echo   If you ran bootstrap on this machine, re-run from the repo
    echo   directory so the script can find the config automatically.
    echo.
    echo   Otherwise, pass it directly:
    echo     work_windows.bat --ssh-host ssh.yourdomain.com
    echo.
    echo   Use --help for all options.
    echo.
    pause
    exit /b 1
)

set "INSTALL_DIR=%LOCALAPPDATA%\erebus-edge"

echo.
echo   ================================================
echo     erebus-edge -- Work Machine Setup (Windows)
echo   ================================================
echo     SSH host: %SSH_HOST%
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
