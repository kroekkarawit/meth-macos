import XCTest
@testable import MethCore

final class SleepModeTests: XCTestCase {
    func testRawValuesAreStableLowercaseIdentifiers() {
        XCTAssertEqual(SleepMode.allCases.map(\.rawValue), ["sober", "bump", "high", "overdose"])
    }

    func testAssertionKindsPerMode() {
        XCTAssertEqual(SleepMode.sober.assertionKinds, [])
        XCTAssertEqual(SleepMode.bump.assertionKinds, [.preventUserIdleSystemSleep])
        XCTAssertEqual(Set(SleepMode.high.assertionKinds), [.preventUserIdleSystemSleep, .preventUserIdleDisplaySleep])
        XCTAssertTrue(SleepMode.overdose.assertionKinds.contains(.preventUserIdleDisplaySleep))
        XCTAssertTrue(SleepMode.overdose.requiresPrivilegedHelper)
        XCTAssertFalse(SleepMode.high.requiresPrivilegedHelper)
    }

    func testCLIWordsAndOrdering() {
        XCTAssertEqual(SleepMode(cliWord: "STOP"), .sober)
        XCTAssertEqual(SleepMode(cliWord: "off"), .sober)
        XCTAssertEqual(SleepMode(cliWord: "High"), .high)
        XCTAssertNil(SleepMode(cliWord: "speed"))
        XCTAssertLessThan(SleepMode.bump, SleepMode.overdose)
        XCTAssertFalse(SleepMode.sober.isActive)
    }
}

final class DurationParserTests: XCTestCase {
    func parse(_ s: String, max: Int = MethDuration.maximumSeconds) throws -> MethDuration {
        try DurationParser.parse(s, maximumSeconds: max)
    }

    func testValidForms() throws {
        XCTAssertEqual(try parse("15m"), .seconds(900))
        XCTAssertEqual(try parse("90m"), .seconds(5400))
        XCTAssertEqual(try parse("2h"), .seconds(7200))
        XCTAssertEqual(try parse("1h30m"), .seconds(5400))
        XCTAssertEqual(try parse("45s"), .seconds(45))
        XCTAssertEqual(try parse("1d"), .seconds(86400))
        XCTAssertEqual(try parse(" 2H "), .seconds(7200))
        XCTAssertEqual(try parse("1d2h3m4s"), .seconds(93784))
    }

    func testIndefiniteForms() throws {
        for s in ["inf", "infinite", "forever", "∞", "INF"] {
            XCTAssertEqual(try parse(s), .indefinite, s)
        }
    }

    func testRejectsInvalid() {
        for s in ["", "abc", "10", "-5m", "5x", "m", "1.5h", "30m1h", "1h1h", "5m 3s", "99999999h"] {
            XCTAssertThrowsError(try parse(s), "should reject \(s)")
        }
    }

    func testRejectsZeroAndTooLong() {
        XCTAssertThrowsError(try parse("0m")) { XCTAssertEqual($0 as? DurationParseError, .zero) }
        XCTAssertThrowsError(try parse("25h", max: MethDuration.maximumOverdoseSeconds)) {
            XCTAssertEqual($0 as? DurationParseError, .tooLong(maximumSeconds: 86400))
        }
        XCTAssertNoThrow(try parse("24h", max: MethDuration.maximumOverdoseSeconds))
        XCTAssertThrowsError(try parse("31d"))
    }

    func testLabelsAndFormatting() {
        XCTAssertEqual(MethDuration.presets.map(\.shortLabel), ["30m", "1h", "4h", "∞"])
        XCTAssertEqual(MethDuration.defaultPreset, .seconds(3600))
        XCTAssertEqual(RemainingFormatter.clock(6135), "01:42:15")
        XCTAssertEqual(RemainingFormatter.clock(-4), "00:00:00")
        XCTAssertEqual(RemainingFormatter.clock(90000), "25:00:00")
        XCTAssertEqual(RemainingFormatter.compactClock(6135), "1:42:15")
        XCTAssertEqual(RemainingFormatter.compactClock(75), "1:15")
    }
}

final class CLIParserTests: XCTestCase {
    func parse(_ s: String) throws -> CLIInvocation {
        try CLIParser.parse(s.split(separator: " ").map(String.init))
    }

    func code(_ s: String) -> MethErrorCode? {
        do { _ = try parse(s); return nil } catch { return (error as? MethError)?.code }
    }

    func testDocumentedCommands() throws {
        XCTAssertEqual(try parse("sober").command, .sober)
        XCTAssertEqual(try parse("stop").command, .sober)
        XCTAssertEqual(try parse("bump").command, .activate(.bump, .indefinite))
        XCTAssertEqual(try parse("bump --for 30m").command, .activate(.bump, .seconds(1800)))
        XCTAssertEqual(try parse("high").command, .activate(.high, .indefinite))
        XCTAssertEqual(try parse("high --for 2h").command, .activate(.high, .seconds(7200)))
        XCTAssertEqual(try parse("high --for=90m").command, .activate(.high, .seconds(5400)))
        XCTAssertEqual(try parse("overdose --for 1h").command, .activate(.overdose, .seconds(3600)))
        XCTAssertEqual(try parse("status").command, .status)
        XCTAssertTrue(try parse("status --json").json)
        XCTAssertEqual(try parse("version").command, .version)
        XCTAssertEqual(try parse("--version").command, .version)
        XCTAssertEqual(try parse("help").command, .help)
        XCTAssertEqual(try parse("--help").command, .help)
        XCTAssertEqual(try CLIParser.parse([]).command, .help)
    }

