# ⏻ Mac Power Schedule

**Dein Mac startet nach Plan – und fährt erst herunter, wenn alles bereit ist.**

Native macOS-App mit Menüleiste für **Intel & Apple Silicon · macOS 13+ · Deutsch · MIT**.

[**App herunterladen ↓**](https://github.com/Wiwaltill/Mac-Power-Schedule/releases/latest) · [Bedienung](docs/OPERATIONS.md) · [Signieren](docs/SIGNING.md)

## Das kann die App

| Zeitpläne | Sichere Vorbereitung |
| :--- | :--- |
| Jeden Tag dieselben Zeiten | VirtualBox: ACPI-Shutdown und auf „ausgeschaltet“ warten |
| Wochentage und Wochenende getrennt | Eigene Shell-/SSH-Befehle und Apps ausführen |
| Jeden Wochentag einzeln | Reihenfolge, Aktivierung und Zeitlimit je Aktion |
| Start und Shutdown separat aktivierbar | Bei Fehlern den Mac-Shutdown abbrechen |

Der Systemdienst arbeitet auch bei geschlossener App. Protokoll, Vorbereitungstest, optionale Fehlermitteilungen und App-Autostart sind integriert.

## In drei Schritten starten

1. Im [aktuellen Release](https://github.com/Wiwaltill/Mac-Power-Schedule/releases/latest) **Mac-Power-Schedule.zip** laden, entpacken und die App nach **Programme** kopieren.
2. Zeiten und Aktionen eintragen, etwa eine VirtualBox-Aktion pro VM. Zunächst **Vorbereitung testen …** – die VMs werden dabei wirklich gestoppt.
3. Zeitplan aktivieren und **Speichern & anwenden …** wählen. macOS fragt nach Administratorrechten, auch bei späteren Änderungen.

**Deinstallieren:** Menüleistensymbol → **Vollständig deinstallieren …**. Entfernt nach Bestätigung Systemdienst, eigene Systemtermine, Konfiguration, Protokolle, App-Autostart und die lokalen App-Daten dieses Benutzers. Die App kommt in den Papierkorb. Externe Skripte, andere Benutzerprofile und heruntergeladene ZIPs bleiben erhalten.

> **Vor dem Einsatz:** Die Shutdown-Zeit startet die Vorbereitung. Nur Shutdowns dieser App führen die Aktionen aus. FileVault verlangt nach dem Einschalten manuelles Entsperren; automatischer VM-Start ist separat einzurichten. Prüfe den vollständigen Ablauf auf deinem Mac, bevor du ihn unbeaufsichtigt nutzt.
>
> **Aktuelles Download-Build:** Ad hoc signiert, noch nicht mit Developer ID signiert und nicht notarisiert. macOS kann es beim Öffnen blockieren. Prüfsumme liegt im Release; [Hinweise zu Gatekeeper und eigener Signierung](docs/SIGNING.md).

## Selbst bauen

Xcode mit Swift 6 benötigt; keine externen Paketabhängigkeiten.

```sh
swift test
./scripts/build-app.sh
open "dist/Mac Power Schedule.app"
```

Universal-App, ZIP und SHA-256-Prüfsumme entstehen in `dist/`. GitHub Actions prüft jeden Push/PR. Eine neue `VERSION` mit passenden [Release Notes](docs/releases/) wird nach erfolgreichem Build auf `main` automatisch veröffentlicht; vorhandene Releases bleiben unverändert.

---

Entwickelt von **Till Esser in Zusammenarbeit mit [OpenAI Codex](https://openai.com/codex/)**. Architektur, Implementierung, Tests und Dokumentation sind mit Codex entstanden. Beiträge und Fehlerberichte sind willkommen.
