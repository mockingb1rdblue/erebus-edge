@echo off
setlocal EnableDelayedExpansion
:: bootstrap.bat -- First-run setup wizard for erebus-edge (Windows).
::
:: Self-contained -- uses PowerShell for HTTP/JSON, DPAPI for credential storage.
:: All artifacts go to ..\erebus-temp\ (repo stays clean).
::
:: Usage:
::   bootstrap.bat --email user@example.com
::   bootstrap.bat --email a@x.com --email b@x.com
::   bootstrap.bat --redeploy
::   bootstrap.bat --skip-access --skip-tsnet
::   bootstrap.bat --build-tsnet
::   bootstrap.bat --workers-only

:: ═══════════════════════════════════════════════════════════════════════
::  Paths & constants
:: ═══════════════════════════════════════════════════════════════════════
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"
for %%I in ("%SCRIPT_DIR%\..") do set "REPO_ROOT=%%~fI"
for %%I in ("%REPO_ROOT%\..") do set "PARENT_DIR=%%~fI"
set "TEMP_DIR=%PARENT_DIR%\erebus-temp"
set "KEYS_DIR=%TEMP_DIR%\keys"
set "BIN_DIR=%TEMP_DIR%\bin"
set "CF_CFG_TXT=%TEMP_DIR%\cf_config.txt"
set "CFG_FILE=%KEYS_DIR%\portal_config.json"
set "CF_API=https://api.cloudflare.com/client/v4"
set "PORTAL_TOKEN_NAME=ssh-portal"
set "TUNNEL_NAME=home-ssh"
set "COMPAT_DATE=2024-09-23"

:: Enable VT100 for colours
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "G=%ESC%[32m"
set "Y=%ESC%[33m"
set "C=%ESC%[36m"
set "R=%ESC%[31m"
set "B=%ESC%[1m"
set "D=%ESC%[2m"
set "X=%ESC%[0m"

:: ── Global state ─────────────────────────────────────────────────────
set "TOKEN="
set "ACCT_ID="
set "ACCT_NAME="
set "SUBDOMAIN="
set "TUNNEL_ID="
set "TUNNEL_TOKEN="
set "KV_NS_ID="
set "SSH_HOST="
set "SSH_APP_AUD="
set "SSH_CA_KEY="
set "TEAM_NAME="
set "TSNET_OK=false"

:: ── Parse arguments ──────────────────────────────────────────────────
set "ARG_REDEPLOY=false"
set "ARG_SKIP_ACCESS=false"
set "ARG_SKIP_TSNET=false"
set "ARG_BUILD_TSNET=false"
set "ARG_WORKERS_ONLY=false"
set "EMAIL_COUNT=0"

:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--redeploy"     (set "ARG_REDEPLOY=true"     & shift & goto parse_args)
if /i "%~1"=="--skip-access"  (set "ARG_SKIP_ACCESS=true"  & shift & goto parse_args)
if /i "%~1"=="--skip-tsnet"   (set "ARG_SKIP_TSNET=true"   & shift & goto parse_args)
if /i "%~1"=="--build-tsnet"  (set "ARG_BUILD_TSNET=true"  & shift & goto parse_args)
if /i "%~1"=="--workers-only" (set "ARG_WORKERS_ONLY=true" & shift & goto parse_args)
if /i "%~1"=="--email" (
    shift
    set /a EMAIL_COUNT+=1
    set "ARG_EMAIL_!EMAIL_COUNT!=%~1"
    shift
    goto parse_args
)
if /i "%~1"=="-h" goto show_help
if /i "%~1"=="--help" goto show_help
echo   %R%x%X% Unknown option: %~1
exit /b 1

:show_help
echo Usage: %~nx0 [OPTIONS]
echo.
echo Options:
echo   --email EMAIL     Email for CF Access policy (repeatable)
echo   --redeploy        Re-deploy Workers with existing config
echo   --skip-access     Skip CF Access setup
echo   --skip-tsnet      Skip tsnet build step
echo   --build-tsnet     Only rebuild tsnet binary
echo   --workers-only    Skip tunnel/Access, just deploy Workers
echo   -h, --help        Show this help
exit /b 0

:args_done

:: ═══════════════════════════════════════════════════════════════════════
::  Check PowerShell availability
:: ═══════════════════════════════════════════════════════════════════════
where powershell >nul 2>&1
if errorlevel 1 (
    echo ERROR: PowerShell is required for API calls and JSON parsing.
    exit /b 1
)

:: Create directories
if not exist "%KEYS_DIR%" mkdir "%KEYS_DIR%"
if not exist "%BIN_DIR%"  mkdir "%BIN_DIR%"

:: ═══════════════════════════════════════════════════════════════════════
::  PowerShell helper: run PS command and capture output
:: ═══════════════════════════════════════════════════════════════════════
:: Usage: call :ps_run "powershell code" RESULT_VAR
:: Note: For multi-line PS, write to temp .ps1 file
goto :skip_functions

:ok
echo   %G%v%X% %~1
goto :eof

:warn
echo   %Y%!%X% %~1
goto :eof

:err
echo   %R%x%X% %~1
goto :eof

:hdr
echo.
echo %C%%B%-- %~1 --------------------------------------------------%X%
goto :eof

:: ── CF API call via PowerShell ───────────────────────────────────────
:: Usage: call :cf_api METHOD PATH [JSON_DATA] RESULT_VAR
:cf_api
set "_method=%~1"
set "_path=%~2"
set "_data=%~3"
set "_result_var=%~4"
if "%_data%"=="" set "_result_var=%~3"

set "_ps_file=%TEMP%\erebus_api_%RANDOM%.ps1"
(
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
echo $headers = @{ 'Authorization' = "Bearer %TOKEN%"; 'Content-Type' = 'application/json' }
echo try {
if "%_data%"=="" (
    echo   $r = Invoke-RestMethod -Uri '%CF_API%%_path%' -Method %_method% -Headers $headers -ErrorAction Stop
) else (
    echo   $body = '%_data%'
    echo   $r = Invoke-RestMethod -Uri '%CF_API%%_path%' -Method %_method% -Headers $headers -Body $body -ErrorAction Stop
)
echo   $r ^| ConvertTo-Json -Depth 20 -Compress
echo } catch {
echo   Write-Output ('{"success":false,"errors":["' + $_.Exception.Message + '"]}'^)
echo }
) > "%_ps_file%"
for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%_ps_file%" 2^>nul') do set "%_result_var%=%%r"
del "%_ps_file%" 2>nul
goto :eof

