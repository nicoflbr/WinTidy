@echo off
REM Start the WinTidy app (graphical interface). Asks once for administrator rights.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0WinTidy-App.ps1"
