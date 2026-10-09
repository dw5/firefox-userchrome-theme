@echo off
rem firefox-userchrome-theme - double-click launcher for install.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
echo.
pause
