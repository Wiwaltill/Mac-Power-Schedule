import Foundation
import Darwin

private final class TerminationState: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return requested }
        set { lock.lock(); defer { lock.unlock() }; requested = newValue }
    }
}

public enum Command {
    private static let termination = TerminationState()
    public static var terminationRequested: Bool {
        get { termination.value }
        set { termination.value = newValue }
    }
    /// Each command owns a process group, so timeouts also terminate child processes.
    public static func run(_ executable: String, _ arguments: [String], timeout: Int = 30) throws -> String {
        guard !terminationRequested else { throw ScheduleError.message("Systemdienst wird beendet; Aktion abgebrochen.") }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, output.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { environment.forEach { free($0) } }
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { buffer in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&pid, executable, &actions, &attributes, buffer.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw ScheduleError.message("Prozess konnte nicht gestartet werden: \(String(cString: strerror(result)))") }
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeout)
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited == -1 {
                if errno == EINTR { continue }
                kill(-pid, SIGKILL)
                throw ScheduleError.message("Prozessstatus konnte nicht gelesen werden.")
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0
            if terminationRequested || ProcessInfo.processInfo.systemUptime >= deadline || size > 1_048_576 {
                kill(-pid, SIGTERM)
                Thread.sleep(forTimeInterval: 0.3)
                kill(-pid, SIGKILL)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                if terminationRequested { throw ScheduleError.message("Systemdienst wird beendet; laufende Aktion abgebrochen.") }
                throw ScheduleError.message(size > 1_048_576 ? "Aktion wegen zu großer Ausgabe abgebrochen (1 MB)." : "Zeitlimit von \(timeout) Sekunden überschritten.")
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        // A completed command must not leave detached preparation children running.
        kill(-pid, SIGTERM)
        let handle = try FileHandle(forReadingFrom: output)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw ScheduleError.message("Aktion wegen zu großer Ausgabe abgebrochen (1 MB).") }
        let text = String(decoding: data, as: UTF8.self)
        guard status == 0 else {
            let reason = status & 0x7f == 0 ? "Exit-Code \((status >> 8) & 0xff)" : "Signal \(status & 0x7f)"
            throw ScheduleError.message("Prozess fehlgeschlagen (\(reason)): \(text.prefix(1500))")
        }
        return text
    }
}

