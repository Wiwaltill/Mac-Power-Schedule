# Bedienung und Betrieb

Eine native macOS-App für geplantes Einschalten und sicheres Herunterfahren – mit geordneten Vorbereitungsaktionen für VirtualBox, eigene Befehle und Apps. Für Intel-Macs und Apple Silicon, ab macOS 13 (Ventura), einschließlich macOS Sequoia. Oberfläche auf Deutsch, MIT-Lizenz.

## Funktionen

- Ein gemeinsamer Tagesplan, getrennte Zeiten für Montag–Freitag/Samstag–Sonntag oder ein Plan je Wochentag.
- Einschalten und Herunterfahren je Tag/Gruppe separat abschaltbar.
- Sortierbare Vorbereitungsaktionen, jeweils aktivierbar und mit Zeitlimit.
- **VirtualBox:** ACPI-Powerbutton senden, dann mit `showvminfo --machinereadable` bis `VMState="poweroff"` warten. Kein erzwungenes Ausschalten. Eine bereits ausgeschaltete VM ist erfolgreich; pausierte, gespeicherte oder fehlerhafte VMs führen zum Abbruch.
- **Shell:** eigene zsh-Befehle, einschließlich SSH, Skripten und anderen VM-Werkzeugen.
- **App:** Anwendung öffnen und auf ihr Beenden warten (`open -W -a`).
- Jeder Fehler bricht die Aktionskette und den Shutdown ab. Ein fehlgeschlagener Termin wird nicht automatisch wiederholt.
- Menüleiste, Dienstprotokoll, optionaler App-Start bei Anmeldung und Fehlermitteilungen, solange die App läuft.
- Separater `launchd`-Systemdienst: Zeitplan funktioniert auch bei geschlossener App und ohne angemeldete Sitzung. GUI-Aktionen brauchen eine Sitzung.

## Bauen und starten

Voraussetzung: vollständiges Xcode mit Swift 6, aktive Command Line Tools (`xcode-select`). Keine externen Paketabhängigkeiten.

```sh
git clone https://github.com/Wiwaltill/Mac-Power-Schedule.git
cd Mac-Power-Schedule
swift test
./scripts/build-app.sh
open "dist/Mac Power Schedule.app"
```

Das Skript baut eine Universal-App für **x86_64 und arm64**, prüft ihre Signatur und erzeugt `dist/Mac-Power-Schedule.zip`. Die `.app` am besten nach `/Applications` kopieren, bevor der optionale Login-Start aktiviert wird. `swift run PowerSchedule` kann die Oberfläche entwickeln, installiert aber keinen Dienst; dafür das vollständige App-Bundle benutzen.

GitHub Actions testet und baut bei Push und Pull Request, ohne ein Release anzulegen. Ein veröffentlichtes GitHub Release startet den separaten Release-Workflow: Er baut den Stand des Release-Tags, signiert App und Helper mit Developer ID, wartet auf Apples Notarisierung und hängt erst nach erfolgreicher Prüfung ZIP und Prüfsumme an dieses vorhandene Release. Tags haben das Format `v1.2.3` oder `1.2.3`; die App-Version folgt dem Tag. Wähle für neue Release-Tags einen Commit mit dem Release-Workflow. Bereits vorhandene Dateien werden nicht ersetzt.

Über „verify_only“ kann die vollständige Signierungs- und Notarisierungskette ohne Änderungen an Release-Dateien geprüft werden.

Für ein bereits vorhandenes Release lässt sich der Workflow „Build app for published release“ unter Actions manuell mit dessen Tag starten. Wenn gleichnamige Assets existieren, bricht der Upload ab, damit insbesondere manuell hochgeladene signierte Builds erhalten bleiben.

## Einrichten

