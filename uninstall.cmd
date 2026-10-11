@echo off
setlocal
title SH2NR uninstaller
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\uninstall.ps1" %*
echo.
pause
