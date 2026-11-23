#!/bin/bash
set -euo pipefail
# Called only by the app's macOS administrator authorization dialog.
[[ $EUID -eq 0 && $# -eq 2 ]] || { echo 'Administratorrechte und zwei Argumente erforderlich.' >&2; exit 1; }
base='/Library/Application Support/MacPowerSchedule'
label='de.wiwaltill.MacPowerSchedule'
plist="/Library/LaunchDaemons/$label.plist"
[[ ! -L "$base" ]] || { echo 'Unsicheres Zielverzeichnis.' >&2; exit 1; }
/usr/bin/install -d -o root -g wheel -m 755 "$base"
# Do not restart a running preparation: the worker notices changes itself.
/usr/bin/install -o root -g wheel -m 755 "$2" "$base/PowerScheduler.new"
/usr/bin/install -o root -g wheel -m 644 "$1" "$base/configuration.json.new"
/bin/mv -f "$base/PowerScheduler.new" "$base/PowerScheduler"
/bin/mv -f "$base/configuration.json.new" "$base/configuration.json"
/bin/cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>de.wiwaltill.MacPowerSchedule</string>
<key>ProgramArguments</key><array><string>/Library/Application Support/MacPowerSchedule/PowerScheduler</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>30</integer>
<key>ProcessType</key><string>Background</string>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
</dict></plist>
PLIST
/usr/sbin/chown root:wheel "$plist"
/bin/chmod 644 "$plist"
if ! /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    /bin/launchctl bootstrap system "$plist"
fi
