import Foundation
import AppKit
import PowerCore

@MainActor enum Installer {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private static func authorize(_ command: String) throws {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else {
            throw ScheduleError.message("Administratoraufruf konnte nicht vorbereitet werden.")
        }
        script.executeAndReturnError(&error)
        if let error { throw ScheduleError.message(error[NSAppleScript.errorMessage] as? String ?? "Administratorfreigabe abgebrochen.") }
    }

    private static func resources(for script: String) throws -> (URL, URL) {
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent(script).path),
              let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("PowerScheduler"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ScheduleError.message("Bitte das vollständige App-Bundle verwenden.")
        }
        return (resources.appendingPathComponent(script), executable)
    }

    static func apply(_ configuration: Configuration) throws {
        var config = configuration
        config.userID = getuid()
        try config.validate()
        let (script, executable) = try resources(for: "install.sh")
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = staging.appendingPathComponent("configuration.json")
        try JSONEncoder().encode(config).write(to: file, options: .atomic)
        try authorize("/bin/bash " + quote(script.path) + " " + quote(file.path) + " " + quote(executable.path))
    }

    static func updateServiceIfNeeded() throws -> String? {
        guard FileManager.default.fileExists(atPath: Paths.config) else { return nil }
        let (script, bundled) = try resources(for: "install.sh")
        guard try ServiceUpdate.needsReplacement(installed: URL(fileURLWithPath: Paths.executable), bundled: bundled) else { return nil }
        let supportsReload = (try? Data(contentsOf: URL(fileURLWithPath: Paths.runtime))).flatMap {
            try? JSONDecoder().decode(ServiceRuntime.self, from: $0)
        } != nil
        try authorize("/bin/bash " + quote(script.path) + " --update-service " + quote(bundled.path))
        return supportsReload
            ? "Dienstdatei aktualisiert. Übernahme im nächsten Leerlauf; Zeitplan und laufende Aktionen bleiben erhalten."
            : "Dienstdatei aktualisiert; der bisherige Dienst bleibt bis zum nächsten normalen Mac-Neustart aktiv. Der Zeitplan bleibt erhalten. Danach erfolgen weitere Dienstupdates automatisch im Leerlauf."
    }

    static func removeSystemService() throws {
        let (script, executable) = try resources(for: "uninstall.sh")
        // Use the bundled helper even when an installed helper is missing or damaged.
        try authorize("/bin/bash " + quote(script.path) + " " + quote(executable.path))
    }


    static func finishCleanupAfterExit() throws {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("cleanup-user.sh"),
              FileManager.default.fileExists(atPath: script.path) else {
            throw ScheduleError.message("Abschließende Datenbereinigung fehlt im App-Bundle.")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let stagedScript = staging.appendingPathComponent("cleanup.sh")
        let content = try String(contentsOf: script, encoding: .utf8)
            + "\n/bin/rm -f -- \"$0\"\n/bin/rmdir -- \"$(dirname \"$0\")\"\n"
        try content.write(to: stagedScript, atomically: true, encoding: .utf8)
        let cleanup = Process()
        cleanup.executableURL = URL(fileURLWithPath: "/bin/bash")
        cleanup.arguments = [stagedScript.path, String(getpid())]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        cleanup.environment = environment
        cleanup.standardInput = FileHandle.nullDevice
        cleanup.standardOutput = FileHandle.nullDevice
        cleanup.standardError = FileHandle.nullDevice
        do { try cleanup.run() }
        catch { try? FileManager.default.removeItem(at: staging); throw error }
    }

    static func removeUserData() throws {
        let files = FileManager.default
        let identifier = "de.wiwaltill.MacPowerSchedule.app"
        let directories: [URL] = [
            files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacPowerSchedule"),
            files.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent(identifier),
            files.homeDirectoryForCurrentUser.appendingPathComponent("Library/HTTPStorages/\(identifier)"),
            files.homeDirectoryForCurrentUser.appendingPathComponent("Library/WebKit/\(identifier)"),
            files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Saved Application State/\(identifier).savedState")
        ]
        for directory in directories where files.fileExists(atPath: directory.path) {
            try files.removeItem(at: directory)
        }
        UserDefaults.standard.removePersistentDomain(forName: identifier)
    }
}