:: ── JSON value extraction via PowerShell ─────────────────────────────
:: Usage: call :json_get JSON_STRING "path.to.value" RESULT_VAR
:json_get
set "_json=%~1"
set "_jpath=%~2"
set "_jvar=%~3"
:: Write JSON to temp file to avoid escaping issues
set "_jf=%TEMP%\erebus_json_%RANDOM%.txt"
echo !_json! > "!_jf!"
for /f "delims=" %%v in ('powershell -NoProfile -Command "$j = Get-Content '!_jf!' | ConvertFrom-Json; $v = $j; '%_jpath%'.Split('.') | ForEach-Object { if ($_ -match '(.*)\[(\d+)\]') { $v = $v.($matches[1])[$matches[2]] } else { $v = $v.$_ } }; if ($v -is [bool]) { $v.ToString().ToLower() } elseif ($v -ne $null) { $v } else { '' }" 2^>nul') do set "%_jvar%=%%v"
del "!_jf!" 2>nul
goto :eof

:: ── Config load/save ─────────────────────────────────────────────────
:config_val
:: Usage: call :config_val KEY RESULT_VAR
if not exist "%CFG_FILE%" (set "%~2=" & goto :eof)
for /f "delims=" %%v in ('powershell -NoProfile -Command "$c = Get-Content '%CFG_FILE%' | ConvertFrom-Json; if ($c.%~1) { $c.%~1 } else { '' }" 2^>nul') do set "%~2=%%v"
goto :eof

:save_config
:: Usage: call :save_config "json_updates"
set "_updates=%~1"
set "_sc_ps=%TEMP%\erebus_savecfg_%RANDOM%.ps1"
(
echo $cfgFile = '%CFG_FILE%'
echo $updates = '%_updates%' ^| ConvertFrom-Json
echo if (Test-Path $cfgFile^) {
echo   $cfg = Get-Content $cfgFile ^| ConvertFrom-Json
echo   $updates.PSObject.Properties ^| ForEach-Object { $cfg ^| Add-Member -Force -NotePropertyName $_.Name -NotePropertyValue $_.Value }
echo } else {
echo   $cfg = $updates
echo }
echo $cfg ^| ConvertTo-Json -Depth 10 ^| Set-Content $cfgFile
) > "%_sc_ps%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%_sc_ps%" 2>nul
del "%_sc_ps%" 2>nul
goto :eof

:: ── DPAPI credential store ───────────────────────────────────────────
:store_credential
:: Usage: call :store_credential TOKEN
set "_tok=%~1"
set "_cred_file=%KEYS_DIR%\cf_creds.dpapi"
powershell -NoProfile -Command ^
  "Add-Type -AssemblyName System.Security; ^
   $bytes = [System.Text.Encoding]::UTF8.GetBytes('{\"cf_token\":\"%_tok%\"}'); ^
   $enc = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $null, 'CurrentUser'); ^
   [System.IO.File]::WriteAllBytes('%_cred_file%', $enc)" 2>nul
if errorlevel 1 (call :warn "DPAPI encryption failed -- token not saved.") else (call :ok "Credentials saved (DPAPI-encrypted).")
goto :eof

