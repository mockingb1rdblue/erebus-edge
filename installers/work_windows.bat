@echo off
setlocal enabledelayedexpansion
REM ═══════════════════════════════════════════════════════════════════
REM  erebus-edge -- WORK machine setup for Windows
REM  Run this on the machine you connect FROM (your work/office machine).
REM  Pure batch -- works even when PowerShell is blocked by GPO.
REM  No admin needed. Downloads cloudflared to your user directory.
REM
REM  Handles corporate networks that block custom domain DNS by routing
REM  through a workers.dev relay (auto-detected via DNS probe).
REM
REM  Usage:
REM    work_windows.bat                                 (auto-reads config)
REM    work_windows.bat --host app.yourdomain.com       (skip prompt)
REM    work_windows.bat --relay edge-sync.x.workers.dev (explicit relay)
REM
REM  If bootstrap was run on this machine, just double-click -- no args needed.
REM ═══════════════════════════════════════════════════════════════════

set "TARGET_HOST="
set "RELAY_HOST="
set "SUBDOMAIN="
set "SVC_ID="
set "SVC_SECRET="

REM ── Parse arguments ───────────────────────────────────────────
:parse_args
if "%~1"=="" goto :args_done
if /i "%~1"=="--host"     ( set "TARGET_HOST=%~2" & shift & shift & goto :parse_args )
if /i "%~1"=="--ssh-host" ( set "TARGET_HOST=%~2" & shift & shift & goto :parse_args )
if /i "%~1"=="--relay"    ( set "RELAY_HOST=%~2" & shift & shift & goto :parse_args )
if /i "%~1"=="--id"       ( set "SVC_ID=%~2" & shift & shift & goto :parse_args )
if /i "%~1"=="--secret"   ( set "SVC_SECRET=%~2" & shift & shift & goto :parse_args )
if /i "%~1"=="--help"     goto :show_help
if /i "%~1"=="-help"      goto :show_help
if /i "%~1"=="-h"         goto :show_help
REM Legacy positional arg
if "%TARGET_HOST%"=="" ( set "TARGET_HOST=%~1" & shift & goto :parse_args )
shift
goto :parse_args

:show_help
echo.
echo   Usage:
echo     work_windows.bat                                  (auto-reads config)
echo     work_windows.bat --host ^<HOST^>                    (skip prompt)
echo     work_windows.bat --relay ^<RELAY^>                  (explicit relay host)
echo.
echo   Options:
echo     --host ^<HOST^>       Target hostname (e.g. app.yourdomain.com)
echo     --relay ^<RELAY^>     workers.dev relay (auto-detected if omitted)
echo     --id ^<ID^>           Service token client ID
echo     --secret ^<SECRET^>   Service token client secret
echo     --help, -h           Show this help
echo.
echo   If you ran bootstrap on this machine, just double-click with no arguments.
echo   The script auto-reads your config from the bootstrap output.
echo.
echo   Corporate DNS blocking your custom domain? The script auto-detects this
echo   and routes through a workers.dev relay instead.
echo.
exit /b 0

:args_done

REM ── Auto-read config from bootstrap output if not provided ────
set "_CFG_FILE="
if exist "%~dp0..\erebus-temp\keys\portal_config.json" set "_CFG_FILE=%~dp0..\erebus-temp\keys\portal_config.json"
if "%_CFG_FILE%"=="" if exist "%~dp0..\..\erebus-temp\keys\portal_config.json" set "_CFG_FILE=%~dp0..\..\erebus-temp\keys\portal_config.json"
REM Check keys/ inside repo (legacy location)
if "%_CFG_FILE%"=="" if exist "%~dp0..\keys\portal_config.json" set "_CFG_FILE=%~dp0..\keys\portal_config.json"

