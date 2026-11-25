import XCTest
@testable import MethCore

final class SessionControllerTests: XCTestCase {
    var clock: ManualClock!
    var scheduler: ManualScheduler!
    var assertions: MockAssertions!
    var pmset: FakePMSet!
    var engine: OverdoseEngine!
    var privileged: MockPrivileged!
    var store: MemorySessionStore!
    var processes: FakeProcesses!
    var power: FakePower!

    override func setUp() {
        clock = ManualClock()
        scheduler = ManualScheduler(clock: clock)
        assertions = MockAssertions()
        pmset = FakePMSet(false)
        engine = OverdoseEngine(backend: pmset, store: MemoryRecordStore(), clock: clock)
        privileged = MockPrivileged(engine: engine)
        store = MemorySessionStore()
        processes = FakeProcesses()
        power = FakePower()
    }

    func makeController() -> SessionController {
        SessionController(assertions: assertions, privileged: privileged, store: store,
                          clock: clock, scheduler: scheduler, version: "9.9.9",
                          processes: processes, power: power)
    }

    // MARK: Basic transitions

    func testStartsSober() async {
        let c = makeController()
        let s = await c.snapshot()
        XCTAssertEqual(s.mode, .sober)
        XCTAssertNil(s.remainingSeconds)
        XCTAssertEqual(assertions.heldCount, 0)
    }

    func testBumpHoldsOnlySystemIdleAssertion() async {
        let c = makeController()
        let r = await c.handle(.activate(mode: .bump, durationSeconds: 1800, confirmIndefiniteOverdose: false), source: .cli)
        XCTAssertNil(r.error)
        XCTAssertEqual(r.snapshot?.mode, .bump)
        XCTAssertEqual(r.snapshot?.remainingSeconds, 1800)
        XCTAssertEqual(r.snapshot?.source, .cli)
        XCTAssertEqual(assertions.heldKinds, [.preventUserIdleSystemSleep])
        XCTAssertEqual(store.session?.mode, .bump)
        XCTAssertFalse(pmset.value, "Bump must never touch global power settings")
    }

