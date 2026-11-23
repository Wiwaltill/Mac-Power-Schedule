#!/bin/bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Bitte mit sudo ausführen.' >&2; exit 1; }
base='/Library/Application Support/MacPowerSchedule'
label='de.wiwaltill.MacPowerSchedule'
[[ ! -L "$base" ]] || { echo 'Unsicheres Zielverzeichnis.' >&2; exit 1; }
if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "system/$label"
fi
helper="${1:-$base/PowerScheduler}"
[[ -x "$helper" ]] || { echo 'Helper fehlt; bitte über die vollständige App deinstallieren.' >&2; exit 1; }
"$helper" --remove-owned-events
/bin/rm -f "/Library/LaunchDaemons/$label.plist"
/bin/rm -rf "$base"
echo 'Systemdienst, Konfiguration, Protokolle und eigene Start-/Wecktermine entfernt.'
echo 'Bei CLI-Deinstallation: App-Autostart, App und lokale Benutzerdaten separat entfernen.'
