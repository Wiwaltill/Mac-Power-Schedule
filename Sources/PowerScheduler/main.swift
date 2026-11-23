import Foundation
import Darwin
import PowerCore
import IOKit.pwr_mgt

struct PersistentState: Codable {
    var attemptedShutdown: Date?
}

func log(_ message: String) {
    let safeMessage = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ⏎ ")
    let line = "\(ISO8601DateFormatter().string(from: Date()))  \(safeMessage)\n"
    let url = URL(fileURLWithPath: Paths.log)
    if ((try? FileManager.default.attributesOfItem(atPath: Paths.log)[.size] as? NSNumber)?.intValue ?? 0) > 512_000 {
        try? FileManager.default.removeItem(atPath: Paths.log + ".previous")
        try? FileManager.default.moveItem(atPath: Paths.log, toPath: Paths.log + ".previous")
    }
    if !FileManager.default.fileExists(atPath: Paths.log) { FileManager.default.createFile(atPath: Paths.log, contents: nil, attributes: [.posixPermissions: 0o644]) }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        do { try handle.seekToEnd(); try handle.write(contentsOf: Data(line.utf8)) } catch {}
    }
}
let stateURL = URL(fileURLWithPath: Paths.directory + "/state.json")
func save(_ state: PersistentState) throws { try JSONEncoder().encode(state).write(to: stateURL, options: .atomic) }
struct PowerEvent: Hashable {
    var date: Date
    var type: String
}
func reconcile(_ config: Configuration, force: Bool = false) throws {
    let now = Date()
    var desired = Set(config.starts(after: now).map { PowerEvent(date: $0, type: kIOPMAutoWakeOrPowerOn) })
    // Wake a sleeping Mac for preparations, without powering on an already shut-down Mac.
    if config.enabled {
        for offset in 0..<8 {
            guard let day = Calendar.current.date(byAdding: .day, value: offset, to: now) else { continue }
            let plan = config.day(for: day)
            if plan.stopEnabled, let date = config.occurrence(on: day, time: plan.stop), date > now {
                desired.insert(PowerEvent(date: date, type: kIOPMAutoWake))
            }
        }
    }
    let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] ?? []
    let actual = Set(events.compactMap { event -> PowerEvent? in
        guard event[kIOPMPowerEventAppNameKey] as? String == Paths.label,
              let date = event[kIOPMPowerEventTimeKey] as? Date,
              let type = event[kIOPMPowerEventTypeKey] as? String else { return nil }
        return PowerEvent(date: date, type: type)
    })
    for event in actual.subtracting(desired) {
        let code = IOPMCancelScheduledPowerEvent(event.date as CFDate, Paths.label as CFString, event.type as CFString)
        guard code == kIOReturnSuccess else { throw ScheduleError.message("Start-/Wecktermin konnte nicht entfernt werden (IOKit \(code)).") }
    }
    for event in desired.subtracting(actual) {
        let code = IOPMSchedulePowerEvent(event.date as CFDate, Paths.label as CFString, event.type as CFString)
        guard code == kIOReturnSuccess else { throw ScheduleError.message("Start-/Wecktermin konnte nicht gesetzt werden (IOKit \(code)).") }
    }
    if force || actual != desired {
        log(config.enabled ? "Start-/Wecktermine aktualisiert (\(desired.count)); Zeitzone \(TimeZone.current.identifier)." : "Zeitplan deaktiviert; eigene Start-/Wecktermine entfernt.")
    }
}

