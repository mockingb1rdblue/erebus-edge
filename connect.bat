@echo off
setlocal EnableDelayedExpansion

:: ─────────────────────────────────────────────────────────────────────────────
:: connect.bat  –  SSH to home machine via Cloudflare Tunnel
:: No admin needed. Bypasses corporate proxy (workers.dev is in no_proxy).
:: SSH key stored DPAPI-encrypted (tied to your Windows login, not plaintext).
:: ─────────────────────────────────────────────────────────────────────────────

set "DIR=%~dp0"
set "DIR=%DIR:~0,-1%"
set "BIN=%DIR%\bin"
set "KEYS_DIR=%DIR%\keys"
set "KEY_ENC=%KEYS_DIR%\home_key.dpapi"
set "KEY_PUB=%KEYS_DIR%\home_key.pub"
:: Default CF_HOST -- overridden by cf_config.txt if bootstrap.py has been run
set "CF_HOST=ssh.mock1ng.workers.dev"

:: ── load saved config (HOME_USER, SSH_PORT, CF_HOST) ─────────────────────────
if exist "%DIR%\cf_config.txt" (
    for /f "tokens=1,2 delims==" %%A in (%DIR%\cf_config.txt) do (
        if "%%A"=="HOME_USER" set "HOME_USER=%%B"
        if "%%A"=="SSH_PORT"  set "SSH_PORT=%%B"
        if "%%A"=="CF_HOST"   set "CF_HOST=%%B"
    )
)

:: ── first-run: ask for username ───────────────────────────────────────────────
if not defined HOME_USER (
    set /p HOME_USER="Home machine username: "
    set /p SSH_PORT="SSH port on home machine [22]: "
    if "!SSH_PORT!"=="" set "SSH_PORT=22"
    echo HOME_USER=!HOME_USER!>  "%DIR%\cf_config.txt"
    echo SSH_PORT=!SSH_PORT!>>  "%DIR%\cf_config.txt"
    echo [saved to cf_config.txt]
)
set "SSH_PORT=!SSH_PORT!"
if "!SSH_PORT!"=="" set "SSH_PORT=22"

:: ── SSH key setup ─────────────────────────────────────────────────────────────
if not exist "%KEYS_DIR%" mkdir "%KEYS_DIR%"

if not exist "%KEY_ENC%" (
    echo.
    echo No SSH key found.
    echo   1. Generate new key + auto-install on home  (password auth once)
    echo   2. Paste from clipboard
    echo   3. Import from file
    echo   4. Skip - use password auth every time
    echo.
    set /p KEY_CHOICE="Choice [1/2/3/4]: "
    echo.

    set "PLAIN_TMP=%KEYS_DIR%\home_key.tmp"

    if "!KEY_CHOICE!"=="1" (
        ssh-keygen -t ed25519 -f "!PLAIN_TMP!" -N "" -C "cf-portable"
        copy /y "!PLAIN_TMP!.pub" "%KEY_PUB%" >nul
        echo.
        echo [key generated - connecting to install on home machine...]
        echo Enter your home machine password when prompted.
        echo.
        ssh -o "ProxyCommand=\"%BIN%\cloudflared.exe\" access ssh --hostname %CF_HOST%" ^
            -o "StrictHostKeyChecking=accept-new" ^
            -p !SSH_PORT! ^
            !HOME_USER!@%CF_HOST% ^
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" ^
            < "%KEY_PUB%"
        if !errorlevel! equ 0 (
            echo.
            echo [public key installed - future logins will use the key]
        ) else (
            echo.
            echo [auto-install failed - add manually:]
            type "%KEY_PUB%"
        )
        echo.
    ) else if "!KEY_CHOICE!"=="2" (
        powershell -NoProfile -Command "Get-Clipboard" > "!PLAIN_TMP!"
    ) else if "!KEY_CHOICE!"=="3" (
        set /p KEY_SRC="Path to private key: "
        copy "!KEY_SRC!" "!PLAIN_TMP!" >nul
    )

    :: DPAPI-encrypt the private key and delete the plaintext
    if exist "!PLAIN_TMP!" (
        powershell -NoProfile -Command ^
            "Add-Type -AssemblyName System.Security; $b=[IO.File]::ReadAllBytes('!PLAIN_TMP!'); $e=[Security.Cryptography.ProtectedData]::Protect($b,$null,'CurrentUser'); [IO.File]::WriteAllBytes('%KEY_ENC%',$e)"
        del /q /f "!PLAIN_TMP!" 2>nul
        echo [key encrypted with DPAPI - no plaintext stored]
        echo.
    )
)

:: ── decrypt key to temp for this session ─────────────────────────────────────
set "TMP_KEY="
if exist "%KEY_ENC%" (
    for /f "delims=" %%T in ('powershell -NoProfile -Command ^
        "Add-Type -AssemblyName System.Security; try { $e=[IO.File]::ReadAllBytes('%KEY_ENC%'); $d=[Security.Cryptography.ProtectedData]::Unprotect($e,$null,'CurrentUser'); $t=[IO.Path]::GetTempFileName(); [IO.File]::WriteAllBytes($t,$d); $t } catch { '' }" ^
        2^>nul') do set "TMP_KEY=%%T"
)

:: ── connect ───────────────────────────────────────────────────────────────────
echo.
echo Connecting to home via Cloudflare Tunnel...
echo   Endpoint : %CF_HOST%  (direct, no corporate proxy)
echo   User     : !HOME_USER!
if defined TMP_KEY (
    echo   Key      : DPAPI-encrypted ^(temp file, deleted after connect^)
) else (
    echo   Key      : none - password auth
)
echo.
echo Tip: once connected, run:  tmux new -A -s work
echo.

if defined TMP_KEY (
    ssh -o "ProxyCommand=\"%BIN%\cloudflared.exe\" access ssh --hostname %CF_HOST%" ^
        -o "StrictHostKeyChecking=accept-new" ^
        -o "ServerAliveInterval=30" ^
        -o "ServerAliveCountMax=3" ^
        -i "!TMP_KEY!" ^
        -p !SSH_PORT! ^
        !HOME_USER!@%CF_HOST%
    del /q /f "!TMP_KEY!" 2>nul
) else (
    ssh -o "ProxyCommand=\"%BIN%\cloudflared.exe\" access ssh --hostname %CF_HOST%" ^
        -o "StrictHostKeyChecking=accept-new" ^
        -o "ServerAliveInterval=30" ^
        -o "ServerAliveCountMax=3" ^
        -p !SSH_PORT! ^
        !HOME_USER!@%CF_HOST%
)
