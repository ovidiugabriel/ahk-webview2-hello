@echo off
rem Installs AutoHotkey v2, checks the WebView2 Runtime and fetches lib\WebView2Loader.dll.
rem See install_deps.ps1 for details; the run is logged to logs\install.log.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_deps.ps1" %*
exit /b %ERRORLEVEL%