:load_credential
:: Usage: call :load_credential RESULT_VAR
set "_cred_file=%KEYS_DIR%\cf_creds.dpapi"
if not exist "%_cred_file%" (set "%~1=" & goto :eof)
for /f "delims=" %%t in ('powershell -NoProfile -Command ^
  "Add-Type -AssemblyName System.Security; ^
   try { ^
     $enc = [System.IO.File]::ReadAllBytes('%_cred_file%'); ^
     $dec = [System.Security.Cryptography.ProtectedData]::Unprotect($enc, $null, 'CurrentUser'); ^
     $json = [System.Text.Encoding]::UTF8.GetString($dec) | ConvertFrom-Json; ^
     $json.cf_token ^
   } catch { '' }" 2^>nul') do set "%~1=%%t"
goto :eof

:: ── cloudflared detection ────────────────────────────────────────────
:find_cloudflared
set "CLOUDFLARED="
where cloudflared >nul 2>&1
if not errorlevel 1 (
    for /f "delims=" %%p in ('where cloudflared 2^>nul') do set "CLOUDFLARED=%%p"
    call :ok "cloudflared in PATH: !CLOUDFLARED!"
    goto :eof
)
if exist "%BIN_DIR%\cloudflared.exe" (
    set "CLOUDFLARED=%BIN_DIR%\cloudflared.exe"
    call :ok "cloudflared: !CLOUDFLARED!"
    goto :eof
)
:: Download
echo   Downloading cloudflared (Windows amd64) ...
set "_cf_url=https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
curl -sL -o "%BIN_DIR%\cloudflared.exe" "%_cf_url%" 2>nul
if exist "%BIN_DIR%\cloudflared.exe" (
    set "CLOUDFLARED=%BIN_DIR%\cloudflared.exe"
    call :ok "cloudflared downloaded."
) else (
    :: Try certutil fallback
    certutil -urlcache -split -f "%_cf_url%" "%BIN_DIR%\cloudflared.exe" >nul 2>&1
    if exist "%BIN_DIR%\cloudflared.exe" (
        set "CLOUDFLARED=%BIN_DIR%\cloudflared.exe"
        call :ok "cloudflared downloaded (certutil)."
    ) else (
        call :warn "Could not download cloudflared."
    )
)
goto :eof

:: ── Deploy Worker (multipart upload via PowerShell) ──────────────────
:deploy_worker
:: Usage: call :deploy_worker ACCT_ID SCRIPT_NAME JS_FILE_PATH
set "_dw_acct=%~1"
set "_dw_name=%~2"
set "_dw_js_file=%~3"
set "_dw_ps=%TEMP%\erebus_deploy_%RANDOM%.ps1"
(
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
echo $url = '%CF_API%/accounts/%_dw_acct%/workers/scripts/%_dw_name%'
echo $token = '%TOKEN%'
echo $meta = '{"main_module":"worker.js","compatibility_date":"%COMPAT_DATE%","bindings":[],"logpush":false}'
echo $js = Get-Content '%_dw_js_file%' -Raw
echo $boundary = '----BootstrapBoundary' + [guid]::NewGuid().ToString('N'^)
echo $body = "--$boundary`r`n"
echo $body += "Content-Disposition: form-data; name=`"metadata`"; filename=`"metadata.json`"`r`n"
echo $body += "Content-Type: application/json`r`n`r`n"
echo $body += $meta + "`r`n"
echo $body += "--$boundary`r`n"
echo $body += "Content-Disposition: form-data; name=`"worker.js`"; filename=`"worker.js`"`r`n"
echo $body += "Content-Type: application/javascript+module`r`n`r`n"
echo $body += $js + "`r`n"
echo $body += "--$boundary--`r`n"
echo $headers = @{ 'Authorization' = "Bearer $token"; 'Content-Type' = "multipart/form-data; boundary=$boundary" }
echo try {
echo   $r = Invoke-RestMethod -Uri $url -Method PUT -Headers $headers -Body $body -ErrorAction Stop
echo   if ($r.success -eq $true^) { Write-Output 'OK' } else { Write-Output 'FAIL' }
echo } catch { Write-Output 'FAIL' }
echo # Enable workers.dev subdomain
echo try {
echo   $subUrl = $url + '/subdomain'
echo   $subHeaders = @{ 'Authorization' = "Bearer $token"; 'Content-Type' = 'application/json' }
echo   Invoke-RestMethod -Uri $subUrl -Method POST -Headers $subHeaders -Body '{"enabled":true}' -ErrorAction SilentlyContinue
echo } catch {}
) > "%_dw_ps%"
set "_dw_result=FAIL"
for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%_dw_ps%" 2^>nul') do set "_dw_result=%%r"
del "%_dw_ps%" 2>nul
if "!_dw_result!"=="OK" (exit /b 0) else (exit /b 1)

:skip_functions

:: ═══════════════════════════════════════════════════════════════════════
::  Main entry point
:: ═══════════════════════════════════════════════════════════════════════
echo.
echo %C%%B%  +==========================================+
echo   ^|       SSH Portal -- Bootstrap Wizard     ^|
echo   +==========================================+%X%
echo.
echo   Each user deploys their OWN instance with their OWN CF account.
echo   Share the repo/zip -- not the URL.
echo.

:: ── Build-tsnet-only mode ────────────────────────────────────────────
if "%ARG_BUILD_TSNET%"=="true" (
    call :step_build_tsnet
    if "!TSNET_OK!"=="true" call :ok "tsnet.exe ready. Run:  %BIN_DIR%\tsnet.exe up"
    goto :end
)

:: ── Redeploy mode ────────────────────────────────────────────────────
if "%ARG_REDEPLOY%"=="true" (
    call :config_val account_id ACCT_ID
    call :config_val subdomain SUBDOMAIN
    call :config_val tunnel_id TUNNEL_ID
    call :config_val kv_ns_id KV_NS_ID
    if "!ACCT_ID!"=="" (call :err "Config incomplete. Run full bootstrap first." & exit /b 1)
    if "!SUBDOMAIN!"=="" (call :err "Config incomplete. Run full bootstrap first." & exit /b 1)
    call :step_auth
    call :step_workers
    call :step_ts_relay
    if not "%ARG_SKIP_TSNET%"=="true" call :step_build_tsnet
    call :print_summary
    goto :end
)

:: ── Full wizard ──────────────────────────────────────────────────────
call :step_auth
call :step_discover

if not "%ARG_WORKERS_ONLY%"=="true" (
    call :step_tunnel
    call :step_kv
) else (
    call :config_val tunnel_id TUNNEL_ID
    call :config_val kv_ns_id KV_NS_ID
)

:: Save config early
call :step_save

call :step_workers

if not "%ARG_WORKERS_ONLY%"=="true" (
    call :step_ingress
    call :step_ts_relay
)

:: CF Access: collect emails
if "%ARG_SKIP_ACCESS%"=="true" goto :skip_access
if "%ARG_WORKERS_ONLY%"=="true" goto :skip_access
if %EMAIL_COUNT% gtr 0 goto :do_access

echo.
echo   %B%CF Zero Trust Access%X% protects the terminal (shell on home machine).
echo   Enter email addresses to allow. Press Enter with no input to skip.

:collect_emails
set /p "_email=  Email (or Enter to skip): "
if "!_email!"=="" goto :check_emails
set /a EMAIL_COUNT+=1
set "ARG_EMAIL_!EMAIL_COUNT!=!_email!"
goto :collect_emails

:check_emails
if %EMAIL_COUNT% equ 0 goto :skip_access

:do_access
call :step_access
:skip_access

:: Build tsnet
if not "%ARG_SKIP_TSNET%"=="true" call :step_build_tsnet

call :print_summary
goto :end

:: ═══════════════════════════════════════════════════════════════════════
::  Step 1 — Authenticate
:: ═══════════════════════════════════════════════════════════════════════
:step_auth
call :hdr "Step 1: Authenticate with Cloudflare"

:: Try stored DPAPI credential
call :load_credential TOKEN
if not "!TOKEN!"=="" (
    :: Verify token
    set "_verify_ps=%TEMP%\erebus_verify_%RANDOM%.ps1"
    (
    echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    echo [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
    echo try {
    echo   $r = Invoke-RestMethod -Uri '%CF_API%/accounts' -Headers @{ 'Authorization' = "Bearer !TOKEN!" } -ErrorAction Stop
    echo   if ($r.result.Count -gt 0^) { 'valid' } else { 'invalid' }
    echo } catch { 'invalid' }
    ) > "!_verify_ps!"
    set "_vresult=invalid"
    for /f "delims=" %%v in ('powershell -NoProfile -ExecutionPolicy Bypass -File "!_verify_ps!" 2^>nul') do set "_vresult=%%v"
    del "!_verify_ps!" 2>nul
    if "!_vresult!"=="valid" (
        call :ok "Using stored Cloudflare credentials."
        goto :eof
    )
    call :warn "Stored token could not be verified -- re-authenticating."
    set "TOKEN="
)

echo.
echo   %B%Authentication method:%X%
echo   %B%1%X%  Browser OAuth  %D%(recommended -- opens Cloudflare in browser)%X%
echo   %B%2%X%  Paste API token  %D%(from CF Dashboard -^> My Profile -^> API Tokens)%X%
echo.
set /p "_auth_method=  [1/2]: "

if "!_auth_method!"=="2" goto :manual_token

:: Browser login
call :find_cloudflared
if "!CLOUDFLARED!"=="" (
    call :warn "cloudflared not found. Falling back to manual token."
    goto :manual_token
)

echo.
echo   Opening Cloudflare in your browser...
echo   %D%Log in, select your account, and click Authorize.%X%
echo.

set "_cert_path=%KEYS_DIR%\cf_login.pem"
if exist "!_cert_path!" del "!_cert_path!"
"!CLOUDFLARED!" tunnel login --origincert="!_cert_path!" 2>nul

if not exist "!_cert_path!" (
    call :warn "Login did not complete. Falling back to manual token."
    goto :manual_token
)

:: Parse cert token (via PowerShell)
set "_broad_token="
for /f "delims=" %%t in ('powershell -NoProfile -Command ^
  "$c = Get-Content '!_cert_path!' -Raw; ^
   if ($c -match '-----BEGIN SERVICE KEY-----\r?\n(.*?)\r?\n-----END SERVICE KEY-----') { ^
     $raw = $matches[1] -replace '\r|\n',''; ^
     [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw)).Trim() ^
   }" 2^>nul') do set "_broad_token=%%t"
del "!_cert_path!" 2>nul

if "!_broad_token!"=="" (
    call :warn "Could not extract token from cert. Falling back to manual."
    goto :manual_token
)

:: Get account for scoped token creation
call :cf_api_broad "!_broad_token!" GET "/accounts" _accts_resp
:: For simplicity, use broad token directly and let user create scoped token manually if desired
set "TOKEN=!_broad_token!"
call :ok "Authenticated via browser OAuth."
goto :save_token_prompt

:manual_token
echo.
echo   Dashboard -^> My Profile -^> API Tokens -^> Create Token
echo   Permissions: Cloudflare Tunnel Edit, Workers Script Edit,
echo                Workers KV Storage Edit, Zero Trust Edit
echo.
set /p "TOKEN=  Paste token: "
if "!TOKEN!"=="" (call :err "No token provided." & exit /b 1)

:save_token_prompt
echo.
echo   %B%Save credentials?%X%
echo   %B%1%X%  Yes -- DPAPI-encrypted, tied to this Windows login
echo   %B%2%X%  No  -- session only
echo.
set /p "_save_choice=  [1/2]: "
if not "!_save_choice!"=="2" call :store_credential "!TOKEN!"
goto :eof

:cf_api_broad
:: Like cf_api but with explicit token arg
set "_cab_tok=%~1"
set "_cab_method=%~2"
set "_cab_path=%~3"
set "_cab_var=%~4"
set "_cab_ps=%TEMP%\erebus_apib_%RANDOM%.ps1"
(
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
echo try {
echo   $r = Invoke-RestMethod -Uri '%CF_API%%_cab_path%' -Method %_cab_method% -Headers @{ 'Authorization' = "Bearer %_cab_tok%" } -ErrorAction Stop
echo   $r ^| ConvertTo-Json -Depth 20 -Compress
echo } catch { '{"success":false}' }
) > "%_cab_ps%"
for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%_cab_ps%" 2^>nul') do set "%_cab_var%=%%r"
del "%_cab_ps%" 2>nul
goto :eof

:: ═══════════════════════════════════════════════════════════════════════
::  Step 2 — Discover account + subdomain
:: ═══════════════════════════════════════════════════════════════════════
:step_discover
call :hdr "Step 2: Discover account & workers.dev subdomain"

set "_disc_ps=%TEMP%\erebus_disc_%RANDOM%.ps1"
(
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
echo $h = @{ 'Authorization' = "Bearer %TOKEN%"; 'Content-Type' = 'application/json' }
echo $r = Invoke-RestMethod -Uri '%CF_API%/accounts' -Headers $h -ErrorAction Stop
echo $accts = $r.result
echo if ($accts.Count -eq 0^) { Write-Error 'No accounts'; exit 1 }
echo $acct = $accts[0]
echo if ($accts.Count -gt 1^) {
echo   for ($i=0; $i -lt $accts.Count; $i++^) { Write-Host ("  " + ($i+1^) + "  " + $accts[$i].name + "  (" + $accts[$i].id.Substring(0,8^) + "...^)"^) }
echo   $choice = Read-Host "  Account [1]"
echo   if ($choice -and [int]$choice -ge 1 -and [int]$choice -le $accts.Count^) { $acct = $accts[[int]$choice - 1] }
echo }
echo $sub = Invoke-RestMethod -Uri ('%CF_API%/accounts/' + $acct.id + '/workers/subdomain'^) -Headers $h -ErrorAction SilentlyContinue
echo $subdomain = if ($sub.result.subdomain^) { $sub.result.subdomain } else { Read-Host "  Enter workers.dev subdomain" }
echo Write-Output ("ACCT_ID=" + $acct.id^)
echo Write-Output ("ACCT_NAME=" + $acct.name^)
echo Write-Output ("SUBDOMAIN=" + $subdomain^)
) > "%_disc_ps%"
for /f "tokens=1,* delims==" %%a in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%_disc_ps%" 2^>nul') do (
    if "%%a"=="ACCT_ID" set "ACCT_ID=%%b"
    if "%%a"=="ACCT_NAME" set "ACCT_NAME=%%b"
    if "%%a"=="SUBDOMAIN" set "SUBDOMAIN=%%b"
)
del "%_disc_ps%" 2>nul
set "SSH_HOST=ssh.!SUBDOMAIN!.workers.dev"
call :ok "workers.dev subdomain: !SUBDOMAIN!.workers.dev"
call :ok "Account: !ACCT_NAME!"
goto :eof

:: ═══════════════════════════════════════════════════════════════════════
::  Step 3 — Tunnel
:: ═══════════════════════════════════════════════════════════════════════
:step_tunnel
call :hdr "Step 3: CF Tunnel"

set "_tun_ps=%TEMP%\erebus_tunnel_%RANDOM%.ps1"
(
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
echo $h = @{ 'Authorization' = "Bearer %TOKEN%"; 'Content-Type' = 'application/json' }
echo $r = Invoke-RestMethod -Uri '%CF_API%/accounts/%ACCT_ID%/cfd_tunnel?name=%TUNNEL_NAME%' -Headers $h -ErrorAction SilentlyContinue
echo $existing = $r.result ^| Where-Object { $_.name -eq '%TUNNEL_NAME%' -and -not $_.deleted_at }
echo if ($existing^) {
echo   $t = $existing ^| Select-Object -First 1
echo   Write-Output ("TUNNEL_ID=" + $t.id^)
echo   try {
echo     $tok = Invoke-RestMethod -Uri ('%CF_API%/accounts/%ACCT_ID%/cfd_tunnel/' + $t.id + '/token'^) -Headers $h -ErrorAction Stop
echo     Write-Output ("TUNNEL_TOKEN=" + $tok.result^)
echo   } catch {}
echo   exit 0
echo }
echo $secret = [Convert]::ToBase64String((1..32 ^| ForEach-Object { Get-Random -Max 256 } ^| ForEach-Object { [byte]$_ }^)^)
echo $body = @{ name='%TUNNEL_NAME%'; tunnel_secret=$secret; config_src='cloudflare' } ^| ConvertTo-Json
echo $cr = Invoke-RestMethod -Uri '%CF_API%/accounts/%ACCT_ID%/cfd_tunnel' -Method POST -Headers $h -Body $body -ErrorAction Stop
echo Write-Output ("TUNNEL_ID=" + $cr.result.id^)
echo if ($cr.result.token^) { Write-Output ("TUNNEL_TOKEN=" + $cr.result.token^) }
echo else {
echo   try {
echo     $tok = Invoke-RestMethod -Uri ('%CF_API%/accounts/%ACCT_ID%/cfd_tunnel/' + $cr.result.id + '/token'^) -Headers $h -ErrorAction Stop
echo     Write-Output ("TUNNEL_TOKEN=" + $tok.result^)
echo   } catch {}
echo }
) > "%_tun_ps%"
for /f "tokens=1,* delims==" %%a in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%_tun_ps%" 2^>nul') do (
    if "%%a"=="TUNNEL_ID" set "TUNNEL_ID=%%b"
    if "%%a"=="TUNNEL_TOKEN" set "TUNNEL_TOKEN=%%b"
)
del "%_tun_ps%" 2>nul
if "!TUNNEL_ID!"=="" (call :err "Failed to create/find tunnel." & exit /b 1)
call :ok "Tunnel: !TUNNEL_ID:~0,8!..."
goto :eof