1. Gewünschte Zeitplan-Aufteilung und Zeiten im 24-Stunden-Format `HH:mm` wählen. Ein Moduswechsel verwendet die Einstellungen von Montag für „Alle Tage“/„Mo–Fr“ und Samstag für „Sa–So“; die übrigen Einzeltage bleiben gespeichert.
2. Aktionen hinzufügen und mit den Pfeilen in die gewünschte Reihenfolge bringen. Für VirtualBox den exakten VM-Namen oder die UUID verwenden (`VBoxManage list vms`). Standardpfad: `/Applications/VirtualBox.app/Contents/MacOS/VBoxManage`.
3. **Vorbereitung testen …** führt die Aktionen wirklich aus, einschließlich VM-Shutdowns, jedoch **ohne anschließenden Mac-Shutdown**. Für den Test muss ein bereits installierter Zeitplan zunächst deaktiviert und angewendet sein. Der Test verlangt eine zusätzliche Bestätigung. Ergebnis unter „Protokoll & Test“.
4. „Zeitplan aktivieren“ einschalten und **Speichern & anwenden …** wählen. macOS fragt nach Administratorrechten. Die Freigabe wird auch für spätere Änderungen am installierten Plan benötigt.
5. Optional die App bei Anmeldung öffnen und Mitteilungen erlauben. Der Dienst arbeitet unabhängig davon weiter; Fehler bleiben auch ohne App im Protokoll erhalten.

Die Shutdown-Zeit ist der **Beginn der Vorbereitung**. Bei zwei VMs mit je bis zu 180 Sekunden Zeitlimit erfolgt der eigentliche Shutdown entsprechend später. Aktionen laufen nacheinander. Bei einer Planänderung während der Vorbereitung wird nach Ende der laufenden Aktionen der Shutdown abgebrochen; bereits ausgeführte Aktionen werden nicht rückgängig gemacht.

### VirtualBox / Home Assistant / Homebridge

Je VM eine VirtualBox-Aktion anlegen, beispielsweise „Home Assistant sauber stoppen“ und „Homebridge sauber stoppen“. Die konkreten VM-Namen trägst du selbst ein. Der Gast muss ACPI-Shutdown unterstützen und darauf korrekt reagieren. Wähle das Zeitlimit passend zum Gast, etwa 180–300 Sekunden. Ein Gast kann trotz erfolgreichen ACPI-Signals weiterlaufen; deshalb prüft der Dienst den tatsächlichen Zustand.

Die VMs gehören zum **Benutzer, der den Zeitplan anwendet**. Der Dienst führt `VBoxManage` und sämtliche eigenen Aktionen unter dessen UID mit dessen HOME aus. Root besitzt seine eigene VirtualBox-Konfiguration und wird deshalb nicht als VM-Benutzer verwendet.

### Shell und Apps

Shell-Befehle laufen unter `/bin/zsh -c`, ohne interaktive Shell-Profile und mit dem Home-Verzeichnis als Arbeitsverzeichnis. Im Dienst gilt ein definierter PATH: `/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin`. Verwende absolute Pfade und einen aussagekräftigen Exit-Code. Ein Exit-Code ungleich null bricht den Shutdown ab. Die Standard-Eingabe ist geschlossen; Passwortabfragen sind nicht möglich.

Beispiel für einen SSH-Befehl mit bereits eingerichteter Schlüsselanmeldung und bekanntem Host-Key:

```sh
/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 server-user@server /absolute/path/to/prepare-shutdown
```

Ein erfolgreicher SSH-Aufruf bestätigt nur dessen Exit-Code. Soll auf einen entfernten Dienstzustand gewartet werden, muss dein Skript ihn prüfen. Keine Kennwörter/Tokens in die Konfiguration schreiben; nutze Schlüsseldateien bzw. geeignete lokale Zugangsdaten. Schlüsselbund, TCC und andere Rechte sind in einer nicht interaktiven Dienstsitzung möglicherweise nicht verfügbar.

Bei Apps wartet die Aktion bis zum Beenden der Anwendung. Eine dauerhaft geöffnete App erreicht ihr Zeitlimit und verhindert den Shutdown. GUI-Starts aus einem Systemdienst sind sitzungsabhängig; für unbeaufsichtigten Betrieb CLI-Befehle oder Skripte bevorzugen. Der lokale Vorbereitungstest hat die Rechte und Umgebung deiner angemeldeten Sitzung und ersetzt keinen Test des installierten Dienstes.

