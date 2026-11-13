@echo off
rem ============================================================
rem  ZCode data migration finisher launcher (double-click entry)
rem  Pairs with finish_migration.ps1 in the same folder.
rem  Requirement: ZCode FULLY exited (check the tray icon).
rem ============================================================
chcp 65001 >nul
set "DST="
set "EXE="
echo ==============================================
echo  ZCode data migration finisher
echo  Make sure ZCode is FULLY exited before continue.
echo ==============================================
set /p DST=Target .zcode full path (e.g. X:\ZCodeHome\.zcode):
if "%DST%"=="" (
  echo [ERROR] target path is required.
  pause
  exit /b 1
)
set /p EXE=ZCode.exe full path for relaunch after finish (leave blank to skip):
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0finish_migration.ps1" -Dst "%DST%" -ZcodeExe "%EXE%"
echo.
pause