    func testFlagOrderDoesNotMatter() throws {
        XCTAssertEqual(try parse("--json high --for 2h"), CLIInvocation(command: .activate(.high, .seconds(7200)), json: true))
        XCTAssertEqual(try parse("--for 15m bump").command, .activate(.bump, .seconds(900)))
    }

    func testLanguageFlag() throws {
        XCTAssertEqual(try parse("status --lang th").language, .th)
        XCTAssertEqual(try parse("status --lang=zh").language, .zhHans)
        XCTAssertEqual(code("status --lang fr"), .usage)
    }

    func testErrors() {
        XCTAssertEqual(code("speed"), .unknownCommand)
        XCTAssertEqual(code("high --for"), .usage)
        XCTAssertEqual(code("high --for 10"), .invalidDuration)
        XCTAssertEqual(code("high --for -5m"), .invalidDuration) // negative durations are rejected
        XCTAssertEqual(code("high --for 0m"), .invalidDuration)
        XCTAssertEqual(code("overdose"), .durationRequired)
        XCTAssertEqual(code("overdose --for inf"), .durationRequired)
        XCTAssertEqual(code("overdose --for 25h"), .invalidDuration)
        XCTAssertEqual(code("status --for 1h"), .usage)
        XCTAssertEqual(code("sober --for 1h"), .usage)
        XCTAssertEqual(code("high --for 1h --for 2h"), .usage)
        XCTAssertEqual(code("high extra"), .usage)
        XCTAssertEqual(code("high --bogus"), .usage)
    }

    func testExitCodesAreDistinctPerCategory() {
        XCTAssertEqual(MethErrorCode.usage.exitCode, 2)
        XCTAssertEqual(MethErrorCode.invalidDuration.exitCode, 2)
        XCTAssertEqual(MethErrorCode.agentUnavailable.exitCode, 3)
        XCTAssertEqual(MethErrorCode.overdoseNotAllowed.exitCode, 4)
        XCTAssertEqual(MethErrorCode.privilegedOperationFailed.exitCode, 5)
        XCTAssertEqual(MethErrorCode.unauthorizedClient.exitCode, 6)
        XCTAssertEqual(MethErrorCode.internal.exitCode, 1)
        for c in MethErrorCode.allCases { XCTAssertNotEqual(c.exitCode, 0) }
    }
}

final class LanguageTests: XCTestCase {
    func testCodes() {
        XCTAssertEqual(CLILanguage(code: "th-TH"), .th)
        XCTAssertEqual(CLILanguage(code: "zh-Hans-CN"), .zhHans)
        XCTAssertEqual(CLILanguage(code: "zh_CN"), .zhHans)
        XCTAssertEqual(CLILanguage(code: "en-GB"), .en)
        XCTAssertNil(CLILanguage(code: "fr"))
    }

    func testResolutionOrder() {
        XCTAssertEqual(CLILanguage.resolve(explicit: .zhHans, environment: ["METH_LANG": "th"], appLanguages: ["en"], preferred: ["en"]), .zhHans)
        XCTAssertEqual(CLILanguage.resolve(explicit: nil, environment: ["METH_LANG": "th"], appLanguages: ["zh-Hans"], preferred: ["en"]), .th)
        XCTAssertEqual(CLILanguage.resolve(explicit: nil, environment: [:], appLanguages: ["zh-Hans"], preferred: ["th"]), .zhHans)
        XCTAssertEqual(CLILanguage.resolve(explicit: nil, environment: [:], appLanguages: nil, preferred: ["fr-FR", "th-TH"]), .th)
        XCTAssertEqual(CLILanguage.resolve(explicit: nil, environment: [:], appLanguages: nil, preferred: ["fr"]), .en)
    }

    func testEveryLanguageHasEveryString() {
        for lang in CLILanguage.allCases {
            let s = CLIStrings(lang)
            XCTAssertFalse(s.help.isEmpty)
            for label in [CLIStrings.Label.mode, .status, .remaining, .active, .inactive, .indefinite, .error, .warning] {
                XCTAssertFalse(s.label(label).isEmpty)
            }
            for code in MethErrorCode.allCases {
                XCTAssertFalse(s.message(for: MethError(code, "x")).isEmpty)
            }
        }
        XCTAssertEqual(CLIStrings(.th).label(.mode), "โหมด")
        XCTAssertEqual(CLIStrings(.zhHans).label(.status), "状态")
    }
}

final class PMSetParsingTests: XCTestCase {
    func testParsesSleepDisabled() {
        let on = """
        System-wide power settings:
         SleepDisabled		1
        Currently in use:
         standby              1
        """
        XCTAssertTrue(PMSetBackend.parseSleepDisabled(on))
        XCTAssertFalse(PMSetBackend.parseSleepDisabled(on.replacingOccurrences(of: "SleepDisabled\t\t1", with: "SleepDisabled\t\t0")))
        let absent = """
        System-wide power settings:
        Currently in use:
         sleep                1 (sleep prevented by caffeinate)
        """
        XCTAssertFalse(PMSetBackend.parseSleepDisabled(absent))
    }
}