Prozess-Zeitlimits beenden die Prozessgruppe der Aktion einschließlich gewöhnlicher Kindprozesse. Programme, die sich bewusst daemonisieren oder anderweitig abkoppeln, können sich dem entziehen. Apps werden bei einem Zeitlimit nicht zwangsweise beendet; der Mac bleibt eingeschaltet.

## Wie der Zeitplan arbeitet

Der root-eigene Dienst prüft alle 15 Sekunden die installierte Konfiguration. Er registriert über Apples IOKit-Power-Management-API (denselben Systemmechanismus, den `pmset` bedient) die nächsten acht Kalendertage als einzelne `wakepoweron`-Termine. Das erlaubt unterschiedliche Zeiten je Wochentag. Zusätzlich registriert er `wake`-Termine zu Shutdown-Zeiten, um einen schlafenden Mac für die Vorbereitung zu wecken, ohne einen ausgeschalteten Mac dafür einzuschalten.

Nur Termine mit der Kennung `de.wiwaltill.MacPowerSchedule` werden verwaltet und bei Deaktivierung entfernt. Fremde Termine und bestehende `pmset repeat`-Pläne bleiben erhalten und können den Mac unabhängig von dieser App starten oder herunterfahren. Prüfen mit:

```sh
pmset -g sched
launchctl print system/de.wiwaltill.MacPowerSchedule
tail -f '/Library/Application Support/MacPowerSchedule/scheduler.log'
```

Die lokale Zeitzone des Macs gilt; Änderungen werden beim nächsten Dienstzyklus berücksichtigt. Bei der Sommerzeitumstellung wird eine nicht existente Uhrzeit auf die nächste gültige Zeit verschoben; eine doppelte Uhrzeit wird nur einmal ausgeführt. Verpasste Shutdowns werden nach 90 Sekunden nicht nachgeholt. Der letzte begonnene Shutdown wird vor der ersten Aktion dauerhaft gespeichert, damit ein Dienstneustart keine Wiederholung auslöst.

### Wichtige Betriebsgrenzen

- Automatisches Einschalten benötigt Netzstrom und unterstützte Hardware/Firmware. Nach Stromausfällen bzw. Änderungen an der Stromversorgung auf dem konkreten Mac prüfen.
- Mit FileVault muss nach dem Start manuell entsperrt werden. Die App verändert FileVault oder automatische Anmeldung nicht.
- Automatischer VM-Start nach Boot/Anmeldung ist separat einzurichten. Diese App übernimmt die Shutdown-Vorbereitung.
- Nur der durch diese App ausgelöste Shutdown führt Vorbereitungsaktionen aus. Manuelles Ausschalten, andere Zeitpläne und Stromausfälle werden nicht abgefangen.
- `/sbin/shutdown -h now` fährt nach erfolgreicher Vorbereitung herunter. Geöffnete Dokumente werden dabei nicht mit einem normalen App-Speichern-Dialog behandelt. Wichtige Daten vorher speichern bzw. mit passenden Aktionen sichern.
- Wenn der Mac länger als acht Tage ausgeschaltet bleibt, sind die vorab registrierten Termine aufgebraucht. Nach dem nächsten manuellen Start füllt der Dienst sie wieder auf.
- Beim Aktualisieren der App wird die Dienstdatei ersetzt; ein bereits laufender Dienst verwendet seinen bisherigen Programmcode bis zum nächsten Neustart des Macs. Konfigurationsänderungen wirken ohne Neustart. Updates deshalb zunächst mit deaktiviertem Zeitplan anwenden, dann neu starten und wieder aktivieren.

## Sicherheit und Speicherung

