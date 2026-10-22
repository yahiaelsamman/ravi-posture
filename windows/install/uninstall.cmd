@echo off
rem Double-click to remove Ravi. Add -Purge after the quotes to delete your stretch history too.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
echo.
pause
