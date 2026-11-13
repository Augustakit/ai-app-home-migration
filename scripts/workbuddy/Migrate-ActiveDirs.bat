@echo off
setlocal
set "TOOL=%~dp0Migrate-AppDataDirs.ps1"
set "SRC=<APP_HOME>"
set "DST=<TARGET_ROOT>"
set "NAMES='app','logs','traces','cache','projects'"
set "GUARD=<PROCESS>"
echo Close the application COMPLETELY before running this (tray + Task Manager).
echo Edit SRC / DST / NAMES / GUARD at the top of this file first.
echo This first run is a dry run (-WhatIf). Remove -WhatIf to actually migrate.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%TOOL%' -SourceRoot '%SRC%' -TargetRoot '%DST%' -Directories @(%NAMES%) -GuardProcess '%GUARD%' -Interactive -WhatIf"
echo.
echo After migration, choose D in the interactive prompt (or re-run with -CleanupMode Delete) to free the space.
pause
