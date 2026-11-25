import Foundation
@testable import MethCore

final class ManualClock: MethClock, @unchecked Sendable {
    private let lock = NSLock()
    private var wall: Date
    private var cont: UInt64
    private var boot: String

    init(wall: Date = Date(timeIntervalSince1970: 1_800_000_000), cont: UInt64 = 1_000_000_000_000, boot: String = "boot-A") {
        self.wall = wall
        self.cont = cont
        self.boot = boot
    }

    func now() -> Date { lock.withLock { wall } }
    func continuousNanos() -> UInt64 { lock.withLock { cont } }
    func bootSessionID() -> String { lock.withLock { boot } }

    func advance(seconds: Double) {
        lock.withLock {
            wall = wall.addingTimeInterval(seconds)
            cont += UInt64(seconds * 1_000_000_000)
        }
    }

    /// Simulates the user changing the system clock (continuous clock unaffected).
    func jumpWall(seconds: Double) {
        lock.withLock { wall = wall.addingTimeInterval(seconds) }
    }

    /// Simulates a reboot: new boot id, continuous clock restarts.
    func reboot(after seconds: Double) {
        lock.withLock {
            wall = wall.addingTimeInterval(seconds)
            cont = 5_000_000_000
            boot = "boot-\(UUID().uuidString)"
        }
    }
}

final class ManualScheduler: MethScheduler, @unchecked Sendable {
    final class Token: ScheduledTask, @unchecked Sendable {
        let fireAt: UInt64
        let handler: @Sendable () -> Void
        var cancelled = false
        init(fireAt: UInt64, handler: @escaping @Sendable () -> Void) {
            self.fireAt = fireAt
            self.handler = handler
        }
        func cancel() { cancelled = true }
    }

    private let lock = NSLock()
    private var tokens: [Token] = []
    let clock: ManualClock

    init(clock: ManualClock) { self.clock = clock }

    func schedule(afterNanos nanos: UInt64, _ handler: @escaping @Sendable () -> Void) -> ScheduledTask {
        let t = Token(fireAt: clock.continuousNanos() + nanos, handler: handler)
        lock.withLock { tokens.append(t) }
        return t
    }

    var pendingCount: Int { lock.withLock { tokens.filter { !$0.cancelled }.count } }

    /// Advances the clock and fires due timers.
    func advance(seconds: Double) {
        clock.advance(seconds: seconds)
        let now = clock.continuousNanos()
        let due: [Token] = lock.withLock {
            let d = tokens.filter { !$0.cancelled && $0.fireAt <= now }
            tokens.removeAll { $0.cancelled || $0.fireAt <= now }
            return d
        }
        due.forEach { $0.handler() }
    }
}

final class MockAssertions: PowerAssertionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var nextID: UInt32 = 1
    private(set) var held: [UInt32: PowerAssertionKind] = [:]
    var failNext = false

    func acquire(_ kinds: [PowerAssertionKind], reason: String) throws(MethError) -> AssertionGroup {
        lock.lock(); defer { lock.unlock() }
        if failNext { failNext = false; throw MethError(.assertionFailed, "mock failure") }
        var ids: [UInt32] = []
        for k in kinds {
            held[nextID] = k
            ids.append(nextID)
            nextID += 1
        }
        return AssertionGroup(ids: ids, kinds: kinds)
    }

    func release(_ group: AssertionGroup) {
        lock.withLock { group.ids.forEach { held[$0] = nil } }
    }

    var heldKinds: Set<PowerAssertionKind> { lock.withLock { Set(held.values) } }
    var heldCount: Int { lock.withLock { held.count } }
}

/// Privileged helper double backed by a real OverdoseEngine and a fake pmset.
final class MockPrivileged: PrivilegedPowerProviding, @unchecked Sendable {
    let engine: OverdoseEngine
    var unavailable = false
    private(set) var calls: [String] = []

    init(engine: OverdoseEngine) { self.engine = engine }

    private func check(_ name: String) throws {
        calls.append(name)
        if unavailable { throw MethError(.helperUnavailable, "mock helper down") }
    }

