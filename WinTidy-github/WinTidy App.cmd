@echo off
REM WinTidy App starten (grafische Oberflaeche). Fragt einmal nach Administratorrechten.
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0WinTidy-App.ps1"
