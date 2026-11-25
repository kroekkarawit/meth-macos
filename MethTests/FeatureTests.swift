import XCTest
@testable import MethCore

/// Tests for: while-process sessions, extend, battery rules, --until parsing,
/// preference back-compat.
final class FeatureTests: XCTestCase {
    var clock: ManualClock!
    var scheduler: ManualScheduler!
    var assertions: MockAssertions!
    var privileged: MockPrivileged!
    var store: MemorySessionStore!
    var processes: FakeProcesses!
    var power: FakePower!

    override func setUp() {
        clock = ManualClock()
        scheduler = ManualScheduler(clock: clock)
        assertions = MockAssertions()
        privileged = MockPrivileged(engine: OverdoseEngine(backend: FakePMSet(false), store: MemoryRecordStore(), clock: clock))
        store = MemorySessionStore()
        processes = FakeProcesses()
        power = FakePower()
    }

    func make() -> SessionController {
        SessionController(assertions: assertions, privileged: privileged, store: store, clock: clock,
                          scheduler: scheduler, version: "9.9.9", processes: processes, power: power)
    }

    // MARK: While a process runs

    func testSessionEndsWhenWatchedProcessExits() async {
        let c = make()
        processes.launch(pid: 4242, name: "Xcode")
        let r = await c.handle(.activate(mode: .high, durationSeconds: nil, confirmIndefiniteOverdose: false, whilePID: 4242), source: .app)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.snapshot?.watchedProcess?.name, "Xcode")
        XCTAssertEqual(assertions.heldCount, 2)

