@echo off
rem Moon Theme entfernen (Doppelklick)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
pause
