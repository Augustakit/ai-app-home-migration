@echo off
rem Double-click launcher for the DSH migration wizard (pure PowerShell, no Python).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Wizard.ps1" %*
exit /b %ERRORLEVEL%
