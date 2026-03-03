@echo off
:: ─────────────────────────────────────────────────────────────────────────────
:: portal.bat  –  Launch the SSH Portal (finds Python without MS Store stub)
:: ─────────────────────────────────────────────────────────────────────────────
setlocal EnableDelayedExpansion

set "DIR=%~dp0"
set "DIR=%DIR:~0,-1%"

:: ── find Python (explicit paths, no MS Store stub) ───────────────────────────
set "PY="

:: 1. Python 3.11 (the one we know works)
if exist "%LOCALAPPDATA%\Programs\Python\Python311\python.exe" (
    set "PY=%LOCALAPPDATA%\Programs\Python\Python311\python.exe"
    goto :found
)
:: 2. Any Python3xx installation under LOCALAPPDATA
for /d %%D in ("%LOCALAPPDATA%\Programs\Python\Python3*") do (
    if exist "%%D\python.exe" (
        set "PY=%%D\python.exe"
        goto :found
    )
)
:: 3. Check PATH entries for a python.exe that is NOT the Store stub
for %%P in (python.exe) do (
    set "CANDIDATE=%%~$PATH:P"
    if defined CANDIDATE (
        echo !CANDIDATE! | find /i "WindowsApps" >nul 2>&1
        if errorlevel 1 (
            set "PY=!CANDIDATE!"
            goto :found
        )
    )
)

echo [error] Python 3 not found. Install Python 3.11+ from python.org (user install, no admin needed).
pause
exit /b 1

:found
echo [portal] Using Python: %PY%
"%PY%" "%DIR%\portal.py" %*
