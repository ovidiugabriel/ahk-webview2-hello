@echo off
rem Runs `autohotkey main.ahk` in self-test mode; see run_test.ps1. Exit code 0 = success.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_test.ps1" %*
exit /b %ERRORLEVEL%