public struct ActionRunner: Sendable {
    public let configuration: Configuration
    public let privileged: Bool
    public init(configuration: Configuration, privileged: Bool = false) {
        self.configuration = configuration
        self.privileged = privileged
    }
    private func run(_ executable: String, _ arguments: [String], timeout: Int) throws -> String {
        if privileged {
            guard configuration.userID >= 501, let user = getpwuid(configuration.userID) else { throw ScheduleError.message("Aktionsbenutzer existiert nicht.") }
            let home = String(cString: user.pointee.pw_dir)
            let name = String(cString: user.pointee.pw_name)
            return try Command.run("/usr/bin/sudo", ["-n", "-H", "-u", "#\(configuration.userID)", "/usr/bin/env", "-i", "HOME=\(home)", "USER=\(name)", "LOGNAME=\(name)", "PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", executable] + arguments, timeout: timeout)
        }
        return try Command.run(executable, arguments, timeout: timeout)
    }
    public func execute(_ action: Preparation, log: (String) -> Void = { _ in }) throws {
        switch action.kind {
        case .shell:
            _ = try run("/bin/zsh", ["-c", "cd \"$HOME\" && {\n" + action.target + "\n}"], timeout: action.timeout)
        case .application:
            // open -W waits for the application to exit, not merely for its launch.
            _ = try run("/usr/bin/open", ["-W", "-a", action.target], timeout: action.timeout)
        case .virtualBox:
            let deadline = ProcessInfo.processInfo.systemUptime + Double(action.timeout)
            var lastStatusError: String?
            var reportedRetry = false
            var lastReportedState: String?
            func remaining(maximum: Int = 15) throws -> Int {
                let value = Int(ceil(deadline - ProcessInfo.processInfo.systemUptime))
                guard value > 0 else {
                    let detail = lastStatusError.map { " Letzter Statusfehler: \($0)" } ?? ""
                    throw ScheduleError.message("VirtualBox-VM hat das Zeitlimit überschritten; ausgeschalteter Zustand nicht bestätigt." + detail)
                }
                return min(value, maximum)
            }
            func state() throws -> String {
                while true {
                    let output: String
                    do {
                        output = try run(configuration.vboxPath, ["showvminfo", action.target, "--machinereadable"], timeout: remaining())
                    } catch {
                        let detail = error.localizedDescription
                        // A closing VirtualBox console can temporarily reject a shared session.
                        // Retry only this specific read failure, never infer poweroff from an error.
                        guard !Command.terminationRequested,
                              detail.contains("Failed to get a console object from the direct session"),
                              detail.contains("VBOX_E_INVALID_OBJECT_STATE") else { throw error }
                        lastStatusError = detail
                        _ = try remaining()
                        if !reportedRetry {
                            log("VirtualBox: \(action.target) – Sitzung vorübergehend nicht abfragbar; Status wird bis zum Zeitlimit erneut geprüft.")
                            reportedRetry = true
                        }
                        Thread.sleep(forTimeInterval: min(1, max(0.1, deadline - ProcessInfo.processInfo.systemUptime)))
                        continue
                    }
                    guard let line = output.split(separator: "\n").first(where: { $0.hasPrefix("VMState=") }) else {
                        throw ScheduleError.message("VirtualBox liefert keinen VM-Status.")
                    }
                    let value = String(line.dropFirst("VMState=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"\r"))
                    lastStatusError = nil
                    if value != lastReportedState {
                        log("VirtualBox: \(action.target) – Zustand \(value).")
                        lastReportedState = value
                    }
                    return value
                }
            }
            let initial = try state()
            if initial == "poweroff" { return }
            guard initial == "running" else { throw ScheduleError.message("VM ist \(initial). Sie muss laufen oder bereits ausgeschaltet sein.") }
            switch action.resolvedShutdownMethod {
            case .homeAssistantConsole:
                log("VirtualBox: \(action.target) – host shutdown wird über die virtuelle Tastatur an die Home-Assistant-Konsole gesendet.")
                _ = try run(configuration.vboxPath, ["controlvm", action.target, "keyboardputstring", "host shutdown"], timeout: remaining())
                _ = try run(configuration.vboxPath, ["controlvm", action.target, "keyboardputscancode", "1c", "9c"], timeout: remaining())
            case .custom:
                guard let command = action.shutdownCommand, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ScheduleError.message("Eigener Shutdown-Befehl ist leer.")
                }
                log("VirtualBox: \(action.target) – eigener Shutdown-Befehl wird ausgeführt.")
                _ = try run("/bin/zsh", ["-c", "cd \"$HOME\" && {\n" + command + "\n}"], timeout: remaining(maximum: action.timeout))
            case .acpi:
                _ = try run(configuration.vboxPath, ["controlvm", action.target, "acpipowerbutton"], timeout: remaining())
            }
            while true {
                let current = try state()
                if current == "poweroff" { return }
                guard current == "running" || current == "stopping" else { throw ScheduleError.message("Unerwarteter VM-Status: \(current)") }
                _ = try remaining()
                Thread.sleep(forTimeInterval: min(2, max(0.1, deadline - ProcessInfo.processInfo.systemUptime)))
            }
        }
    }
    public func executeAll(log: (String) -> Void) throws {
        for action in configuration.actions where action.enabled {
            log("Starte: \(action.name)")
            do { try execute(action, log: log); log("Erfolgreich: \(action.name)") }
            catch { throw ScheduleError.message("\(action.name): \(error.localizedDescription)") }
        }
    }
}