    func testHighHoldsDisplayAssertionAndSwitchHasNoOrphans() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .bump, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .app)
        _ = await c.handle(.activate(mode: .high, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .app)
        XCTAssertEqual(assertions.heldKinds, [.preventUserIdleSystemSleep, .preventUserIdleDisplaySleep])
        XCTAssertEqual(assertions.heldCount, 2, "previous mode's assertions must be released")
        let s = await c.snapshot()
        XCTAssertTrue(s.isIndefinite)
        XCTAssertNil(s.expiresAt)
    }

    func testSoberReleasesEverythingAndIsIdempotent() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .high, durationSeconds: 60, confirmIndefiniteOverdose: false), source: .app)
        for _ in 0..<3 {
            let r = await c.handle(.sober, source: .cli)
            XCTAssertNil(r.error)
            XCTAssertEqual(r.snapshot?.mode, .sober)
        }
        XCTAssertEqual(assertions.heldCount, 0)
        XCTAssertNil(store.session)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testStartingSameModeTwiceRestartsCountdownWithoutDuplicates() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .high, durationSeconds: 3600, confirmIndefiniteOverdose: false), source: .cli)
        scheduler.advance(seconds: 600)
        let r = await c.handle(.activate(mode: .high, durationSeconds: 7200, confirmIndefiniteOverdose: false), source: .cli)
        XCTAssertEqual(r.snapshot?.remainingSeconds, 7200)
        XCTAssertEqual(assertions.heldCount, 2)
        XCTAssertEqual(scheduler.pendingCount, 1)
    }

    func testAssertionFailureLeavesPreviousStateIntact() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .bump, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .app)
        assertions.failNext = true
        let r = await c.handle(.activate(mode: .high, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .app)
        XCTAssertEqual(r.error?.code, .assertionFailed)
        XCTAssertEqual(r.snapshot?.mode, .bump, "never display a mode whose operation failed")
        XCTAssertEqual(assertions.heldKinds, [.preventUserIdleSystemSleep])
    }

    func testRejectsInvalidDurations() async {
        let c = makeController()
        let r1 = await c.handle(.activate(mode: .high, durationSeconds: 0, confirmIndefiniteOverdose: false), source: .cli)
        XCTAssertEqual(r1.error?.code, .invalidDuration)
        let r2 = await c.handle(.activate(mode: .high, durationSeconds: -5, confirmIndefiniteOverdose: false), source: .cli)
        XCTAssertEqual(r2.error?.code, .invalidDuration)
        let r3 = await c.handle(.activate(mode: .bump, durationSeconds: MethDuration.maximumSeconds + 1, confirmIndefiniteOverdose: false), source: .cli)
        XCTAssertEqual(r3.error?.code, .invalidDuration)
        XCTAssertEqual(assertions.heldCount, 0)
    }

    // MARK: Expiry

    func testTimerExpiryReturnsToSober() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .high, durationSeconds: 1800, confirmIndefiniteOverdose: false), source: .cli)
        scheduler.advance(seconds: 1799)
        let mid = await c.snapshot()
        XCTAssertEqual(mid.remainingSeconds, 1)
        scheduler.advance(seconds: 1)
        let ended = await eventually { await c.snapshot().mode == .sober }
        XCTAssertTrue(ended)
        XCTAssertEqual(assertions.heldCount, 0)
        XCTAssertNil(store.session)
    }

    func testWallClockChangeDoesNotAffectRemainingTime() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .bump, durationSeconds: 3600, confirmIndefiniteOverdose: false), source: .app)
        clock.jumpWall(seconds: 86400 * 3) // user sets the date forward
        let s = await c.snapshot()
        XCTAssertEqual(s.mode, .bump)
        XCTAssertEqual(s.remainingSeconds, 3600)
    }

    func testOnChangeNotifiesObservers() async {
        let c = makeController()
        let box = Box()
        await c.setOnChange { box.append($0.mode) }
        _ = await c.handle(.activate(mode: .bump, durationSeconds: 60, confirmIndefiniteOverdose: false), source: .cli)
        _ = await c.handle(.sober, source: .app)
        XCTAssertEqual(box.modes, [.bump, .sober])
    }

    func testConcurrentRequestsAreSerialized() async {
        let c = makeController()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    let mode: SleepMode = [.bump, .high, .sober][i % 3]
                    if mode == .sober {
                        _ = await c.handle(.sober, source: .cli)
                    } else {
                        _ = await c.handle(.activate(mode: mode, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .cli)
                    }
                }
            }
        }
        let s = await c.snapshot()
        XCTAssertEqual(assertions.heldCount, s.mode.assertionKinds.count, "no orphaned or duplicate assertions")
        XCTAssertLessThanOrEqual(scheduler.pendingCount, 1)
    }

    // MARK: Persistence & recovery

    func testRestoreResumesTimedSessionAfterAgentRestart() async {
        let c1 = makeController()
        _ = await c1.handle(.activate(mode: .high, durationSeconds: 3600, confirmIndefiniteOverdose: false), source: .cli)
        clock.advance(seconds: 600)
        // Agent crashes: kernel drops its assertions.
        assertions = MockAssertions()
        let c2 = makeController()
        await c2.restore()
        let s = await c2.snapshot()
        XCTAssertEqual(s.mode, .high)
        XCTAssertEqual(s.remainingSeconds, 3000)
        XCTAssertEqual(assertions.heldCount, 2)
    }

    func testRestoreAfterRebootUsesWallClockAndDropsExpired() async {
        let c1 = makeController()
        _ = await c1.handle(.activate(mode: .bump, durationSeconds: 3600, confirmIndefiniteOverdose: false), source: .cli)
        clock.reboot(after: 1200)
        assertions = MockAssertions()
        let c2 = makeController()
        await c2.restore()
        let resumed = await c2.snapshot()
        XCTAssertEqual(resumed.mode, .bump)
        XCTAssertEqual(resumed.remainingSeconds, 2400)

        clock.reboot(after: 5000)
        assertions = MockAssertions()
        let c3 = makeController()
        await c3.restore()
        let expired = await c3.snapshot()
        XCTAssertEqual(expired.mode, .sober)
        XCTAssertNil(store.session)
    }

    func testIndefiniteSessionDoesNotSurviveReboot() async {
        let c1 = makeController()
        _ = await c1.handle(.activate(mode: .high, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .app)
        clock.reboot(after: 60)
        let c2 = makeController()
        await c2.restore()
        let mode = await c2.snapshot().mode
        XCTAssertEqual(mode, .sober)
    }

    // MARK: Overdose

    func testOverdoseFromCLIRequiresPreference() async {
        let c = makeController()
        let r = await c.handle(.activate(mode: .overdose, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .cli)
        XCTAssertEqual(r.error?.code, .overdoseNotAllowed)
        XCTAssertFalse(pmset.value)

        let denied = await c.handle(.setAllowOverdoseFromCLI(true), source: .cli)
        XCTAssertEqual(denied.error?.code, .unauthorizedClient, "the CLI cannot grant itself permission")

        _ = await c.handle(.setAllowOverdoseFromCLI(true), source: .app)
        let ok = await c.handle(.activate(mode: .overdose, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .cli)
        XCTAssertNil(ok.error)
        XCTAssertEqual(ok.snapshot?.mode, .overdose)
        XCTAssertTrue(pmset.value)
    }

    func testIndefiniteOverdoseNeedsConfirmationAndNeverFromCLI() async {
        let c = makeController()
        _ = await c.handle(.setAllowOverdoseFromCLI(true), source: .app)
        let cli = await c.handle(.activate(mode: .overdose, durationSeconds: nil, confirmIndefiniteOverdose: true), source: .cli)
        XCTAssertEqual(cli.error?.code, .durationRequired)
        let unconfirmed = await c.handle(.activate(mode: .overdose, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .app)
        XCTAssertEqual(unconfirmed.error?.code, .indefiniteOverdoseRequiresConfirmation)
        let confirmed = await c.handle(.activate(mode: .overdose, durationSeconds: nil, confirmIndefiniteOverdose: true), source: .app)
        XCTAssertNil(confirmed.error)
        XCTAssertNotNil(engine.record?.leaseExpiresContinuousNanos, "indefinite Overdose is lease-based")
        XCTAssertNil(engine.record?.deadlineContinuousNanos)
    }

    func testOverdoseRejectsMoreThan24Hours() async {
        let c = makeController()
        let r = await c.handle(.activate(mode: .overdose, durationSeconds: 86401, confirmIndefiniteOverdose: false), source: .app)
        XCTAssertEqual(r.error?.code, .invalidDuration)
    }

    func testOverdoseHelperFailureKeepsPreviousMode() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .high, durationSeconds: nil, confirmIndefiniteOverdose: false), source: .app)
        privileged.unavailable = true
        let r = await c.handle(.activate(mode: .overdose, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .app)
        XCTAssertEqual(r.error?.code, .helperUnavailable)
        XCTAssertEqual(r.snapshot?.mode, .high)
        XCTAssertEqual(assertions.heldCount, 2, "the failed Overdose assertions were rolled back")
        XCTAssertFalse(pmset.value)
    }

    func testOverdoseUnsupportedHardware() async {
        pmset.ignoresWrites = true
        let c = makeController()
        let r = await c.handle(.activate(mode: .overdose, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .app)
        XCTAssertEqual(r.error?.code, .overdoseUnsupported)
        XCTAssertEqual(r.snapshot?.mode, .sober)
        XCTAssertNil(engine.record)
    }

    func testSoberAfterOverdoseRestoresOriginalValue() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .overdose, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .app)
        XCTAssertTrue(pmset.value)
        _ = await c.handle(.sober, source: .app)
        XCTAssertFalse(pmset.value)
        XCTAssertNil(engine.record)
        XCTAssertEqual(assertions.heldCount, 0)
    }

    func testSwitchingFromOverdoseToHighRestoresSleepSetting() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .overdose, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .app)
        _ = await c.handle(.activate(mode: .high, durationSeconds: 600, confirmIndefiniteOverdose: false), source: .app)
        XCTAssertFalse(pmset.value)
        XCTAssertEqual(assertions.heldCount, 2)
    }

    func testOverdoseExpiryRestores() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .overdose, durationSeconds: 60, confirmIndefiniteOverdose: false), source: .app)
        scheduler.advance(seconds: 61)
        let ended = await eventually { await c.snapshot().mode == .sober }
        XCTAssertTrue(ended)
        XCTAssertFalse(pmset.value)
    }

    func testOverdoseIsNeverResumedAfterReboot() async {
        let c1 = makeController()
        _ = await c1.handle(.activate(mode: .overdose, durationSeconds: 3600, confirmIndefiniteOverdose: false), source: .app)
        clock.reboot(after: 30)
        // Helper boot recovery runs first (RunAtLoad).
        engine.recoverAtLaunch()
        XCTAssertFalse(pmset.value)
        let c2 = makeController()
        await c2.restore()
        let mode = await c2.snapshot().mode
        XCTAssertEqual(mode, .sober)
    }

    func testOverdoseResumesAfterAgentCrashWhenHelperStillHoldsSession() async {
        let c1 = makeController()
        _ = await c1.handle(.activate(mode: .overdose, durationSeconds: 3600, confirmIndefiniteOverdose: false), source: .app)
        clock.advance(seconds: 100)
        assertions = MockAssertions()
        let c2 = makeController()
        await c2.restore()
        let s = await c2.snapshot()
        XCTAssertEqual(s.mode, .overdose)
        XCTAssertTrue(pmset.value)
    }

    func testTerminationAlwaysEndsOverdose() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .overdose, durationSeconds: 3600, confirmIndefiniteOverdose: false), source: .app)
        await c.prepareForTermination()
        XCTAssertFalse(pmset.value)
        XCTAssertNil(store.session)
    }

    func testTerminationKeepsTimedBumpForResume() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .bump, durationSeconds: 3600, confirmIndefiniteOverdose: false), source: .app)
        await c.prepareForTermination()
        XCTAssertEqual(assertions.heldCount, 0)
        XCTAssertEqual(store.session?.mode, .bump)
    }

    func testIndefiniteOverdoseLeaseRenewal() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .overdose, durationSeconds: nil, confirmIndefiniteOverdose: true), source: .app)
        let firstLease = engine.record?.leaseExpiresContinuousNanos
        scheduler.advance(seconds: Double(SessionController.overdoseLeaseRenewSeconds))
        let renewed = await eventually { self.engine.record?.leaseExpiresContinuousNanos ?? 0 > firstLease ?? 0 }
        XCTAssertTrue(renewed)
        XCTAssertTrue(privileged.calls.contains("renew"))
    }

    func testLostLeaseDropsOverdose() async {
        let c = makeController()
        _ = await c.handle(.activate(mode: .overdose, durationSeconds: nil, confirmIndefiniteOverdose: true), source: .app)
        // Helper restored on its own (e.g. it was restarted after a lease timeout).
        let id = engine.record!.sessionID
        _ = try? engine.end(sessionID: id)
        scheduler.advance(seconds: Double(SessionController.overdoseLeaseRenewSeconds))
        let dropped = await eventually { await c.snapshot().mode == .sober }
        XCTAssertTrue(dropped, "must not claim Overdose once the helper no longer holds it")
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _modes: [SleepMode] = []
    func append(_ m: SleepMode) { lock.withLock { _modes.append(m) } }
    var modes: [SleepMode] { lock.withLock { _modes } }
}
