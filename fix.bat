@echo off
cd /d "%~dp0"
echo ============================================
echo  Clash Verge old-CPU core fix
echo ============================================
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-core.ps1"
echo.
pause

