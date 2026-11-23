import XCTest
@testable import PowerCore

final class PowerCoreTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return value
    }
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func testScheduleModesAndWeekBoundary() {
        var config = Configuration()
        for index in 0..<7 { config.days[index].start = String(format: "%02d:00", index + 7) }
        let monday = date("2026-11-23T12:00:00Z")
        let sunday = date("2026-11-29T12:00:00Z")
        XCTAssertEqual(config.day(for: sunday, calendar: calendar).start, "07:00")
        config.mode = .workweek
        XCTAssertEqual(config.day(for: monday, calendar: calendar).start, "07:00")
        XCTAssertEqual(config.day(for: sunday, calendar: calendar).start, "12:00")
        config.mode = .individual
        XCTAssertEqual(config.day(for: sunday, calendar: calendar).start, "13:00")
    }
    func testDisabledAndFutureStarts() {
        var config = Configuration()
        let now = date("2026-11-23T12:00:00Z")
        XCTAssertTrue(config.starts(after: now, calendar: calendar).isEmpty)
        config.enabled = true
        let starts = config.starts(after: now, calendar: calendar)
        XCTAssertEqual(starts.count, 7)
        XCTAssertEqual(starts.first, date("2026-11-24T06:00:00Z"))
        config.days[0].startEnabled = false
        XCTAssertTrue(config.starts(after: now, calendar: calendar).isEmpty)
    }
    func testShutdownWindowAndDisabledDays() {
        var config = Configuration()
        config.enabled = true
        let due = date("2026-11-23T22:00:00Z")
        XCTAssertNil(config.shutdownDue(now: due.addingTimeInterval(-1), calendar: calendar))
        XCTAssertEqual(config.shutdownDue(now: due.addingTimeInterval(89), calendar: calendar), due)
        XCTAssertNil(config.shutdownDue(now: due.addingTimeInterval(90), calendar: calendar))
        config.days[0].stopEnabled = false
        XCTAssertNil(config.shutdownDue(now: due, calendar: calendar))
    }
    func testDSTMissingAndRepeatedHour() {
        let config = Configuration()
        let spring = config.occurrence(on: date("2027-03-28T00:00:00Z"), time: "02:30", calendar: calendar)!
        XCTAssertEqual(calendar.component(.hour, from: spring), 3)
        let autumn = config.occurrence(on: date("2027-10-31T00:00:00Z"), time: "02:30", calendar: calendar)
        XCTAssertEqual(autumn, date("2027-10-31T00:30:00Z"))
    }
    func testValidationAndRoundTrip() throws {
        var config = Configuration()
        XCTAssertEqual(try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)), config)
        for time in ["7:00", "24:00", "00:60", "aa:bb", "12:00:00", ""] { XCTAssertFalse(Configuration.validTime(time)) }
        config.days[0].stop = config.days[0].start
        XCTAssertThrowsError(try config.validate())
        config.days[0].stopEnabled = false
        try config.validate()
        config.days = []
        XCTAssertThrowsError(try config.validate())
    }
    func testExitStatusAndOutput() throws {
        XCTAssertEqual(try Command.run("/usr/bin/printf", ["hello"]), "hello")
        XCTAssertThrowsError(try Command.run("/bin/sh", ["-c", "exit 7"]))
        XCTAssertThrowsError(try Command.run("/nonexistent", []))
    }
    func testOutputLimitAlsoAppliesToQuicklyExitingProcesses() {
        XCTAssertThrowsError(try Command.run("/bin/dd", ["if=/dev/zero", "bs=1048576", "count=2"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("1 MB"))
        }
    }
    func testTimeoutTerminatesProcessGroup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("should-not-exist").path
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try Command.run("/bin/sh", ["-c", "(sleep 2; touch '\(marker)') & wait"], timeout: 1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        Thread.sleep(forTimeInterval: 1.1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }
    func testFailureStopsFollowingActions() {
        var config = Configuration()
        var first = Preparation()
        first.name = "Fehler"
        first.kind = .shell
        first.target = "exit 3"
        var second = Preparation()
        second.name = "Darf nicht laufen"
        second.kind = .shell
        second.target = "exit 0"
        config.actions = [first, second]
        var lines: [String] = []
        XCTAssertThrowsError(try ActionRunner(configuration: config).executeAll { lines.append($0) })
        XCTAssertEqual(lines, ["Starte: Fehler"])
    }
    func testVirtualBoxTracksPoweroffAndRejectsUnsafeStates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("VBoxManage")
        let state = directory.appendingPathComponent("state")
        try "running".write(to: state, atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        cd "$(dirname "$0")"
        case "$1" in
          showvminfo) printf 'VMState="%s"\\n' "$(cat state)";;
          controlvm) echo poweroff > state;;
          *) exit 1;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var config = Configuration()
        config.vboxPath = script.path
        var action = Preparation()
        action.target = "Home Assistant VM"
        action.timeout = 3
        try ActionRunner(configuration: config).execute(action)
        XCTAssertEqual(try String(contentsOf: state, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "poweroff")
        try ActionRunner(configuration: config).execute(action) // Already off is successful.
        try "paused".write(to: state, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ActionRunner(configuration: config).execute(action))
        try "running".write(to: state, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho 'VMState=\"running\"'\n".write(to: script, atomically: true, encoding: .utf8)
        action.timeout = 1
        XCTAssertThrowsError(try ActionRunner(configuration: config).execute(action))
    }
}
