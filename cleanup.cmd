@echo off
rem Double-click to remove generated files (lib\, logs\, %LOCALAPPDATA%\ahk-webview2-hello).
rem See cleanup.ps1 for details. Source files are never touched.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cleanup.ps1"
set RC=%ERRORLEVEL%
if not "%RC%"=="0" echo. & echo Cleanup FAILED (exit code %RC%).
echo.
pause
exit /b %RC%
