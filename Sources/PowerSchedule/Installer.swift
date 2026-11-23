import Foundation
import AppKit
import PowerCore

@MainActor enum Installer {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func apply(_ configuration: Configuration) throws {
        var config = configuration
        config.userID = getuid()
        try config.validate()
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: resources.appendingPathComponent("install.sh").path),
              let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("PowerScheduler") else {
            throw ScheduleError.message("Bitte die mit scripts/build-app.sh gebaute .app verwenden.")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let file = staging.appendingPathComponent("configuration.json")
        try JSONEncoder().encode(config).write(to: file, options: .atomic)
        let command = "/bin/bash " + quote(resources.appendingPathComponent("install.sh").path) + " " + quote(file.path) + " " + quote(executable.path)
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        guard let script = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges") else { throw ScheduleError.message("Administratoraufruf konnte nicht vorbereitet werden.") }
        script.executeAndReturnError(&error)
        if let error { throw ScheduleError.message(error[NSAppleScript.errorMessage] as? String ?? "Installation abgebrochen.") }
    }
}