:: ═══════════════════════════════════════════════════════════════════════
::  Step 4 — KV namespace
:: ═══════════════════════════════════════════════════════════════════════
:step_kv
call :hdr "Step 4: KV Namespace (ssh-portal)"

set "_kv_ps=%TEMP%\erebus_kv_%RANDOM%.ps1"
(
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
echo $h = @{ 'Authorization' = "Bearer %TOKEN%"; 'Content-Type' = 'application/json' }
echo $r = Invoke-RestMethod -Uri '%CF_API%/accounts/%ACCT_ID%/storage/kv/namespaces' -Headers $h -ErrorAction Stop
echo $ns = $r.result ^| Where-Object { $_.title -eq 'ssh-portal' } ^| Select-Object -First 1
echo if ($ns^) { Write-Output $ns.id; exit 0 }
echo $cr = Invoke-RestMethod -Uri '%CF_API%/accounts/%ACCT_ID%/storage/kv/namespaces' -Method POST -Headers $h -Body '{"title":"ssh-portal"}' -ErrorAction Stop
echo Write-Output $cr.result.id
) > "%_kv_ps%"
for /f "delims=" %%v in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%_kv_ps%" 2^>nul') do set "KV_NS_ID=%%v"
del "%_kv_ps%" 2>nul
if "!KV_NS_ID!"=="" (call :err "Failed to create/find KV namespace." & exit /b 1)
call :ok "KV namespace: !KV_NS_ID:~0,8!..."
goto :eof

