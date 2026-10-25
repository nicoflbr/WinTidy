@echo off
REM Start WinTidy (menu). Requests admin rights. Parameters are passed through, e.g.:
REM   WinTidy.cmd -Mode Scan -OpenReport
cd /d "%~dp0"
net session 1>NUL 2>NUL
if errorlevel 1 goto :elevate
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0WinTidy.ps1" %*
exit /b

:elevate
REM Pass path and parameters via environment variables (robust with apostrophes and spaces in the path)
set "WT_PS1=%~dp0WinTidy.ps1"
set "WT_ARGS=%*"
powershell.exe -NoProfile -Command "Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -NoExit -File \"{0}\" {1}' -f $env:WT_PS1, $env:WT_ARGS)"
exit /b