        processes.exit(pid: 4242)
        let ended = await eventually { await c.snapshot().mode == .sober }
        XCTAssertTrue(ended)
        XCTAssertEqual(assertions.heldCount, 0)
        let s = await c.snapshot()
        XCTAssertEqual(s.lastEndReason, .processExited)
    }

    func testUnknownProcessIsRejected() async {
        let c = make()
        let r = await c.handle(.activate(mode: .bump, durationSeconds: nil, confirmIndefiniteOverdose: false, whilePID: 999), source: .cli)
        XCTAssertEqual(r.error?.code, .processNotFound)
        XCTAssertEqual(r.error?.code.exitCode, 2)
        XCTAssertEqual(assertions.heldCount, 0)
    }

    func testTimerStillAppliesWithWatchedProcess() async {
        let c = make()
        processes.launch(pid: 7, name: "make")
        _ = await c.handle(.activate(mode: .bump, durationSeconds: 60, confirmIndefiniteOverdose: false, whilePID: 7), source: .cli)
        scheduler.advance(seconds: 61)
        let ended = await eventually { await c.snapshot().mode == .sober }
        XCTAssertTrue(ended)
        let reason = await c.snapshot().lastEndReason
        XCTAssertEqual(reason, .expired)
    }

    func testRestoreDropsSessionWhoseProcessQuitWhileAgentWasDown() async {
        processes.launch(pid: 50, name: "Render", start: 111)
        let c1 = make()
        _ = await c1.handle(.activate(mode: .high, durationSeconds: 3600, confirmIndefiniteOverdose: false, whilePID: 50), source: .app)
        // Agent crashes; meanwhile the PID is reused by another process.
        processes.exit(pid: 50)
        processes.launch(pid: 50, name: "Other", start: 222)
        let c2 = make()
        await c2.restore()
        let mode = await c2.snapshot().mode
        XCTAssertEqual(mode, .sober)
    }

    // MARK: Extend

    func testExtendAddsTimeToRunningSession() async {
        let c = make()
        _ = await c.handle(.activate(mode: .high, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .app)
        scheduler.advance(seconds: 100)
        let r = await c.handle(.extend(seconds: 1800), source: .cli)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.snapshot?.mode, .high)
        XCTAssertEqual(r.snapshot?.remainingSeconds, 500 + 1800)
        XCTAssertEqual(assertions.heldCount, 2)
    }

    func testExtendKeepsWatchedProcess() async {
        let c = make()
        processes.launch(pid: 9, name: "ffmpeg")
        _ = await c.handle(.activate(mode: .bump, durationSeconds: 600, confirmIndefiniteOverdose: false, whilePID: 9), source: .cli)
        let r = await c.handle(.extend(seconds: 600), source: .cli)
        XCTAssertEqual(r.snapshot?.watchedProcess?.pid, 9)
    }

    func testExtendRejectsIndefiniteOrSober() async {
        let c = make()
        var r = await c.handle(.extend(seconds: 60), source: .cli)
        XCTAssertEqual(r.error?.code, .notExtendable)
        _ = await c.handle(.activate(mode: .bump, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .cli)
        r = await c.handle(.extend(seconds: 60), source: .cli)
        XCTAssertEqual(r.error?.code, .notExtendable)
    }

    func testExtendCannotExceedMaximum() async {
        let c = make()
        _ = await c.handle(.activate(mode: .bump, durationSeconds: MethDuration.maximumSeconds - 10, confirmIndefiniteOverdose: false), source: .cli)
        let r = await c.handle(.extend(seconds: 3600), source: .cli)
        XCTAssertEqual(r.error?.code, .invalidDuration)
        XCTAssertEqual(r.snapshot?.mode, .bump) // unchanged
    }

    // MARK: Battery rules

    func testLowBatteryEndsSession() async {
        let c = make()
        _ = await c.handle(.activate(mode: .high, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .app)
        await c.powerSourceChanged(PowerSourceState(hasBattery: true, onBattery: true, batteryPercent: 40))
        var mode = await c.snapshot().mode
        XCTAssertEqual(mode, .high)
        await c.powerSourceChanged(PowerSourceState(hasBattery: true, onBattery: true, batteryPercent: 10))
        mode = await c.snapshot().mode
        XCTAssertEqual(mode, .sober)
        let reason = await c.snapshot().lastEndReason
        XCTAssertEqual(reason, .lowBattery)
        XCTAssertEqual(assertions.heldCount, 0)
    }

    func testLowBatteryIgnoredOnACPower() async {
        let c = make()
        _ = await c.handle(.activate(mode: .bump, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .app)
        await c.powerSourceChanged(PowerSourceState(hasBattery: true, onBattery: false, batteryPercent: 3))
        let mode = await c.snapshot().mode
        XCTAssertEqual(mode, .bump)
    }

    func testStartingBelowLimitOnBatteryIsRefused() async {
        power.set(PowerSourceState(hasBattery: true, onBattery: true, batteryPercent: 8))
        let c = make()
        let r = await c.handle(.activate(mode: .bump, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .cli)
        XCTAssertEqual(r.error?.code, .batteryLow)
        XCTAssertEqual(r.error?.code.exitCode, 5)
        XCTAssertEqual(assertions.heldCount, 0)
    }

    func testBatteryLimitOffAllowsEverything() async {
        power.set(PowerSourceState(hasBattery: true, onBattery: true, batteryPercent: 3))
        let c = make()
        _ = await c.handle(.setBatteryRules(endBelowBatteryPercent: nil, endOnBatteryPower: false), source: .app)
        let r = await c.handle(.activate(mode: .bump, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .cli)
        XCTAssertNil(r.error)
        await c.powerSourceChanged(PowerSourceState(hasBattery: true, onBattery: true, batteryPercent: 2))
        let mode = await c.snapshot().mode
        XCTAssertEqual(mode, .bump)
    }

    func testEndOnBatteryPowerOnlyOnUnplug() async {
        let c = make()
        _ = await c.handle(.setBatteryRules(endBelowBatteryPercent: 10, endOnBatteryPower: true), source: .app)
        await c.powerSourceChanged(PowerSourceState(hasBattery: true, onBattery: false, batteryPercent: 90))
        _ = await c.handle(.activate(mode: .high, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .app)
        await c.powerSourceChanged(PowerSourceState(hasBattery: true, onBattery: true, batteryPercent: 90))
        let s = await c.snapshot()
        XCTAssertEqual(s.mode, .sober)
        XCTAssertEqual(s.lastEndReason, .onBatteryPower)
    }

    func testBatteryRulesAreAppOnlyAndValidated() async {
        let c = make()
        var r = await c.handle(.setBatteryRules(endBelowBatteryPercent: 5, endOnBatteryPower: true), source: .cli)
        XCTAssertEqual(r.error?.code, .unauthorizedClient)
        r = await c.handle(.setBatteryRules(endBelowBatteryPercent: 7, endOnBatteryPower: false), source: .app)
        XCTAssertEqual(r.error?.code, .usage)
        r = await c.handle(.setBatteryRules(endBelowBatteryPercent: 20, endOnBatteryPower: true), source: .app)
        XCTAssertNil(r.error)
        XCTAssertEqual(store.loadPreferences().endBelowBatteryPercent, 20)
        XCTAssertTrue(store.loadPreferences().endOnBatteryPower)
    }

    // MARK: Preferences compatibility

    func testOldPreferencesFileGetsDefaults() throws {
        let old = Data(#"{"allowOverdoseFromCLI":true}"#.utf8)
        let p = try MethJSON.decoder().decode(AgentPreferences.self, from: old)
        XCTAssertTrue(p.allowOverdoseFromCLI)
        XCTAssertEqual(p.endBelowBatteryPercent, AgentPreferences.defaultBatteryLimit)
        XCTAssertFalse(p.endOnBatteryPower)
    }

    func testBatteryLimitOffRoundTrips() throws {
        let p = AgentPreferences(endBelowBatteryPercent: nil)
        let back = try MethJSON.decoder().decode(AgentPreferences.self, from: MethJSON.encode(p))
        XCTAssertNil(back.endBelowBatteryPercent)
    }

    // MARK: CLI parsing

    private func parse(_ s: String, now: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> CLIInvocation {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return try CLIParser.parse(s.split(separator: " ").map(String.init), now: now, calendar: cal)
    }

    func testUntilResolvesToNextOccurrence() throws {
        // 1_800_000_000 = 2027-01-15 08:00:00 UTC
        XCTAssertEqual(try parse("high --until 09:30").command, .activate(.high, .seconds(5400), whilePID: nil))
        // Earlier than now → tomorrow.
        XCTAssertEqual(try parse("bump --until 07:00").command, .activate(.bump, .seconds(23 * 3600), whilePID: nil))
        XCTAssertEqual(try parse("overdose --until 10:00").command, .activate(.overdose, .seconds(7200), whilePID: nil))
    }

    func testUntilValidation() {
        for bad in ["high --until 25:00", "high --until 9:7", "high --until noon", "high --for 1h --until 09:00", "sober --until 09:00"] {
            XCTAssertThrowsError(try parse(bad), bad)
        }
    }

    func testWhilePIDParsing() throws {
        XCTAssertEqual(try parse("bump --while-pid 123").command, .activate(.bump, .indefinite, whilePID: 123))
        XCTAssertEqual(try parse("high --for 2h -p 77").command, .activate(.high, .seconds(7200), whilePID: 77))
        XCTAssertThrowsError(try parse("bump --while-pid abc"))
        XCTAssertThrowsError(try parse("bump --while-pid 0"))
        XCTAssertThrowsError(try parse("status --while-pid 5"))
    }

    func testExtendParsing() throws {
        XCTAssertEqual(try parse("extend 30m").command, .extend(seconds: 1800))
        XCTAssertEqual(try parse("extend 1h30m --json").json, true)
        XCTAssertThrowsError(try parse("extend"))
        XCTAssertThrowsError(try parse("extend inf"))
        XCTAssertThrowsError(try parse("extend 10"))
        XCTAssertThrowsError(try parse("extend 30m --for 1h"))
    }

    func testStatusJSONHasNewKeys() {
        var s = SessionSnapshot.sober(version: "1", now: Date(timeIntervalSince1970: 0))
        s.lastEndReason = .lowBattery
        let json = CLIOutput.statusJSON(s, cliVersion: "1")
        XCTAssertTrue(json.contains(#""whileProcess":null"#))
        XCTAssertTrue(json.contains(#""lastEndReason":"lowBattery""#))
        XCTAssertTrue(json.contains(#""endBelowBatteryPercent":10"#))
        XCTAssertTrue(json.contains(#""endOnBatteryPower":false"#))
    }
}