:: ═══════════════════════════════════════════════════════════════════════
::  Step 5 — Deploy SSH Worker
:: ═══════════════════════════════════════════════════════════════════════
:step_workers
call :hdr "Step 5: Deploy SSH Worker"
set "SSH_HOST=ssh.!SUBDOMAIN!.workers.dev"

:: Generate Worker JS to temp file
set "_ssh_js=%TEMP%\erebus_ssh_worker_%RANDOM%.js"
(
echo // SSH proxy Worker: forwards cloudflared SSH traffic to the CF Tunnel.
echo const TUNNEL   = '!TUNNEL_ID!.cfargotunnel.com';
echo const SSH_HOST = '!SSH_HOST!';
echo export default {
echo   async fetch(request^) {
echo     const url  = new URL(request.url^);
echo     const dest = new URL(url.pathname + url.search, `https://${TUNNEL}`^);
echo     const headers = new Headers(^);
echo     for (const [k, v] of request.headers^) {
echo       if (/^^(cf-^|x-forwarded-^|x-real-ip^)/i.test(k^)^) continue;
echo       headers.set(k, v^);
echo     }
echo     headers.set('Host', SSH_HOST^);
echo     return fetch(dest.toString(^), {
echo       method: request.method, headers,
echo       body: ['GET','HEAD'].includes(request.method^) ? undefined : request.body,
echo     }^);
echo   }
echo };
) > "!_ssh_js!"

echo   Deploying 'ssh' Worker ...
call :deploy_worker "!ACCT_ID!" "ssh" "!_ssh_js!"
if not errorlevel 1 (
    echo   %G%OK%X%  -^>  https://!SSH_HOST!
) else (
    echo   %R%FAILED%X%
)
del "!_ssh_js!" 2>nul
goto :eof

:: ═══════════════════════════════════════════════════════════════════════
::  Step 6 — Tunnel ingress
:: ═══════════════════════════════════════════════════════════════════════
:step_ingress
call :hdr "Step 6: Tunnel ingress rules"
set "SSH_HOST=ssh.!SUBDOMAIN!.workers.dev"

call :config_val ssh_app_aud _ing_aud
call :config_val team_name _ing_team

set "_ing_ps=%TEMP%\erebus_ingress_%RANDOM%.ps1"
(
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
echo $h = @{ 'Authorization' = "Bearer %TOKEN%"; 'Content-Type' = 'application/json' }
echo $cfgUrl = '%CF_API%/accounts/%ACCT_ID%/cfd_tunnel/%TUNNEL_ID%/configurations'
echo $r = Invoke-RestMethod -Uri $cfgUrl -Headers $h -ErrorAction SilentlyContinue
echo $existing = $r.result.config.ingress ^| Where-Object { $_.hostname -eq '%SSH_HOST%' }
echo if ($existing -and ($existing.originRequest.access -or -not '%_ing_aud%'^)^) {
echo   Write-Output 'EXISTS'
echo   exit 0
echo }
echo $sshRule = @{ hostname='%SSH_HOST%'; service='ssh://localhost:22' }
echo if ('%_ing_aud%' -and '%_ing_team%'^) {
echo   $sshRule.originRequest = @{ access = @{ required=$true; teamName='%_ing_team%'; audTag=@('%_ing_aud%'^) } }
echo }
echo $rules = @($sshRule, @{ service='http_status:404' }^)
echo $body = @{ config = @{ ingress = $rules } } ^| ConvertTo-Json -Depth 10
echo $r2 = Invoke-RestMethod -Uri $cfgUrl -Method PUT -Headers $h -Body $body -ErrorAction Stop
echo if ($r2.success^) { Write-Output 'OK' } else { Write-Output 'FAIL' }
) > "%_ing_ps%"
set "_ing_result="
for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%_ing_ps%" 2^>nul') do set "_ing_result=%%r"
del "%_ing_ps%" 2>nul
if "!_ing_result!"=="EXISTS" (call :ok "Tunnel ingress already configured.") ^
else if "!_ing_result!"=="OK" (call :ok "Ingress set: !SSH_HOST! -> ssh://localhost:22") ^
else (call :warn "Ingress update failed.")
goto :eof

:: ═══════════════════════════════════════════════════════════════════════
::  Step 7 — CF Access
:: ═══════════════════════════════════════════════════════════════════════
:step_access
call :hdr "Step 7: CF Zero Trust Access"
if %EMAIL_COUNT% equ 0 (
    echo   %D%Skipped (no emails provided).%X%
    goto :eof
)

:: Build email list for PowerShell
set "_email_list="
for /l %%i in (1,1,%EMAIL_COUNT%) do (
    if defined _email_list (set "_email_list=!_email_list!,!ARG_EMAIL_%%i!") else (set "_email_list=!ARG_EMAIL_%%i!")
)

