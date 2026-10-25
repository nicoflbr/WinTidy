@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Probe-Display.ps1" > "%~dp0probe-display.log" 2>&1
