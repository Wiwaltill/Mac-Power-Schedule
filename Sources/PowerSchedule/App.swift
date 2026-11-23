import SwiftUI
import AppKit
import PowerCore
import ServiceManagement
import UserNotifications

@MainActor final class AppModel: ObservableObject {
    let updates = UpdaterController()
    @Published var config = Configuration()
    @Published var message = "Noch kein Zeitplan installiert."
    @Published var logText = ""
    @Published var busy = false
    @Published var latestStatus = "Noch kein Dienstprotokoll vorhanden."
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private var lastNotificationLine = ""
    @Published var testOutput = ""
    private let draftURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacPowerSchedule/draft.json")
    init() {
        updates.preparationIsRunning = { [weak self] in self?.busy ?? false }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.config)), let saved = try? JSONDecoder().decode(Configuration.self, from: data), (try? saved.validate()) != nil {
            config = saved
            message = "Installierte Einstellungen geladen."
        } else if let data = try? Data(contentsOf: draftURL), let draft = try? JSONDecoder().decode(Configuration.self, from: data), (try? draft.validate()) != nil { config = draft }
        refresh()
        Task {
            try? await Task.sleep(for: .seconds(2))
            do { if let result = try Installer.updateServiceIfNeeded() { message = result } }
            catch { message = "App ist aktuell; Dienstupdate noch ausstehend: \(error.localizedDescription)" }
        }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { Task { do { try await SMAppService.mainApp.unregister(); loginEnabled = false } catch { message = error.localizedDescription } }; return }
            loginEnabled = SMAppService.mainApp.status == .enabled
        } catch { message = error.localizedDescription }
    }
    func enableNotifications() {
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                message = allowed ? "Fehlermeldungen aktiviert, solange die App läuft." : "Mitteilungen sind nicht erlaubt. Bitte in den Systemeinstellungen prüfen."
            } catch { message = error.localizedDescription }
        }
    }
    func refresh() {
        logText = (try? String(contentsOfFile: Paths.log, encoding: .utf8)) ?? "Noch kein Dienstprotokoll vorhanden."
        latestStatus = String(logText.split(separator: "\n").last ?? "")
        if latestStatus != lastNotificationLine {
            let wasInitialized = !lastNotificationLine.isEmpty
            lastNotificationLine = latestStatus
            if wasInitialized && (latestStatus.contains("ABGEBROCHEN") || latestStatus.contains("FEHLER:")) {
                let content = UNMutableNotificationContent()
                content.title = "Mac Power Schedule: Fehler"
                content.body = latestStatus
                content.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
        }
    }
    func apply() {
        do {
            config.userID = getuid()
            try config.validate()
            try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(config).write(to: draftURL, options: .atomic)
            try Installer.apply(config)
            message = "Gespeichert. Übernahme im nächsten Dienstzyklus; laufende Aktionen werden zuerst beendet."
        } catch { message = "Fehler: \(error.localizedDescription)" }
        refresh()
    }
    func confirmUninstall() {
        guard !busy else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Mac Power Schedule vollständig deinstallieren?"
        alert.informativeText = "Der Systemdienst, alle eigenen Start-/Wecktermine und die Konfiguration samt Protokollen werden entfernt. App-Autostart, lokale Entwürfe, Einstellungen und Cache dieses Benutzers werden gelöscht; die App kommt in den Papierkorb. Laufende Dienstaktionen werden beendet. Gestoppte VMs und bereits gestartete Apps bleiben in ihrem Zustand. Andere Benutzerprofile, externe Skripte und heruntergeladene ZIP-Dateien bleiben erhalten."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Deinstallieren")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        busy = true
        Task {
            do {
                // Ask for administrator authorization first. Cancellation leaves local data intact.
                try Installer.removeSystemService()
                if SMAppService.mainApp.status != .notRegistered {
                    try await SMAppService.mainApp.unregister()
                }
                loginEnabled = false
                let notifications = UNUserNotificationCenter.current()
                notifications.removeAllPendingNotificationRequests()
                notifications.removeAllDeliveredNotifications()
                NSApp.disableRelaunchOnLogin()
                for window in NSApp.windows { window.isRestorable = false }
                try Installer.removeUserData()
                let app = Bundle.main.bundleURL
                guard app.pathExtension == "app", Bundle.main.bundleIdentifier == "de.wiwaltill.MacPowerSchedule.app" else {
                    throw ScheduleError.message("Systemdienst und Daten entfernt. Dieses Programm ist kein App-Bundle; bitte manuell löschen.")
                }
                try Installer.finishCleanupAfterExit()
                try FileManager.default.trashItem(at: app, resultingItemURL: nil)
                NSApp.terminate(nil)
            } catch {
                busy = false
                message = "Deinstallation nicht vollständig: \(error.localizedDescription)"
                let failure = NSAlert()
                failure.messageText = "Deinstallation nicht abgeschlossen"
                failure.informativeText = message + " Bereits entfernte Komponenten bleiben entfernt. Du kannst die Deinstallation erneut starten. Falls nur das Verschieben der App fehlschlägt, lösche die App anschließend im Finder."
                failure.runModal()
            }
        }
    }
    func test() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.config)),
           let installed = try? JSONDecoder().decode(Configuration.self, from: data), installed.enabled {
            message = "Bitte den aktiven Systemzeitplan zuerst deaktivieren und anwenden, bevor du testest."
            return
        }
        do { try config.validate() } catch { message = error.localizedDescription; return }
        busy = true
        testOutput = "Vorbereitungstest läuft. Die Aktionen werden wirklich ausgeführt; der Mac bleibt eingeschaltet."
        let snapshot = config
        Task {
            let result = await Task.detached {
                var lines: [String] = []
                do {
                    try ActionRunner(configuration: snapshot).executeAll { lines.append($0) }
                    lines.append("Alle Aktionen erfolgreich. Kein Shutdown ausgeführt.")
                } catch { lines.append("ABGEBROCHEN: \(error.localizedDescription)") }
                return lines.joined(separator: "\n")
            }.value
            testOutput = result
            busy = false
            updates.resumeInstallationIfIdle()
        }
    }
}

