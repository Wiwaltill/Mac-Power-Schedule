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
    func testServiceTerminationCancelsRunningCommand() {
        defer { Command.terminationRequested = false }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            Command.terminationRequested = true
        }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try Command.run("/bin/sleep", ["10"], timeout: 20)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Systemdienst wird beendet"))
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 5)
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
    private func virtualBoxFixture(_ body: String) throws -> (URL, Configuration) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("VBoxManage")
        try ("#!/bin/sh\ncd \"$(dirname \"$0\")\"\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var config = Configuration()
        config.vboxPath = script.path
        var action = Preparation()
        action.name = "Homebridge"
        action.target = "Homebridge VM"
        action.timeout = 8
        config.actions = [action]
        return (directory, config)
    }

    func testVirtualBoxRecoversFromConsoleRaceBeforeAndAfterACPI() throws {
        let (directory, fixture) = try virtualBoxFixture("""
        case "$1" in
          showvminfo)
            count=$(cat calls 2>/dev/null || echo 0)
            count=$((count + 1)); echo "$count" > calls
            if [ "$count" = 1 ] || [ "$count" = 3 ]; then
              echo 'VBoxManage: error: Failed to get a console object from the direct session (VBOX_E_INVALID_OBJECT_STATE)' >&2
              exit 1
            fi
            if [ "$count" = 2 ]; then echo 'VMState="running"'; else echo 'VMState="poweroff"'; fi;;
          controlvm) echo acpi >> controls;;
          *) exit 2;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = fixture
        var following = Preparation()
        following.name = "Following action"
        following.kind = .shell
        following.target = "touch \"\(directory.appendingPathComponent("continued").path)\""
        config.actions.append(following)
        var lines: [String] = []
        try ActionRunner(configuration: config).executeAll { lines.append($0) }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8), "4\n")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("controls"), encoding: .utf8), "acpi\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("continued").path))
        XCTAssertTrue(lines.contains { $0.contains("vorübergehend nicht abfragbar") })
        XCTAssertTrue(lines.contains { $0.contains("Zustand poweroff") })
    }

    func testVirtualBoxPersistentConsoleRaceDoesNotCountAsPoweroff() throws {
        let (directory, fixture) = try virtualBoxFixture("""
        case "$1" in
          showvminfo)
            if [ ! -f controls ]; then echo 'VMState="running"'; exit 0; fi
            echo 'VBoxManage: error: Failed to get a console object from the direct session (VBOX_E_INVALID_OBJECT_STATE)' >&2
            exit 1;;
          controlvm) echo acpi > controls;;
          *) exit 2;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = fixture
        config.actions[0].timeout = 1
        var following = Preparation()
        following.name = "Must not run"
        following.kind = .shell
        following.target = "exit 0"
        config.actions.append(following)
        var lines: [String] = []
        XCTAssertThrowsError(try ActionRunner(configuration: config).executeAll { lines.append($0) }) { error in
            XCTAssertTrue(error.localizedDescription.contains("ausgeschalteter Zustand nicht bestätigt"))
            XCTAssertTrue(error.localizedDescription.contains("VBOX_E_INVALID_OBJECT_STATE"))
        }
        XCTAssertFalse(lines.contains("Starte: Must not run"))
        XCTAssertFalse(lines.contains("Erfolgreich: Homebridge"))
    }

    func testVirtualBoxUnrelatedStatusErrorsStillFailImmediately() throws {
        let (directory, config) = try virtualBoxFixture("""
        echo called >> calls
        echo 'VBoxManage: error: Permission denied' >&2
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try ActionRunner(configuration: config).executeAll { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Permission denied"))
        }
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("calls"), encoding: .utf8), "called\n")
    }

    func testServiceUpdateRecognizesContentsNotOnlyFileMetadata() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let installed = directory.appendingPathComponent("installed")
        let bundled = directory.appendingPathComponent("bundled")
        try Data("version-one".utf8).write(to: installed)
        try Data("version-one".utf8).write(to: bundled)
        XCTAssertFalse(try ServiceUpdate.needsReplacement(installed: installed, bundled: bundled))
        let timestamp = Date(timeIntervalSince1970: 1000)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: bundled.path)
        XCTAssertFalse(try ServiceUpdate.needsReplacement(installed: installed, bundled: bundled))
        try Data("version-two".utf8).write(to: bundled)
        try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: bundled.path)
        XCTAssertTrue(try ServiceUpdate.needsReplacement(installed: installed, bundled: bundled))
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "version-one")
        try FileManager.default.removeItem(at: bundled)
        XCTAssertThrowsError(try ServiceUpdate.needsReplacement(installed: installed, bundled: bundled))
    }

    func testLegacyPreparationDecodesWithACPIStillEnabled() throws {
        let data = Data(#"{"id":"F4D4A49D-C401-4919-AD24-744036E79E39","enabled":true,"name":"Old VM","kind":"virtualBox","target":"Homebridge","timeout":180}"#.utf8)
        let action = try JSONDecoder().decode(Preparation.self, from: data)
        XCTAssertNil(action.shutdownCommand)
        var config = Configuration()
        config.actions = [action]
        config.actions[0].shutdownCommand = "  "
        XCTAssertThrowsError(try config.validate())
    }
    func testCustomShutdownCommandTracksVMWithoutSendingACPI() throws {
        let (directory, fixture) = try virtualBoxFixture("""
        case "$1" in
          showvminfo) if [ -f off ]; then echo 'VMState="poweroff"'; else echo 'VMState="running"'; fi;;
          controlvm) touch unexpected-acpi; exit 1;;
          *) exit 2;;
        esac
        """)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = fixture
        config.actions[0].shutdownCommand = "touch \"\(directory.appendingPathComponent("off").path)\""
        try ActionRunner(configuration: config).executeAll { _ in }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("unexpected-acpi").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("off").path))
        // Already powered off: do not execute even a failing custom command.
        config.actions[0].shutdownCommand = "exit 7"
        try ActionRunner(configuration: config).executeAll { _ in }
    }
    func testSuccessfulCustomCommandAloneDoesNotConfirmShutdown() throws {
        let (directory, fixture) = try virtualBoxFixture("echo 'VMState=\"running\"'\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = fixture
        config.actions[0].shutdownCommand = "exit 0"
        config.actions[0].timeout = 1
        XCTAssertThrowsError(try ActionRunner(configuration: config).executeAll { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains("ausgeschalteter Zustand nicht bestätigt"))
        }
    }
    func testFailedCustomCommandAbortsInsteadOfAssumingRemoteShutdown() throws {
        let (directory, fixture) = try virtualBoxFixture("echo 'VMState=\"running\"'\n")
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = fixture
        config.actions[0].shutdownCommand = "exit 255"
        XCTAssertThrowsError(try ActionRunner(configuration: config).executeAll { _ in }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Exit-Code 255"))
        }
    }

}