    func begin(sessionID: UUID, deadlineSeconds: Int?, leaseSeconds: Int?) async throws -> HelperResponse {
        try check("begin")
        do {
            let w = try engine.begin(sessionID: sessionID, deadlineSeconds: deadlineSeconds, leaseSeconds: leaseSeconds)
            return HelperResponse(status: engine.status(version: "test"), warnings: w)
        } catch { return HelperResponse(status: nil, error: error) }
    }
    func renew(sessionID: UUID) async throws -> HelperResponse {
        try check("renew")
        do { try engine.renew(sessionID: sessionID); return HelperResponse(status: engine.status(version: "test")) }
        catch { return HelperResponse(status: nil, error: error) }
    }
    func end(sessionID: UUID) async throws -> HelperResponse {
        try check("end")
        do { let (_, w) = try engine.end(sessionID: sessionID); return HelperResponse(status: engine.status(version: "test"), warnings: w) }
        catch { return HelperResponse(status: nil, error: error) }
    }
    func status() async throws -> HelperResponse {
        try check("status")
        return HelperResponse(status: engine.status(version: "test"))
    }
}

final class FakePMSet: SleepDisableBackend, @unchecked Sendable {
    private let lock = NSLock()
    var value: Bool
    var ignoresWrites = false
    var failWrites = false
    private(set) var writes: [Bool] = []

    init(_ initial: Bool = false) { value = initial }

    func readSleepDisabled() throws(MethError) -> Bool { lock.withLock { value } }
    func writeSleepDisabled(_ disabled: Bool) throws(MethError) {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw MethError(.privilegedOperationFailed, "pmset failed") }
        writes.append(disabled)
        if !ignoresWrites { value = disabled }
    }
}

final class MemoryRecordStore: FileStoreProtocol, @unchecked Sendable {
    var record: OverdoseRecord?
    func loadRecord() -> OverdoseRecord? { record }
    func saveRecord(_ r: OverdoseRecord?) throws { record = r }
}

final class MemorySessionStore: SessionStore, @unchecked Sendable {
    var session: SessionRecord?
    var prefs = AgentPreferences()
    func loadSession() -> SessionRecord? { session }
    func saveSession(_ record: SessionRecord?) throws { session = record }
    func loadPreferences() -> AgentPreferences { prefs }
    func savePreferences(_ p: AgentPreferences) throws { prefs = p }
}

/// Polls until `condition` holds (timers hop through `Task {}` before reaching the actor).
func eventually(timeout: TimeInterval = 2, _ condition: @escaping () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Process watcher double: processes "run" until `exit(pid:)` is called.
final class FakeProcesses: ProcessWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var running: [Int32: WatchedProcess] = [:]
    private var watchers: [Int32: [@Sendable () -> Void]] = [:]

    func launch(pid: Int32, name: String, start: UInt64 = 1) {
        lock.withLock { running[pid] = WatchedProcess(pid: pid, name: name, startTime: start) }
    }

    func exit(pid: Int32) {
        let handlers: [@Sendable () -> Void] = lock.withLock {
            running[pid] = nil
            return watchers.removeValue(forKey: pid) ?? []
        }
        handlers.forEach { $0() }
    }

    func identity(pid: Int32) -> WatchedProcess? { lock.withLock { running[pid] } }

    func watch(_ process: WatchedProcess, onExit: @escaping @Sendable () -> Void) -> ScheduledTask {
        lock.lock()
        if running[process.pid]?.startTime != process.startTime {
            lock.unlock(); onExit(); return NoopTask()
        }
        watchers[process.pid, default: []].append(onExit)
        lock.unlock()
        return NoopTask()
    }

    struct NoopTask: ScheduledTask { func cancel() {} }
}

final class FakePower: PowerSourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var state: PowerSourceState
    init(_ state: PowerSourceState = PowerSourceState(hasBattery: true, onBattery: false, batteryPercent: 80)) {
        self.state = state
    }
    func set(_ s: PowerSourceState) { lock.withLock { state = s } }
    func current() -> PowerSourceState { lock.withLock { state } }
}
