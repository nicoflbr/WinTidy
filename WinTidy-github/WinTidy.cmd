@echo off
REM WinTidy starten (Menue). Fordert Adminrechte an. Parameter werden durchgereicht, z. B.:
REM   WinTidy.cmd -Mode Scan -OpenReport
cd /d "%~dp0"
net session 1>NUL 2>NUL
if errorlevel 1 goto :elevate
powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0WinTidy.ps1" %*
exit /b

:elevate
REM Pfad und Parameter ueber Umgebungsvariablen uebergeben (robust bei Apostrophen und Leerzeichen im Pfad)
set "WT_PS1=%~dp0WinTidy.ps1"
set "WT_ARGS=%*"
powershell.exe -NoProfile -Command "Start-Process -FilePath powershell.exe -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -NoExit -File \"{0}\" {1}' -f $env:WT_PS1, $env:WT_ARGS)"
exit /b
