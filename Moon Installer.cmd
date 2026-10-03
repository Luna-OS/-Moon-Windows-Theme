@echo off
title Moon Installer
rem Moon Installer starten (Doppelklick). Bei einem Fehler bleibt dieses Fenster offen.
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0app\MoonInstaller.ps1"
if errorlevel 1 pause
