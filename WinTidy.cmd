@echo off
REM Start WinTidy (menu). Requests admin rights. Parameters are passed through, e.g.:
REM   WinTidy.cmd -Mode Scan -OpenReport
cd /d "%~dp0"
"%SystemRoot%\System32\net.exe" session 1>NUL 2>NUL
if errorlevel 1 goto :elevate
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0WinTidy.ps1" %*
exit /b

:elevate
REM Pass path and parameters via environment variables (robust with apostrophes and spaces in the path)
set "WT_PS1=%~dp0WinTidy.ps1"
set "WT_ARGS=%*"
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -Command "Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -NoExit -File \"{0}\" {1}' -f $env:WT_PS1, $env:WT_ARGS)"
exit /b
