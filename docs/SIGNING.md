# Signieren und Notarisieren

Das aktuelle GitHub-Release ist **ad hoc signiert**. Das schützt die Integrität des Bundles, bestätigt aber keine Entwickleridentität und ersetzt Apples Notarisierung nicht.

## Für den eigenen Mac

Ein lokaler Build ist auch ohne kostenpflichtiges Entwicklerkonto möglich:

```sh
./scripts/build-app.sh
```

Bei einer heruntergeladenen Version prüfe die SHA-256-Prüfsumme gegen `SHA256SUMS.txt` aus demselben Release:

```sh
shasum -a 256 Mac-Power-Schedule.zip
```

Wenn du der Herkunft vertraust und macOS das Öffnen blockiert, nutze nach dem Öffnungsversuch **Systemeinstellungen → Datenschutz & Sicherheit → Dennoch öffnen**, soweit macOS dies anbietet. Gatekeeper nicht systemweit deaktivieren. Die Prüfsumme allein ersetzt keine Identitätsprüfung.

## Für öffentliche Downloads ohne Entwicklerwarnung

Du benötigst eine Mitgliedschaft im **Apple Developer Program** und ein Zertifikat vom Typ **Developer ID Application** mit privatem Schlüssel auf deinem Mac. Ein „Apple Development“- oder „Developer ID Installer“-Zertifikat ist hierfür nicht der passende Typ.

1. In Xcode unter **Settings → Accounts** deine Apple-ID hinzufügen und dein Team auswählen. Unter **Manage Certificates** ein **Developer ID Application**-Zertifikat erstellen; alternativ über Apples Developer-Portal mit einer auf diesem Mac erzeugten Zertifikatsanforderung.
2. Die verfügbare Identität anzeigen:

   ```sh
   security find-identity -v -p codesigning
   ```

3. Beide Programme mit Hardened Runtime und sicherem Zeitstempel signieren:

   ```sh
   CODESIGN_IDENTITY='Developer ID Application: Dein Name (TEAMID)' ./scripts/build-app.sh
   ```

   Das Build-Skript signiert zuerst den Helper und danach das App-Bundle. Die `.app` nach der Signierung nicht mehr verändern.

4. Zugang für Apples Notarisierung im macOS-Schlüsselbund hinterlegen. `notarytool` fragt fehlende Angaben interaktiv ab; verwende ein app-spezifisches Apple-ID-Passwort. Geheimnisse nicht ins Repository oder in den Chat schreiben:

   ```sh
   xcrun notarytool store-credentials MacPowerSchedule
   ```

5. ZIP hochladen und auf das Ergebnis warten:

   ```sh
   xcrun notarytool submit dist/Mac-Power-Schedule.zip \
     --keychain-profile MacPowerSchedule --wait
   ```

   Nur bei Status **Accepted** fortfahren. Bei Problemen das Protokoll mit `xcrun notarytool log SUBMISSION-ID --keychain-profile MacPowerSchedule` abrufen.

6. Das Ticket an die App anheften, prüfen und das finale ZIP neu erzeugen:

   ```sh
   xcrun stapler staple 'dist/Mac Power Schedule.app'
   xcrun stapler validate 'dist/Mac Power Schedule.app'
   codesign --verify --deep --strict 'dist/Mac Power Schedule.app'
   spctl --assess --type execute --verbose=2 'dist/Mac Power Schedule.app'
   ditto -c -k --sequesterRsrc --keepParent \
     'dist/Mac Power Schedule.app' dist/Mac-Power-Schedule.zip
   (cd dist && shasum -a 256 Mac-Power-Schedule.zip > SHA256SUMS.txt)
   ```

7. Dieses finale ZIP und die neue Prüfsumme als Release-Dateien hochladen. Die Download-Version auf einem zweiten Mac testen.

**CI:** Der aktuelle Workflow erstellt bewusst ad hoc signierte Builds. Er greift nicht auf deine lokalen Zertifikate zu. Eine Developer-ID-signierte Release-Pipeline benötigt separat eingerichtete Zertifikate und Notarisierungs-Zugangsdaten als geschützte GitHub-Secrets. Der oben beschriebene lokale Ablauf funktioniert ohne deren Speicherung bei GitHub.

Apple: [Developer-ID-Zertifikate](https://developer.apple.com/help/account/certificates/create-developer-id-certificates) · [Notarisierung](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) · [Notarisierungs-Workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
