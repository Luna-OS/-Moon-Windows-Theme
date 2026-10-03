@echo off
title Moon - Bilder neu erzeugen
rem Nur fuer Entwickler: erzeugt Hintergruende, Sternenhimmel, Ordnersymbole und Start-Logo neu.
rem Zum Anwenden auf Windows bitte "Moon Installer.cmd" benutzen!
echo.
echo   Moon - Bilder neu erzeugen
echo   ==========================
echo   Hinweis: Das ist nur fuer Entwickler. Die fertigen Bilder liegen schon im Ordner "theme".
echo   Zum Anwenden auf Windows "Moon Installer.cmd" im Hauptordner starten.
echo.
where python >nul 2>nul
if errorlevel 1 (
  echo   Python wurde nicht gefunden. Installieren: https://www.python.org/downloads/
  echo.
  pause
  exit /b 1
)
echo   Installiere benoetigte Pakete ...
python -m pip install --quiet pillow numpy pyyaml
echo   Erzeuge Bilder ...
python "%~dp0generate_wallpapers.py"
python "%~dp0generate_icons.py"
python "%~dp0generate_sounds.py"
python "%~dp0build_windhawk_settings.py"
echo.
echo   Fertig.
pause