set "_access_ps=%TEMP%\erebus_access_%RANDOM%.ps1"
(
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
echo $h = @{ 'Authorization' = "Bearer %TOKEN%"; 'Content-Type' = 'application/json' }
echo $acct = '%ACCT_ID%'
echo $sshHost = '%SSH_HOST%'
echo $emails = '%_email_list%'.Split(','^)
echo.
echo # ensure_org
echo $org = $null
echo try {
echo   $r = Invoke-RestMethod -Uri "%CF_API%/accounts/$acct/access/organizations" -Headers $h -ErrorAction Stop
echo   if ($r.success -and $r.result^) { $org = $r.result; Write-Host "  [OK] Zero Trust org exists" }
echo } catch {}
echo if (-not $org^) {
echo   $orgName = '%ACCT_NAME%'.ToLower(^) -replace ' ',''
echo   $orgBody = @{ name=$orgName; auth_domain="$orgName.cloudflareaccess.com"; login_design=@{}; is_ui_read_only=$false } ^| ConvertTo-Json
echo   try {
echo     $r = Invoke-RestMethod -Uri "%CF_API%/accounts/$acct/access/organizations" -Method PUT -Headers $h -Body $orgBody -ErrorAction Stop
echo     if ($r.success^) { $org = $r.result; Write-Host "  [OK] Created Zero Trust org" }
echo   } catch { Write-Host "  [WARN] Org setup failed"; exit 1 }
echo }
echo $teamName = ($org.auth_domain -replace '\.cloudflareaccess\.com$',''^)
echo.
echo # ensure_otp_idp
echo $idps = (Invoke-RestMethod -Uri "%CF_API%/accounts/$acct/access/identity_providers" -Headers $h -ErrorAction SilentlyContinue^).result
echo $otp = $idps ^| Where-Object { $_.type -eq 'onetimepin' }
echo if (-not $otp^) {
echo   $idpBody = @{ name='Email OTP'; type='onetimepin'; config=@{} } ^| ConvertTo-Json
echo   Invoke-RestMethod -Uri "%CF_API%/accounts/$acct/access/identity_providers" -Method POST -Headers $h -Body $idpBody -ErrorAction SilentlyContinue ^| Out-Null
echo   Write-Host "  [OK] Created email OTP IDP"
echo } else { Write-Host "  [OK] Email OTP IDP exists" }
echo.
echo # ensure_app
echo $apps = (Invoke-RestMethod -Uri "%CF_API%/accounts/$acct/access/apps" -Headers $h -ErrorAction SilentlyContinue^).result
echo $sshApp = $apps ^| Where-Object { $_.domain -eq $sshHost } ^| Select-Object -First 1
echo if (-not $sshApp^) {
echo   $appBody = @{
echo     name='SSH Browser Terminal'; domain=$sshHost; type='ssh'; session_duration='24h'
echo     allowed_idps=@(^); auto_redirect_to_identity=$true; app_launcher_visible=$true
echo     enable_binding_cookie=$false; http_only_cookie_attribute=$false
echo   } ^| ConvertTo-Json
echo   $cr = Invoke-RestMethod -Uri "%CF_API%/accounts/$acct/access/apps" -Method POST -Headers $h -Body $appBody -ErrorAction Stop
echo   $sshApp = $cr.result
echo   Write-Host "  [OK] Created Access app"
echo } else { Write-Host "  [OK] Access app exists" }
echo.
echo # ensure_policy
echo $policies = (Invoke-RestMethod -Uri "%CF_API%/accounts/$acct/access/apps/$($sshApp.id^)/policies" -Headers $h -ErrorAction SilentlyContinue^).result
echo if (-not $policies^) {
echo   $emailRules = $emails ^| ForEach-Object { @{ email = @{ email = $_ } } }
echo   $polBody = @{ name='Allow authorised users'; decision='allow'; include=$emailRules; require=@(^); exclude=@(^); precedence=1 } ^| ConvertTo-Json -Depth 5
echo   Invoke-RestMethod -Uri "%CF_API%/accounts/$acct/access/apps/$($sshApp.id^)/policies" -Method POST -Headers $h -Body $polBody -ErrorAction SilentlyContinue ^| Out-Null
echo   Write-Host "  [OK] Policy created"
echo } else { Write-Host "  [OK] Policies exist" }
echo.
echo # ensure_ssh_ca
echo $ca = (Invoke-RestMethod -Uri "%CF_API%/accounts/$acct/access/apps/$($sshApp.id^)/ca" -Headers $h -ErrorAction SilentlyContinue^).result
echo if (-not $ca -or -not $ca.public_key^) {
echo   $ca = (Invoke-RestMethod -Uri "%CF_API%/accounts/$acct/access/apps/$($sshApp.id^)/ca" -Method POST -Headers $h -ErrorAction SilentlyContinue^).result
echo }
echo.
echo Write-Output ("TEAM_NAME=" + $teamName^)
echo Write-Output ("SSH_APP_AUD=" + $sshApp.aud^)
echo if ($ca.public_key^) { Write-Output ("SSH_CA_KEY=" + $ca.public_key^) }
) > "%_access_ps%"
for /f "tokens=1,* delims==" %%a in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%_access_ps%" 2^>nul') do (
    if "%%a"=="TEAM_NAME" set "TEAM_NAME=%%b"
    if "%%a"=="SSH_APP_AUD" set "SSH_APP_AUD=%%b"
    if "%%a"=="SSH_CA_KEY" set "SSH_CA_KEY=%%b"
)
del "%_access_ps%" 2>nul

if defined SSH_CA_KEY (
    call :save_config "{\"ssh_ca_public_key\":\"!SSH_CA_KEY!\",\"ssh_app_aud\":\"!SSH_APP_AUD!\",\"team_name\":\"!TEAM_NAME!\"}"
    call :ok "SSH short-lived certificate CA generated and saved"
)
call :ok "CF Access configured."
goto :eof

:: ═══════════════════════════════════════════════════════════════════════
::  Step 8 — Deploy ts-relay Worker
:: ═══════════════════════════════════════════════════════════════════════
:step_ts_relay
call :hdr "Step 8: Deploy ts-relay Worker (Tailscale bypass)"
set "_relay_host=ts-relay.!SUBDOMAIN!.workers.dev"

