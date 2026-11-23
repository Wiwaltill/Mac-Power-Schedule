#!/bin/bash
# Finish after the app exits, when AppKit can no longer recreate preferences/state.
set -euo pipefail
[[ $EUID -ne 0 && $# -eq 1 && "$1" =~ ^[1-9][0-9]*$ && -n "$HOME" && "$HOME" != / ]] || exit 1
while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
identifier='de.wiwaltill.MacPowerSchedule.app'
/usr/bin/defaults delete "$identifier" >/dev/null 2>&1 || true
/bin/rm -rf "$HOME/Library/Application Support/MacPowerSchedule" \
    "$HOME/Library/Caches/$identifier" \
    "$HOME/Library/HTTPStorages/$identifier" \
    "$HOME/Library/WebKit/$identifier" \
    "$HOME/Library/Saved Application State/$identifier.savedState"