@main struct PowerScheduleApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Mac Power Schedule", id: "settings") { SettingsView(model: model) }
            .defaultSize(width: 850, height: 760)
            .commands {
                CommandGroup(after: .appInfo) { UpdateControls(updates: model.updates) }
            }
        MenuBarExtra("Power Schedule", systemImage: "power.circle") {
            MenuContent(model: model)
        }
    }
}
struct MenuContent: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Einstellungen öffnen") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
        UpdateControls(updates: model.updates)
        Button("Protokoll aktualisieren") { model.refresh(); openWindow(id: "settings") }
        Divider()
        Text(model.latestStatus)
        Text("Zeitplan läuft als separater Systemdienst")
        Button("Vollständig deinstallieren …", role: .destructive) { model.confirmUninstall() }.disabled(model.busy)
        Divider()
        Button("App beenden (Zeitplan bleibt aktiv)") { NSApp.terminate(nil) }
    }
}
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var confirmTest = false
    private let weekdays = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
    private var indices: [Int] { model.config.mode == .daily ? [0] : model.config.mode == .workweek ? [0, 5] : Array(0..<7) }
    private func label(_ index: Int) -> String { model.config.mode == .daily ? "Alle Tage" : model.config.mode == .workweek ? (index == 0 ? "Mo–Fr" : "Sa–So") : weekdays[index] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "power.circle.fill").font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("Mac Power Schedule").font(.title2.bold())
                    Text("Automatisch starten. Vorbereitet herunterfahren.").foregroundStyle(.secondary)
                }
                Spacer()
            }
            TabView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        GroupBox("Zeitplan") {
                            VStack(alignment: .leading, spacing: 14) {
                                Toggle("Zeitplan aktivieren", isOn: $model.config.enabled)
                                Picker("Aufteilung", selection: $model.config.mode) {
                                    ForEach(ScheduleMode.allCases, id: \.self) { Text($0.title).tag($0) }
                                }.pickerStyle(.segmented)
                                ForEach(indices, id: \.self) { index in
                                    HStack {
                                        Text(label(index)).frame(width: 95, alignment: .leading)
                                        Toggle("Start", isOn: $model.config.days[index].startEnabled)
                                        TextField("HH:mm", text: $model.config.days[index].start).frame(width: 65)
                                        Spacer()
                                        Toggle("Shutdown", isOn: $model.config.days[index].stopEnabled)
                                        TextField("HH:mm", text: $model.config.days[index].stop).frame(width: 65)
                                    }
                                }
                                Text("Lokale Mac-Zeit, Format HH:mm. Die Vorbereitung beginnt zur Shutdown-Zeit; ausgeschaltet wird erst nach ihrem erfolgreichen Abschluss.").font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }
                        GroupBox("Vor dem Herunterfahren") {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Aktionen laufen der Reihe nach. Jeder Fehler oder jedes Zeitlimit bricht das Herunterfahren ab. Es gibt keinen erzwungenen VM-Stopp.").font(.callout)
                                ForEach($model.config.actions) { $action in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Toggle("Aktiv", isOn: $action.enabled).labelsHidden().help("Aktion aktivieren")
                                            TextField("Name", text: $action.name)
                                            Button { move(action.id, by: -1) } label: { Image(systemName: "arrow.up") }.help("Nach oben")
                                            Button { move(action.id, by: 1) } label: { Image(systemName: "arrow.down") }.help("Nach unten")
                                            Button(role: .destructive) { let id = action.id; model.config.actions.removeAll { $0.id == id } } label: { Image(systemName: "trash") }
                                        }
                                        Picker("Typ", selection: $action.kind) { ForEach(ActionKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                                        if action.kind == .shell {
                                            TextEditor(text: $action.target).font(.system(.body, design: .monospaced)).frame(height: 75).border(.secondary.opacity(0.3))
                                        } else {
                                            TextField(action.kind == .virtualBox ? "VM-Name oder UUID" : "Absoluter Pfad zur .app", text: $action.target)
                                        }
                                        if action.kind == .virtualBox {
                                            Picker("Shutdown-Methode", selection: Binding(
                                                get: { action.resolvedShutdownMethod },
                                                set: { action.shutdownMethod = $0 }
                                            )) {
                                                ForEach(VirtualBoxShutdownMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                                            }
                                            if action.resolvedShutdownMethod == .homeAssistantConsole {
                                                Text("Sendet host shutdown und Enter über die virtuelle Tastatur. Voraussetzung: Die VM-Konsole steht am leeren ha >-Prompt. Keine SSH-Einrichtung nötig. Anschließend wird weiterhin auf den ausgeschalteten VM-Zustand gewartet.")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            if action.resolvedShutdownMethod == .custom {
                                                TextEditor(text: Binding(get: { action.shutdownCommand ?? "" }, set: { action.shutdownCommand = $0 }))
                                                    .font(.system(.body, design: .monospaced)).frame(height: 75).border(.secondary.opacity(0.3))
                                                Text("Zum Beispiel SSH mit Schlüsselanmeldung. Erst nach erfolgreichem Befehl wird auf den ausgeschalteten VM-Zustand gewartet. Zeitlimit gilt für Befehl und Statusprüfung zusammen. Keine Kennwörter oder Tokens eintragen.")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        HStack {
                                            Text("Zeitlimit (Sekunden)")
                                            TextField("180", value: $action.timeout, format: .number.grouping(.never)).frame(width: 80)
                                        }
                                        if action.kind == .application { Text("Die App muss selbstständig beenden. GUI-Apps benötigen eine angemeldete Benutzersitzung; für zuverlässige Serverabläufe Shell/CLI verwenden.").font(.caption).foregroundStyle(.secondary) }
                                    }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                                }
                                Button { model.config.actions.append(Preparation()) } label: { Label("Aktion hinzufügen", systemImage: "plus") }
                                TextField("VBoxManage-Pfad", text: $model.config.vboxPath)
                                Text("Shell: /bin/zsh ohne interaktive Profile, Arbeitsverzeichnis und HOME des installierenden Benutzers. SSH und andere Werkzeuge sind als Shell-Befehl möglich; Zugangsdaten gehören in Schlüsseldateien, nicht in dieses Feld.").font(.caption).foregroundStyle(.secondary)
                            }.padding(8)
                        }
                        GroupBox("Betrieb") {
                            VStack(alignment: .leading, spacing: 10) {
                            Toggle("App bei Anmeldung öffnen (Menüleiste und Fehlermeldungen)", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
                            Button("Fehlermitteilungen erlauben …") { model.enableNotifications() }
                            UpdateSettings(updates: model.updates)
                            Text("Der Dienst arbeitet auch bei geschlossener App. Einschalten benötigt Netzstrom; FileVault verlangt manuelles Entsperren. Deine VMs müssen nach der Anmeldung separat automatisch starten. Nur geplante Shutdowns dieser App führen die Aktionen aus. Ein normaler macOS-Shutdown wird nicht abgefangen.").font(.callout)
                            }.padding(8)
                        }
                    }.padding()
                }.tabItem { Label("Einstellungen", systemImage: "calendar") }
                VStack(alignment: .leading) {
                    HStack { Text("Dienstprotokoll").font(.headline); Spacer(); Button("Aktualisieren") { model.refresh() } }
                    ScrollView { Text(model.logText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    if !model.testOutput.isEmpty { Divider(); ScrollView { Text(model.testOutput).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180) }
                }.padding().tabItem { Label("Protokoll & Test", systemImage: "list.bullet.rectangle") }
            }
            Text(model.latestStatus).font(.caption).foregroundStyle(model.latestStatus.contains("ABGEBROCHEN") || model.latestStatus.contains("FEHLER:") ? .red : .secondary).textSelection(.enabled)
            Text(model.message).font(.callout).textSelection(.enabled)
            HStack {
                Button(model.busy ? "Test läuft …" : "Vorbereitung testen …") { confirmTest = true }.disabled(model.busy)
                Spacer()
                Button("Speichern & anwenden …") { model.apply() }.buttonStyle(.borderedProminent).disabled(model.busy)
            }
            Text("Anwenden installiert bzw. aktualisiert den Systemdienst und benötigt eine Administratorfreigabe. Zum Pausieren: Zeitplan deaktivieren und anwenden.").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(minWidth: 740, minHeight: 640)
            .confirmationDialog("Vorbereitung wirklich ausführen?", isPresented: $confirmTest) {
                Button("Aktionen ausführen (ohne Mac-Shutdown)", role: .destructive) { model.test() }
            } message: { Text("VMs werden heruntergefahren, Shell-Befehle und Apps wirklich ausgeführt. Der Test wird beim ersten Fehler abgebrochen.") }
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = model.config.actions.firstIndex(where: { $0.id == id }), model.config.actions.indices.contains(index + offset) else { return }
        model.config.actions.swapAt(index, index + offset)
    }
}

struct UpdateControls: View {
    @ObservedObject var updates: UpdaterController
    var body: some View {
        Button("Nach Updates suchen …") { updates.checkForUpdates() }
            .disabled(!updates.canCheckForUpdates)
    }
}

struct UpdateSettings: View {
    @ObservedObject var updates: UpdaterController
    var body: some View {
        Toggle("Automatisch nach App-Updates suchen", isOn: Binding(get: { updates.automaticallyChecksForUpdates }, set: { updates.setAutomaticChecks($0) }))
        UpdateControls(updates: updates)
        Text("Updates erhalten den Zeitplan. Die Aktualisierung des Systemdienstes benötigt eine Administratorfreigabe; laufende Dienstaktionen werden zuerst beendet.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