:: Generate ts-relay Worker JS to temp file
set "_relay_js=%TEMP%\erebus_relay_worker_%RANDOM%.js"
set "_relay_gen=%TEMP%\erebus_relay_gen_%RANDOM%.ps1"
(
echo $js = @'
echo // ts-relay Worker -- proxies Tailscale through workers.dev
echo const RELAY_HOST   = '__RELAY_HOST__';
echo const CONTROL_HOST = 'controlplane.tailscale.com';
echo const LOGIN_HOST   = 'login.tailscale.com';
echo const DERP_SERVERS = ['derp1.tailscale.com', 'derp2.tailscale.com', 'derp3.tailscale.com'];
echo export default {
echo   async fetch(request^) {
echo     const url = new URL(request.url^); const path = url.pathname;
echo     if (path === '/derpmap/default'^) return derpMap(^);
echo     if (path === '/derp' ^|^| path.startsWith('/derp?'^)^) {
echo       const upgrade = (request.headers.get('Upgrade'^) ^|^| ''^).toLowerCase(^);
echo       if (upgrade !== 'websocket'^) return new Response('WebSocket upgrade required', { status: 426 }^);
echo       return proxyDerp(request^);
echo     }
echo     if (path.startsWith('/login'^) ^|^| path.startsWith('/a/'^) ^|^| path.startsWith('/oauth'^) ^|^| path.startsWith('/oidc'^)^) return proxyHTTP(request, LOGIN_HOST^);
echo     return proxyHTTP(request, CONTROL_HOST^);
echo   },
echo };
echo function derpMap(^) { return new Response(JSON.stringify({ Version:2, Regions:{ 900:{ RegionID:900, RegionCode:'cf-relay', RegionName:'Cloudflare Relay', Nodes:[{ Name:'900a', RegionID:900, HostName:RELAY_HOST, DERPPort:443, STUNPort:-1, ForceWebsocket:true }] } } }^), { headers:{'Content-Type':'application/json'} }^); }
echo async function proxyHTTP(request, destHost^) { const url=new URL(request.url^); const dest=`https://${destHost}${url.pathname}${url.search}`; const headers=new Headers(^); for (const [k,v] of request.headers^) if (!/^^(cf-^|x-forwarded-^|x-real-ip^)/i.test(k^)^) headers.set(k,v^); headers.set('Host',destHost^); try { return await fetch(dest, { method:request.method, headers, body:['GET','HEAD'].includes(request.method^)?undefined:request.body, redirect:'follow' }^); } catch(e^) { return new Response(`Relay error: ${e.message}`, { status:502 }^); } }
echo async function proxyDerp(request^) { const pair=new WebSocketPair(^); const [client,server]=Object.values(pair^); let upstream=null; for (const host of DERP_SERVERS^) { try { const resp=await fetch(`https://${host}/derp`, { headers:{Upgrade:'websocket',Connection:'Upgrade'}, method:'GET' }^); if (resp.webSocket^) { upstream=resp.webSocket; break; } } catch(_^){} } if (!upstream^) return new Response('Could not reach DERP', { status:502 }^); server.accept(^); upstream.accept(^); server.addEventListener('message',e=^>{try{upstream.send(e.data^)}catch(_^){}}^); upstream.addEventListener('message',e=^>{try{server.send(e.data^)}catch(_^){}}^); server.addEventListener('close',e=^>{try{upstream.close(e.code,e.reason^)}catch(_^){}}^); upstream.addEventListener('close',e=^>{try{server.close(e.code,e.reason^)}catch(_^){}}^); server.addEventListener('error',(^)=^>{try{upstream.close(^)}catch(_^){}}^); upstream.addEventListener('error',(^)=^>{try{server.close(^)}catch(_^){}}^); return new Response(null,{status:101,webSocket:client}^); }
echo '@
echo $js = $js -replace '__RELAY_HOST__', '%_relay_host%'
echo $js ^| Set-Content '%_relay_js%' -NoNewline
) > "%_relay_gen%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%_relay_gen%" 2>nul
del "%_relay_gen%" 2>nul

echo   Deploying 'ts-relay' Worker ...
call :deploy_worker "!ACCT_ID!" "ts-relay" "!_relay_js!"
if not errorlevel 1 (
    echo   %G%OK%X%  -^>  https://!_relay_host!
    call :ok "Tailscale control plane + DERP proxied through workers.dev"
    call :save_config "{\"ts_relay_url\":\"https://!_relay_host!\"}"
) else (
    echo   %R%FAILED%X%
    call :warn "ts-relay deploy failed."
)
del "!_relay_js!" 2>nul
goto :eof

:: ═══════════════════════════════════════════════════════════════════════
::  Step 9 — Build tsnet binary
:: ═══════════════════════════════════════════════════════════════════════
:step_build_tsnet
call :hdr "Step 9: Build tsnet binary (userspace Tailscale)"

:: Connectivity pre-check
echo   Checking Tailscale control plane connectivity...
curl --connect-timeout 5 -sk "https://controlplane.tailscale.com/key?v=71" >nul 2>&1
if errorlevel 1 (
    call :warn "Tailscale control plane unreachable (likely corporate firewall)"
    call :warn "tsnet build will likely fail. CF Tunnel SSH is the recommended path."
    echo.
    echo   %B%1%X%  Skip tsnet (recommended^)
    echo   %B%2%X%  Try anyway
    echo.
    set /p "_tsnet_choice=  [1/2]: "
    if not "!_tsnet_choice!"=="2" (
        call :ok "Skipping tsnet build."
        goto :eof
    )
)

:: Check for Go
set "_go_exe="
if exist "%BIN_DIR%\go-toolchain\bin\go.exe" (
    set "_go_exe=%BIN_DIR%\go-toolchain\bin\go.exe"
    call :ok "Go toolchain already present."
    goto :do_build_tsnet
)
where go >nul 2>&1
if not errorlevel 1 (
    set "_go_exe=go"
    call :ok "System Go found."
    goto :do_build_tsnet
)