guard geteuid() == 0 else { fputs("PowerScheduler benötigt den installierten Systemdienst.\n", stderr); exit(1) }
if CommandLine.arguments.dropFirst().contains("--remove-owned-events") {
    let events = IOPMCopyScheduledPowerEvents()?.takeRetainedValue() as? [[String: Any]] ?? []
    for event in events where event[kIOPMPowerEventAppNameKey] as? String == Paths.label {
        guard let date = event[kIOPMPowerEventTimeKey] as? Date, let type = event[kIOPMPowerEventTypeKey] as? String else { continue }
        let result = IOPMCancelScheduledPowerEvent(date as CFDate, Paths.label as CFString, type as CFString)
        guard result == kIOReturnSuccess else { fputs("Start-/Wecktermin konnte nicht entfernt werden.\n", stderr); exit(1) }
    }
    exit(0)
}
// Dispatch handlers run outside POSIX signal context and can safely update the lock.
let terminationSources = [SIGTERM, SIGINT].map { value in
    signal(value, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
    source.setEventHandler { Command.terminationRequested = true }
    source.resume()
    return source
}
umask(0o022)
var state: PersistentState
if FileManager.default.fileExists(atPath: stateURL.path) {
    do { state = try JSONDecoder().decode(PersistentState.self, from: Data(contentsOf: stateURL)) }
    catch { log("Zustandsdatei beschädigt; keine Aktionen ausgeführt: \(error)"); exit(1) }
} else { state = PersistentState() }
let installedExecutable = URL(fileURLWithPath: Paths.executable)
let loadedDigest: String
// The root-owned executable is atomically replaced by the authorized installer.
do {
    loadedDigest = try ServiceUpdate.digest(of: installedExecutable)
    let runtime = ServiceRuntime(processID: getpid(), executableDigest: loadedDigest)
    try JSONEncoder().encode(runtime).write(to: URL(fileURLWithPath: Paths.runtime), options: .atomic)
} catch {
    log("Dienstversion konnte nicht festgestellt werden: \(error.localizedDescription)")
    exit(1)
}
func reloadIfReplaced() throws {
    guard try ServiceUpdate.digest(of: installedExecutable) != loadedDigest else { return }
    log("Dienstupdate erkannt; neue Version wird im Leerlauf geladen. Zeitplan bleibt aktiv.")
    let arguments = [strdup(Paths.executable), nil]
    defer { arguments.forEach { free($0) } }
    arguments.withUnsafeBufferPointer { _ = execv(Paths.executable, $0.baseAddress!) }
    throw ScheduleError.message("Dienstupdate konnte nicht geladen werden: \(String(cString: strerror(errno)))")
}
var previousConfig: Configuration?
var lastError = ""
log("Hintergrunddienst gestartet.")
while !Command.terminationRequested {
    do {
        // Never reload from inside executeAll: preparations and the final shutdown finish first.
        try reloadIfReplaced()
        NSTimeZone.resetSystemTimeZone()
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: Paths.config)))
        try config.validate()
        try reconcile(config, force: previousConfig != config)
        previousConfig = config
        lastError = ""
        if let due = config.shutdownDue(now: Date()), state.attemptedShutdown != due {
            state.attemptedShutdown = due
            try save(state) // Never retry failed or interrupted preparations automatically.
            log("Shutdown-Vorbereitung begonnen.")
            do {
                let assertion = Process()
                assertion.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
                assertion.arguments = ["-is", "-w", String(getpid())]
                try assertion.run()
                defer { assertion.terminate() }
                try ActionRunner(configuration: config, privileged: true).executeAll(log: log)
                // A deactivation or changed plan during preparation cancels the shutdown.
                let latest = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: Paths.config)))
                guard latest == config else { throw ScheduleError.message("Konfiguration wurde während der Vorbereitung geändert.") }
                try reconcile(config)
                log("Alle Vorbereitungen erfolgreich. Mac wird heruntergefahren.")
                _ = try Command.run("/sbin/shutdown", ["-h", "now"])
            } catch { log("HERUNTERFAHREN ABGEBROCHEN: \(error.localizedDescription)") }
        }
    } catch {
        if lastError != error.localizedDescription { log("FEHLER: \(error.localizedDescription)"); lastError = error.localizedDescription }
    }
    for _ in 0..<150 {
        if Command.terminationRequested { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
}
