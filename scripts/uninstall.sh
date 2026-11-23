#!/bin/bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Bitte mit sudo ausführen.' >&2; exit 1; }
base='/Library/Application Support/MacPowerSchedule'
label='de.wiwaltill.MacPowerSchedule'
[[ ! -L "$base" ]] || { echo 'Unsicheres Zielverzeichnis.' >&2; exit 1; }
if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "system/$label"
fi
if [[ -x "$base/PowerScheduler" ]]; then
    "$base/PowerScheduler" --remove-owned-events
fi
/bin/rm -f "/Library/LaunchDaemons/$label.plist"
/bin/rm -rf "$base"
echo 'Systemdienst, Konfiguration, Protokolle und eigene Start-/Wecktermine entfernt.'
echo 'App und lokale Entwürfe können jetzt gelöscht werden; ggf. zuvor den App-Autostart deaktivieren.'
