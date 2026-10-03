@echo off
rem Moon Installer starten (Doppelklick)
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0app\MoonInstaller.ps1"