:: Download Go
echo   Downloading Go toolchain...
set "_go_dl_ps=%TEMP%\erebus_go_%RANDOM%.ps1"
(
echo [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
echo try {
echo   $releases = Invoke-RestMethod -Uri 'https://go.dev/dl/?mode=json' -ErrorAction Stop
echo   $rel = $releases ^| Where-Object { $_.stable -eq $true } ^| Select-Object -First 1
echo   $ver = $rel.version -replace '^go',''
echo   $file = $rel.files ^| Where-Object { $_.os -eq 'windows' -and $_.arch -eq 'amd64' -and $_.kind -eq 'archive' } ^| Select-Object -First 1
echo   $url = "https://go.dev/dl/go$ver.windows-amd64.zip"
echo   $dest = '%BIN_DIR%\go-windows-amd64.zip'
echo   Write-Host "  Downloading Go $ver ..."
echo   Invoke-WebRequest -Uri $url -OutFile $dest -ErrorAction Stop
echo   if ($file.sha256^) {
echo     $actual = (Get-FileHash $dest -Algorithm SHA256^).Hash.ToLower(^)
echo     if ($actual -ne $file.sha256^) { Write-Host "  SHA256 mismatch!"; Remove-Item $dest; exit 1 }
echo     Write-Host "  SHA256 verified."
echo   }
echo   Write-Host "  Extracting ..."
echo   Expand-Archive -Path $dest -DestinationPath '%BIN_DIR%' -Force
echo   if (Test-Path '%BIN_DIR%\go'^) { Rename-Item '%BIN_DIR%\go' '%BIN_DIR%\go-toolchain' -Force }
echo   Remove-Item $dest -Force
echo   Write-Output 'OK'
echo } catch {
echo   Write-Host "  Go download failed: $_"
echo   Write-Output 'FAIL'
echo }
) > "%_go_dl_ps%"
set "_go_dl_result="
for /f "delims=" %%r in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%_go_dl_ps%" 2^>nul') do set "_go_dl_result=%%r"
del "%_go_dl_ps%" 2>nul
if "!_go_dl_result!"=="OK" (
    set "_go_exe=%BIN_DIR%\go-toolchain\bin\go.exe"
) else (
    call :warn "Go download failed. Install manually from https://go.dev/dl/"
    goto :eof
)

:do_build_tsnet
set "_tsnet_src=%REPO_ROOT%\tsnet"
set "_tsnet_exe=%BIN_DIR%\tsnet.exe"
if not exist "%_tsnet_src%\main.go" (call :warn "tsnet\main.go not found." & goto :eof)

set "GONOSUMDB=*"
set "GOFLAGS=-mod=mod"

echo   Fetching latest tailscale.com ...
"!_go_exe!" get tailscale.com@latest 2>nul
echo   Running go mod tidy ...
cd /d "%_tsnet_src%"
"!_go_exe!" mod tidy 2>nul
if errorlevel 1 (call :warn "go mod tidy failed." & cd /d "%REPO_ROOT%" & goto :eof)

echo   Building tsnet.exe ...
set "GOOS=windows"
set "GOARCH=amd64"
"!_go_exe!" build -ldflags "-s -w" -o "!_tsnet_exe!" . 2>&1
if errorlevel 1 (
    call :err "Build failed."
    cd /d "%REPO_ROOT%"
    goto :eof
)
cd /d "%REPO_ROOT%"
call :ok "tsnet.exe built: !_tsnet_exe!"
set "TSNET_OK=true"
goto :eof

:: ═══════════════════════════════════════════════════════════════════════
::  Save config + cf_config.txt
:: ═══════════════════════════════════════════════════════════════════════
:step_save
call :hdr "Saving configuration"
set "SSH_HOST=ssh.!SUBDOMAIN!.workers.dev"

set "_cfg_json={\"account_id\":\"!ACCT_ID!\",\"subdomain\":\"!SUBDOMAIN!\",\"tunnel_id\":\"!TUNNEL_ID!\",\"kv_ns_id\":\"!KV_NS_ID!\",\"ssh_host\":\"!SSH_HOST!\"}"
if defined TUNNEL_TOKEN set "_cfg_json={\"account_id\":\"!ACCT_ID!\",\"subdomain\":\"!SUBDOMAIN!\",\"tunnel_id\":\"!TUNNEL_ID!\",\"kv_ns_id\":\"!KV_NS_ID!\",\"ssh_host\":\"!SSH_HOST!\",\"tunnel_token\":\"!TUNNEL_TOKEN!\"}"

call :save_config "!_cfg_json!"
call :ok "Config saved to %CFG_FILE%"

:: Write cf_config.txt
(
    if exist "%CF_CFG_TXT%" (
        for /f "usebackq tokens=1,* delims==" %%a in ("%CF_CFG_TXT%") do (
            if /i not "%%a"=="CF_HOST" echo %%a=%%b
        )
    )
    echo CF_HOST=!SSH_HOST!
) > "%CF_CFG_TXT%"
call :ok "cf_config.txt updated: CF_HOST=!SSH_HOST!"
goto :eof

:: ═══════════════════════════════════════════════════════════════════════
::  Summary
:: ═══════════════════════════════════════════════════════════════════════
:print_summary
set "SSH_HOST=ssh.!SUBDOMAIN!.workers.dev"
call :config_val tunnel_token _sum_tok
call :config_val ssh_ca_public_key _sum_ca

echo.
echo ==========================================================
echo   %G%%B%Bootstrap complete!%X%
echo ==========================================================
echo.
echo   Your endpoints:
echo     Browser SSH : %C%https://!SSH_HOST!%X%  (CF Access login)
echo     TS relay    : %C%https://ts-relay.!SUBDOMAIN!.workers.dev%X%  (Tailscale bypass)
echo.

if %EMAIL_COUNT% gtr 0 (
    set "_all_emails="
    for /l %%i in (1,1,%EMAIL_COUNT%) do (
        if defined _all_emails (set "_all_emails=!_all_emails!, !ARG_EMAIL_%%i!") else (set "_all_emails=!ARG_EMAIL_%%i!")
    )
    echo   CF Access (OTP email^): !_all_emails!
)
if defined _sum_ca echo   Short-lived SSH certs: %G%ENABLED%X%
echo.

set "_home_args=--token !_sum_tok!"
if defined _sum_ca set "_home_args=!_home_args! --ca-key "!_sum_ca!""
set "_home_args=!_home_args! --ssh-host !SSH_HOST!"

echo   %G%%B%What to do next:%X%
echo.
echo   %C%STEP 1 -- Set up your HOME machine%X% (the one you SSH into)
echo   Copy installers\ to your home machine, then run:
echo.
echo     %Y%Linux / Mac:%X%
echo       chmod +x home_linux_mac.sh
echo       sudo ./home_linux_mac.sh !_home_args!
echo.
echo     %Y%Windows (as Administrator):%X%
echo       home_windows.bat !_sum_tok! "!_sum_ca!" !SSH_HOST!
echo.
echo   %C%STEP 2 -- Set up your WORK machine%X% (the one you connect from)
echo   Copy installers\ to your work machine, then run:
echo.
echo     %Y%Linux / Mac:%X%
echo       chmod +x work_linux_mac.sh ^&^& ./work_linux_mac.sh --ssh-host !SSH_HOST!
echo.
echo     %Y%Windows (no admin needed):%X%
echo       work_windows.bat !SSH_HOST!
echo.
echo   %C%STEP 3 -- Connect%X%
echo     Browser : https://!SSH_HOST!  (email OTP login)
echo     CLI     : ssh YOUR_USER@!SSH_HOST!
echo.
if "!TSNET_OK!"=="true" (
    echo   %G%[ok]%X% tsnet.exe built -- run:  %BIN_DIR%\tsnet.exe up
) else (
    echo   %Y%[!!]%X% tsnet.exe not built. Run later:  %~nx0 --build-tsnet
)
echo      Peers:  %BIN_DIR%\tsnet.exe status
echo      SSH:    ssh -o "ProxyCommand=%BIN_DIR%\tsnet.exe proxy %%h %%p" user@peer
echo.
goto :eof

:end
endlocal
