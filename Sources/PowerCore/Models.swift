import Foundation

public enum ScheduleMode: String, Codable, CaseIterable, Sendable {
    case daily, workweek, individual
    public var title: String { switch self { case .daily: "Jeden Tag"; case .workweek: "Wochentage / Wochenende"; case .individual: "Jeder Tag einzeln" } }
}
public struct DaySchedule: Codable, Equatable, Sendable {
    public var startEnabled = true
    public var start = "07:00"
    public var stopEnabled = true
    public var stop = "23:00"
    public init() {}
}
public enum ActionKind: String, Codable, CaseIterable, Sendable {
    case virtualBox, shell, application
    public var title: String { switch self { case .virtualBox: "VirtualBox (Shutdown + Statusprüfung)"; case .shell: "Shell-Befehl"; case .application: "App starten und auf Ende warten" } }
}
public struct Preparation: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var enabled = true
    public var name = "Neue Aktion"
    public var kind: ActionKind = .virtualBox
    public var target = ""
    public var timeout = 180
    /// nil keeps ACPI; a command triggers shutdown before the same VirtualBox status tracking.
    public var shutdownCommand: String?
    public init() {}
}
public struct Configuration: Codable, Equatable, Sendable {
    public var enabled = false
    public var mode: ScheduleMode = .daily
    public var days = Array(repeating: DaySchedule(), count: 7) // Monday first
    public var actions: [Preparation] = []
    public var vboxPath = "/Applications/VirtualBox.app/Contents/MacOS/VBoxManage"
    public var userID: UInt32 = 501
    public init() {}
    public func day(for date: Date, calendar: Calendar = .current) -> DaySchedule {
        let index = (calendar.component(.weekday, from: date) + 5) % 7
        return days[mode == .daily ? 0 : mode == .workweek ? (index < 5 ? 0 : 5) : index]
    }
    public func validate() throws {
        guard days.count == 7, userID >= 501, actions.count <= 100 else { throw ScheduleError.message("Ungültige Konfiguration.") }
        for day in days {
            guard Self.validTime(day.start), Self.validTime(day.stop) else { throw ScheduleError.message("Zeiten müssen HH:mm entsprechen.") }
            guard !day.startEnabled || !day.stopEnabled || day.start != day.stop else { throw ScheduleError.message("Start und Shutdown dürfen nicht gleichzeitig sein.") }
        }
        for action in actions where action.enabled {
            guard !action.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...7200).contains(action.timeout) else { throw ScheduleError.message("Jede Aktion benötigt ein Ziel und ein Zeitlimit von 1–7200 Sekunden.") }
            if action.kind == .virtualBox, let command = action.shutdownCommand,
               command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ScheduleError.message("Der eigene VirtualBox-Shutdown-Befehl darf nicht leer sein.")
            }
        }
        guard vboxPath.hasPrefix("/") else { throw ScheduleError.message("VBoxManage benötigt einen absoluten Pfad.") }
    }
    public static func validTime(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isNumber) } && (0...23).contains(Int(parts[0]) ?? -1) && (0...59).contains(Int(parts[1]) ?? -1)
    }
    public func occurrence(on date: Date, time: String, calendar: Calendar = .current) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        // A missing DST hour moves to the next valid time; repeated hours run once.
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
    public func starts(after now: Date, count: Int = 8, calendar: Calendar = .current) -> [Date] {
        guard enabled else { return [] }
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
            let plan = day(for: date, calendar: calendar)
            guard plan.startEnabled, let event = occurrence(on: date, time: plan.start, calendar: calendar), event > now else { return nil }
            return event
        }
    }
    public func shutdownDue(now: Date, calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        let plan = day(for: now, calendar: calendar)
        guard plan.stopEnabled, let date = occurrence(on: now, time: plan.stop, calendar: calendar), (0..<90).contains(now.timeIntervalSince(date)) else { return nil }
        return date
    }
}
public enum ScheduleError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public enum Paths {
    public static let directory = "/Library/Application Support/MacPowerSchedule"
    public static let executable = directory + "/PowerScheduler"
    public static let runtime = directory + "/runtime.json"
    public static let config = directory + "/configuration.json"
    public static let log = directory + "/scheduler.log"
    public static let label = "de.wiwaltill.MacPowerSchedule"
}