if not "%_CFG_FILE%"=="" (
    if "%TARGET_HOST%"=="" (
        REM Try PowerShell first for JSON parsing
        for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content '%_CFG_FILE%' | ConvertFrom-Json).ssh_host" 2^>nul`) do (
            set "TARGET_HOST=%%v"
        )
        REM Fallback: simple findstr extraction if PowerShell is blocked
        if "!TARGET_HOST!"=="" (
            for /f "tokens=2 delims=:," %%v in ('findstr /C:"ssh_host" "%_CFG_FILE%" 2^>nul') do (
                set "_RAW=%%v"
                set "_RAW=!_RAW: =!"
                set "_RAW=!_RAW:"=!"
                set "TARGET_HOST=!_RAW!"
            )
        )
    )
    REM Also read subdomain for relay auto-detection
    if "%SUBDOMAIN%"=="" (
        for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content '%_CFG_FILE%' | ConvertFrom-Json).subdomain" 2^>nul`) do (
            set "SUBDOMAIN=%%v"
        )
        if "!SUBDOMAIN!"=="" (
            for /f "tokens=2 delims=:," %%v in ('findstr /C:"subdomain" "%_CFG_FILE%" 2^>nul') do (
                set "_RAW=%%v"
                set "_RAW=!_RAW: =!"
                set "_RAW=!_RAW:"=!"
                set "SUBDOMAIN=!_RAW!"
            )
        )
    )
    REM Read service token credentials for relay auth
    if "%SVC_ID%"=="" (
        for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content '%_CFG_FILE%' | ConvertFrom-Json).service_token_id" 2^>nun`) do (
            set "SVC_ID=%%v"
        )
    )
    if "%SVC_SECRET%"=="" (
        for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command "(Get-Content '%_CFG_FILE%' | ConvertFrom-Json).service_token_secret" 2^>nul`) do (
            set "SVC_SECRET=%%v"
        )
    )
    if not "!TARGET_HOST!"=="" (
        echo.
        echo   Auto-loaded config from: %_CFG_FILE%
    )
)

REM ── Interactive prompt if still missing ───────────────────────
if "%TARGET_HOST%"=="" (
    echo.
    echo   +-----------------------------------------------------------+
    echo   ^|  Target host not found -- let's set it up.                ^|
    echo   +-----------------------------------------------------------+
    echo.
    echo   Your host looks like:  app.yourdomain.com
    echo.
    echo   Where to find it:
    echo     1. If you ran bootstrap, it printed your endpoints at the end.
    echo     2. If someone else set this up, ask them for the hostname.
    echo     3. Check the Cloudflare dashboard: DNS records for your domain.
    echo.
    set /p "TARGET_HOST=  Paste your host here: "
    echo.
)

if "%TARGET_HOST%"=="" (
    echo.
    echo   Could not determine target host.
    echo   Pass it directly:  work_windows.bat --host app.yourdomain.com
    echo.
    pause
    exit /b 1
)

set "INSTALL_DIR=%LOCALAPPDATA%\erebus-edge"

echo.
echo   ================================================
echo     erebus-edge -- Work Machine Setup (Windows)
echo   ================================================
echo     Target: %TARGET_HOST%
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

REM ── 2. DNS probe -- can we resolve the target host directly? ──
echo   [..]  Testing DNS resolution for %TARGET_HOST%...
set "DNS_OK=false"
nslookup %TARGET_HOST% >nul 2>&1
if !errorlevel! equ 0 set "DNS_OK=true"

REM Double-check: nslookup may return 0 even on timeout on some systems
if "!DNS_OK!"=="true" (
    nslookup %TARGET_HOST% 2>&1 | findstr /C:"Address" | findstr /V /C:"10." /C:"172.16" /C:"192.168" >nul 2>&1
    if !errorlevel! neq 0 set "DNS_OK=false"
)

REM ── 3. Determine proxy hostname for cloudflared ───────────────
set "PROXY_HOST=%TARGET_HOST%"

if "!DNS_OK!"=="true" (
    echo   [OK]  DNS resolves %TARGET_HOST% -- direct connection
    goto :proxy_done
)

echo   [!!]  DNS cannot resolve %TARGET_HOST% -- corporate network detected

REM Use explicit --relay if provided
if not "%RELAY_HOST%"=="" (
    echo   [OK]  Using relay: %RELAY_HOST%
    set "PROXY_HOST=%RELAY_HOST%"
    goto :proxy_done
)

REM Auto-detect relay from subdomain (edge-sync is the hardened relay name)
if not "%SUBDOMAIN%"=="" (
    set "RELAY_HOST=edge-sync.!SUBDOMAIN!.workers.dev"
    echo   [..]  Trying relay: !RELAY_HOST!
    nslookup !RELAY_HOST! >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK]  Relay reachable: !RELAY_HOST!
        set "PROXY_HOST=!RELAY_HOST!"
        goto :proxy_done
    )
    REM Fallback: try legacy relay name
    set "RELAY_HOST=ssh-relay.!SUBDOMAIN!.workers.dev"
    echo   [..]  Trying fallback: !RELAY_HOST!
    nslookup !RELAY_HOST! >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [OK]  Relay reachable: !RELAY_HOST!
        set "PROXY_HOST=!RELAY_HOST!"
        goto :proxy_done
    )
)

REM Manual fallback
echo.
echo   Your corporate network blocks custom domain DNS.
echo   A workers.dev relay is needed to bypass this.
echo.
echo   The relay hostname looks like: edge-sync.XXXX.workers.dev
echo   (Ask whoever ran bootstrap for this)
echo.
set /p "RELAY_HOST=  Paste relay hostname here: "
if not "!RELAY_HOST!"=="" (
    set "PROXY_HOST=!RELAY_HOST!"
) else (
    echo   [!!]  No relay provided. Connection may not work from this network.
    echo         Re-run with: work_windows.bat --relay edge-sync.XXXX.workers.dev
)

:proxy_done

REM ── 4. Build cloudflared command ─────────────────────────────
set "CF_CMD="%CF_PATH%" access ssh --hostname %PROXY_HOST%"
if not "%PROXY_HOST%"=="%TARGET_HOST%" (
    if not "%SVC_ID%"=="" if not "%SVC_SECRET%"=="" (
        set "CF_CMD="%CF_PATH%" access ssh --hostname %PROXY_HOST% --id %SVC_ID% --secret %SVC_SECRET%"
        echo   [OK]  Service token loaded for relay auth
    ) else (
        echo   [!!]  WARNING: No service token found in config.
        echo         Relay mode requires a service token for auth.
        echo         Re-run with: --id ^<ID^> --secret ^<SECRET^>
    )
)

REM ── 5. Create connect.bat ─────────────────────────────────────
set "CONNECT=%INSTALL_DIR%\connect.bat"
(
    echo @echo off
    echo set /p RUSER=Username on remote host:
    echo ssh -o "ProxyCommand=!CF_CMD!" %%RUSER%%@%TARGET_HOST%
) > "%CONNECT%"
echo   [OK]  Created %CONNECT%

REM ── 6. Config entry ─────────────────────────────────────────
set "SSH_DIR=%USERPROFILE%\.ssh"
set "SSH_CFG=%SSH_DIR%\config"
if not exist "%SSH_DIR%" mkdir "%SSH_DIR%"

REM Remove any previous erebus-edge entry to avoid duplicates
if exist "%SSH_CFG%" (
    findstr /C:"erebus-edge" "%SSH_CFG%" >nul 2>&1
    if !errorlevel! equ 0 (
        echo   [..]  Removing old config entry...
        set "_SKIP=0"
        > "%SSH_CFG%.tmp" (
            for /f "usebackq delims=" %%L in ("%SSH_CFG%") do (
                set "_LINE=%%L"
                if "!_LINE:erebus-edge=!" neq "!_LINE!" (
                    set "_SKIP=5"
                )
                if !_SKIP! gtr 0 (
                    set /a "_SKIP=!_SKIP!-1"
                ) else (
                    echo %%L
                )
            )
        )
        move /y "%SSH_CFG%.tmp" "%SSH_CFG%" >nul 2>&1
        echo   [OK]  Old entry removed
    )
)

echo.>> "%SSH_CFG%"
echo # erebus-edge -- CF Tunnel>> "%SSH_CFG%"
echo Host %TARGET_HOST%>> "%SSH_CFG%"
echo     ProxyCommand !CF_CMD!>> "%SSH_CFG%"
echo     StrictHostKeyChecking no>> "%SSH_CFG%"
echo     UserKnownHostsFile NUL>> "%SSH_CFG%"

if "%PROXY_HOST%"=="%TARGET_HOST%" (
    echo   [OK]  Config: direct connection to %TARGET_HOST%
) else (
    echo   [OK]  Config: %TARGET_HOST% via relay %PROXY_HOST%
)

echo.
echo   ================================================
echo     Done!  Work machine is ready.
echo   ================================================
echo.
if "%PROXY_HOST%"=="%TARGET_HOST%" (
    echo   Mode: Direct connection
) else (
    echo   Mode: Corporate DNS bypass via workers.dev relay
    echo   Relay: %PROXY_HOST%
)
echo.
echo   Connect to your home machine:
echo     Browser : https://%PROXY_HOST%  (opens terminal in browser)
echo     CLI     : ssh YOUR_USER@%TARGET_HOST%
echo     Script  : %CONNECT%
echo.
endlocal
