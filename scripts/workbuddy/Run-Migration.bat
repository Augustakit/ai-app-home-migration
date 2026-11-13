@echo off
setlocal
set "TOOL=%~dp0Migrate-AppDataDirs.ps1"
set "SRC=<APP_HOME>"
set "DST=<TARGET_ROOT>"
set "NAMES='binaries','plugins','cache'"
set "GUARD=<PROCESS>"
echo Edit SRC / DST / NAMES / GUARD at the top of this file before running.
echo This first run is a dry run (-WhatIf). Remove -WhatIf to actually migrate.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%TOOL%' -SourceRoot '%SRC%' -TargetRoot '%DST%' -Directories @(%NAMES%) -GuardProcess '%GUARD%' -Interactive -WhatIf"
echo.
pause
