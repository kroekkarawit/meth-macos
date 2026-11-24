import XCTest
@testable import MethCore

final class OverdoseEngineTests: XCTestCase {
    var clock: ManualClock!
    var pmset: FakePMSet!
    var store: MemoryRecordStore!

    override func setUp() {
        clock = ManualClock()
        pmset = FakePMSet(false)
        store = MemoryRecordStore()
    }

    func makeEngine() -> OverdoseEngine {
        OverdoseEngine(backend: pmset, store: store, clock: clock)
    }

    func testBeginPersistsOriginalAndApplies() throws {
        let e = makeEngine()
        let id = UUID()
        XCTAssertEqual(try e.begin(sessionID: id, deadlineSeconds: 600, leaseSeconds: nil), [])
        XCTAssertTrue(pmset.value)
        XCTAssertEqual(store.record?.sessionID, id)
        XCTAssertEqual(store.record?.originalSleepDisabled, false)
        XCTAssertEqual(store.record?.methApplied, true)
    }

    func testArgumentValidation() {
        let e = makeEngine()
        XCTAssertThrowsError(try e.begin(sessionID: UUID(), deadlineSeconds: nil, leaseSeconds: nil))
        XCTAssertThrowsError(try e.begin(sessionID: UUID(), deadlineSeconds: 60, leaseSeconds: 60))
        XCTAssertThrowsError(try e.begin(sessionID: UUID(), deadlineSeconds: 0, leaseSeconds: nil))
        XCTAssertThrowsError(try e.begin(sessionID: UUID(), deadlineSeconds: 86401, leaseSeconds: nil))
        XCTAssertThrowsError(try e.begin(sessionID: UUID(), deadlineSeconds: nil, leaseSeconds: 3601))
        XCTAssertFalse(pmset.value)
        XCTAssertTrue(pmset.writes.isEmpty)
    }

    func testDeadlineEnforcement() throws {
        let e = makeEngine()
        _ = try e.begin(sessionID: UUID(), deadlineSeconds: 60, leaseSeconds: nil)
        XCTAssertEqual(e.nanosUntilNextCheck(), 60_000_000_000)
        clock.advance(seconds: 59)
        XCTAssertNil(e.enforceDeadline().0)
        XCTAssertTrue(pmset.value)
        clock.advance(seconds: 1)
        XCTAssertEqual(e.enforceDeadline().0, .restored)
        XCTAssertFalse(pmset.value)
        XCTAssertNil(store.record)
        XCTAssertNil(e.nanosUntilNextCheck())
    }

    func testLeaseExpiresWithoutRenewal() throws {
        let e = makeEngine()
        let id = UUID()
        _ = try e.begin(sessionID: id, deadlineSeconds: nil, leaseSeconds: 600)
        clock.advance(seconds: 500)
        try e.renew(sessionID: id)
        clock.advance(seconds: 500)
        XCTAssertNil(e.enforceDeadline().0, "renewed lease is still valid")
        clock.advance(seconds: 101)
        XCTAssertEqual(e.enforceDeadline().0, .restored)
        XCTAssertFalse(pmset.value)
    }

    func testRenewRejectsUnknownSession() throws {
        let e = makeEngine()
        _ = try e.begin(sessionID: UUID(), deadlineSeconds: nil, leaseSeconds: 600)
        XCTAssertThrowsError(try e.renew(sessionID: UUID()))
    }

    func testEndRejectsForeignSessionAndIsIdempotent() throws {
        let e = makeEngine()
        let id = UUID()
        _ = try e.begin(sessionID: id, deadlineSeconds: 600, leaseSeconds: nil)
        XCTAssertThrowsError(try e.end(sessionID: UUID()))
        XCTAssertTrue(pmset.value)
        XCTAssertEqual(try e.end(sessionID: id).0, .restored)
        XCTAssertNil(try e.end(sessionID: id).0) // nothing left to do
    }

    func testPreexistingDisableSleepIsLeftAlone() throws {
        pmset.value = true // someone else already disabled sleep
        let e = makeEngine()
        let id = UUID()
        let warnings = try e.begin(sessionID: id, deadlineSeconds: 600, leaseSeconds: nil)
        XCTAssertEqual(warnings.first?.code, .restoreConflict)
        XCTAssertTrue(pmset.writes.isEmpty, "no write when already disabled")
        XCTAssertEqual(try e.end(sessionID: id).0, .leftAsOriginal)
        XCTAssertTrue(pmset.value, "original value (1) is preserved")
    }

    func testExternalRestoreIsDetectedNotOverwritten() throws {
        let e = makeEngine()
        let id = UUID()
        _ = try e.begin(sessionID: id, deadlineSeconds: 600, leaseSeconds: nil)
        pmset.value = false // user ran `sudo pmset -a disablesleep 0` meanwhile
        let writesBefore = pmset.writes.count
        XCTAssertEqual(try e.end(sessionID: id).0, .alreadyRestored)
        XCTAssertEqual(pmset.writes.count, writesBefore, "nothing written")
    }

    func testTakeoverKeepsOriginalValue() throws {
        let e = makeEngine()
        _ = try e.begin(sessionID: UUID(), deadlineSeconds: 600, leaseSeconds: nil)
        let second = UUID()
        _ = try e.begin(sessionID: second, deadlineSeconds: 1200, leaseSeconds: nil)
        XCTAssertEqual(store.record?.sessionID, second)
        XCTAssertEqual(store.record?.originalSleepDisabled, false, "original must not become 'true' on takeover")
        XCTAssertEqual(try e.end(sessionID: second).0, .restored)
        XCTAssertFalse(pmset.value)
    }

    func testRecoveryAfterRebootRestoresImmediately() throws {
        let e1 = makeEngine()
        _ = try e1.begin(sessionID: UUID(), deadlineSeconds: 3600, leaseSeconds: nil)
        clock.reboot(after: 10)
        let e2 = makeEngine() // helper launched at boot, loads persisted record
        XCTAssertEqual(e2.recoverAtLaunch().0, .restored)
        XCTAssertFalse(pmset.value)
        XCTAssertNil(store.record)
    }

    func testRecoveryAfterHelperCrashWithinDeadlineKeepsSession() throws {
        let e1 = makeEngine()
        _ = try e1.begin(sessionID: UUID(), deadlineSeconds: 3600, leaseSeconds: nil)
        clock.advance(seconds: 100)
        let e2 = makeEngine()
        XCTAssertNil(e2.recoverAtLaunch().0)
        XCTAssertTrue(pmset.value)
        XCTAssertNotNil(e2.record)
    }

    func testCrashBetweenPersistAndApplyIsRecoverable() throws {
        // Simulate: record persisted, then pmset write failed.
        pmset.failWrites = true
        let e = makeEngine()
        XCTAssertThrowsError(try e.begin(sessionID: UUID(), deadlineSeconds: 600, leaseSeconds: nil))
        XCTAssertNil(store.record, "failed apply leaves no record behind")
        XCTAssertFalse(pmset.value)
    }

    func testUnsupportedHardwareIsDetected() {
        pmset.ignoresWrites = true
        let e = makeEngine()
        XCTAssertThrowsError(try e.begin(sessionID: UUID(), deadlineSeconds: 600, leaseSeconds: nil)) {
            XCTAssertEqual(($0 as? MethError)?.code, .overdoseUnsupported)
        }
        XCTAssertNil(store.record)
    }
}
