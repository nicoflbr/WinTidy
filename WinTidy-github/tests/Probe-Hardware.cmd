@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Probe-Hardware.ps1"
timeout /t 5 >nul