- Systemdienst, installierte Konfiguration und Zustand: `/Library/Application Support/MacPowerSchedule/`.
- LaunchDaemon: `/Library/LaunchDaemons/de.wiwaltill.MacPowerSchedule.plist`.
- Lokaler UI-Entwurf: `~/Library/Application Support/MacPowerSchedule/draft.json`.
- Systemdateien sind root-eigen und nicht durch normale Benutzer veränderbar. Die Konfiguration und Protokolle sind lokal lesbar; **keine Geheimnisse in Befehle oder Ausgaben schreiben**. Fehlermeldungen können bis zu 1500 Zeichen Befehlsausgabe enthalten.
- Root-Rechte werden für Systemzeitpläne und den finalen Shutdown verwendet. Vorbereitungsaktionen laufen ohne Root-Rechte unter der installierenden UID.
- Protokollrotation ab ca. 512 KB; eine vorherige Datei bleibt erhalten. Befehlsausgaben sind auf ca. 1 MB begrenzt und werden vorübergehend mit Modus 0600 gespeichert.
- Keine Telemetrie, kein Server, keine automatischen Downloads.

## Pausieren und deinstallieren

Zum Pausieren „Zeitplan aktivieren“ ausschalten und anwenden. Das Protokoll bestätigt das Entfernen der eigenen Termine. App beenden oder in den Papierkorb legen alleine stoppt den Dienst nicht.

**Menüleiste → Vollständig deinstallieren …** entfernt nach Bestätigung und Administratorfreigabe den Systemdienst, seine eigenen Start-/Wecktermine, Konfiguration und Protokolle. Anschließend werden der App-Autostart, Mitteilungen, lokale Entwürfe, Einstellungen, Cache und gespeicherter Fensterzustand des aktuellen Benutzers entfernt. Das App-Bundle kommt in den Papierkorb, danach beendet sich die App. Externe Skripte, ZIP-Downloads, andere Benutzerprofile und macOS-eigene Berechtigungsaufzeichnungen werden nicht gelöscht.

Während eines lokalen Vorbereitungstests ist die Aktion gesperrt. Laufende Dienstaktionen werden beim Stoppen des Dienstes beendet; bereits gestoppte VMs oder gestartete GUI-Apps werden nicht rückgängig gemacht. Möglichst außerhalb einer laufenden Vorbereitung deinstallieren. Falls das Verschieben in den Papierkorb fehlschlägt, zeigt die App den Fehler an und kann im Finder gelöscht werden. Teilweise entfernte Komponenten werden nicht wiederhergestellt; die Deinstallation lässt sich erneut starten.

Alternativ aus dem Repository:

```sh
sudo ./scripts/uninstall.sh
```

Die CLI entfernt nur den Systemdienst samt dessen Konfiguration, Protokollen und eigenen Systemterminen. App-Autostart und Benutzerdaten anschließend separat entfernen oder die Menüleisten-Aktion verwenden. Fremde Systemtermine bleiben bestehen.

## Entwicklung und Prüfung

```sh
swift test
./scripts/build-app.sh debug
bash -n scripts/*.sh
```

`PowerCore` enthält Modelle, Zeitberechnung und die Aktionsausführung; `PowerSchedule` die SwiftUI-App; `PowerScheduler` den privilegierten Dienst. Die Tests verändern keine Systemzeitpläne und fahren weder den Mac noch echte VMs herunter. Sie prüfen Modi, Tagesgrenzen, DST, Validierung, Serialisierung, Fehlerabbruch, Prozessgruppen-Zeitlimits und VirtualBox mit einem simulierten CLI.

Hardware-Abnahmetest auf einem Test-Mac: zunächst deaktiviert installieren, Protokoll prüfen, eine Test-VM über den Dienst stoppen lassen, Fehler-/Timeout-Abbruch prüfen, dann einen echten Shutdown mit anschließendem automatischem Start testen. GUI-Aktionen, Administratorinstallation, Mitteilungen und Hardware-Einschalten sind zusätzliche manuelle Integrationsprüfungen und nicht durch Unit-Tests abgedeckt.

Apple-Referenzen: [Zeitpläne unter macOS](https://support.apple.com/en-lk/guide/mac-help/-mchl40376151/mac), [Hintergrunddienste](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html), IOKit `IOPMLib.h` im macOS SDK.
