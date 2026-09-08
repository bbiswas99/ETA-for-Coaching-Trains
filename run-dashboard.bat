@echo off
title Indian Railways ETA Dashboard
echo =================================================================
echo   STARTING INDIAN RAILWAYS TELEMETRY DASHBOARD (OFFLINE/LOCAL)
echo =================================================================
echo.
echo Launching your default browser at http://localhost:3000 ...
start http://localhost:3000
echo.
where node >nul 2>nul
if %ERRORLEVEL% equ 0 (
    echo Starting Node.js server...
    node server.js
    goto end
)

where python >nul 2>nul
if %ERRORLEVEL% equ 0 (
    echo Starting Python HTTP server...
    python -m http.server 3000
    goto end
)

echo Warning: Neither Node.js nor Python was found in PATH.
echo Please open index.html using an HTTP server (e.g., Live Server in VS Code).
pause

:end
