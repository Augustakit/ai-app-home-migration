@echo off
chcp 65001 >nul
setlocal
REM Replace ALL three placeholders below before running.
set "SRC=<APP_HOME>"
set "DST=<TARGET_ROOT>"
set "GUARD=<PROCESS>"
echo === Whole-home migration : DRY RUN ===
echo Source : %SRC%
echo Target : %DST%
echo Guard  : %GUARD%
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Migrate-WholeHome.ps1" -SourceRoot "%SRC%" -TargetRoot "%DST%" -GuardProcess "%GUARD%" -WhatIf
echo.
echo This was a DRY RUN. No files were changed.
echo To actually migrate: remove -WhatIf from the command above.
echo To clean the backup later: keep the script path and add -CleanupBackup.
echo.
pause
