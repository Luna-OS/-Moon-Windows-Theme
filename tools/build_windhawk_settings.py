"""Wandelt die Windhawk-Styles (windhawk/*.yaml) in das flache Format um,
in dem Windhawk Mod-Einstellungen speichert, z. B.

    controlStyles[0].target = "Border#AcrylicBorder"
    controlStyles[0].styles[0] = "Background:=..."

Der Moon Installer (app/MoonInstaller.ps1) liest diese JSON-Dateien und
traegt sie direkt in Windhawk ein.

Aufruf:  python tools/build_windhawk_settings.py
Benoetigt: pip install pyyaml
"""
import json
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "windhawk"
OUT = SRC / "json"

# Datei -> (Windhawk-Mod-ID, Anzeigename, standardmaessig ausgewaehlt)
MODS = {
    "start-menu.yaml": ("windows-11-start-menu-styler", "Windows 11 Start Menu Styler", "Startmenü", True),
    "taskbar.yaml": ("windows-11-taskbar-styler", "Windows 11 Taskbar Styler", "Taskleiste", True),
    "notification-center.yaml": ("windows-11-notification-center-styler", "Windows 11 Notification Center Styler", "Infocenter", True),
    "file-explorer.yaml": ("windows-11-file-explorer-styler", "Windows 11 File Explorer Styler", "Explorer", True),
    "settings.yaml": ("windows-11-settings-styler", "Windows 11 Settings Styler", "Einstellungen", True),
    "translucent-windows.yaml": ("translucent-windows", "Translucent Windows", "Klassische Programme (optional)", False),
}

# Styler-Mods haben ein "theme"-Feld; leer = kein eingebautes Theme, nur Moon.
STYLERS_WITH_THEME = {
    "windows-11-start-menu-styler",
    "windows-11-taskbar-styler",
    "windows-11-notification-center-styler",
    "windows-11-file-explorer-styler",
    "windows-11-settings-styler",
}


def flatten(value, prefix, out):
    if isinstance(value, dict):
        for key, child in value.items():
            flatten(child, f"{prefix}.{key}" if prefix else key, out)
    elif isinstance(value, list):
        for i, child in enumerate(value):
            flatten(child, f"{prefix}[{i}]", out)
    elif isinstance(value, bool):
        out[prefix] = int(value)
    elif isinstance(value, int):
        out[prefix] = value
    elif value is None:
        out[prefix] = ""
    else:
        out[prefix] = str(value)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    index = []
    for file_name, (mod_id, mod_name, label, default) in MODS.items():
        data = yaml.safe_load((SRC / file_name).read_text(encoding="utf-8"))
        settings = {}
        if mod_id in STYLERS_WITH_THEME:
            settings["theme"] = ""
        flatten(data, "", settings)
        top_keys = sorted({k.split("[")[0].split(".")[0] for k in settings})
        doc = {
            "modId": mod_id,
            "modName": mod_name,
            "label": label,
            "selectedByDefault": default,
            "source": f"windhawk/{file_name}",
            "managedKeys": top_keys,
            "settings": settings,
        }
        target = OUT / f"{mod_id}.json"
        target.write_text(json.dumps(doc, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        index.append(mod_id)
        print(f"{target.relative_to(ROOT)}: {len(settings)} Werte")
    (OUT / "index.json").write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
