import Foundation

/// Reads/writes the system-wide `disablesleep` setting. The production backend shells
/// out to `/usr/bin/pmset` with a fixed argument vector (never a shell). Mocked in tests.
public protocol SleepDisableBackend: Sendable {
    /// Current value of the `SleepDisabled` system setting.
    func readSleepDisabled() throws(MethError) -> Bool
    func writeSleepDisabled(_ disabled: Bool) throws(MethError)
}

/// Durable record of what the helper changed, persisted root-only so the change can be
/// undone after a helper crash or a reboot.
public struct OverdoseRecord: Codable, Equatable, Sendable {
    public var sessionID: UUID
    /// The value of `SleepDisabled` before Meth touched it.
    public var originalSleepDisabled: Bool
    /// Whether Meth actually wrote `disablesleep 1` (false if it was already 1).
    public var methApplied: Bool
    public var appliedAt: Date
    public var bootSessionID: String
    /// Hard deadline (continuous clock, same boot) and its wall-clock twin.
    public var deadlineContinuousNanos: UInt64?
    public var deadlineWall: Date?
    /// Lease expiry for indefinite sessions (continuous clock).
    public var leaseExpiresContinuousNanos: UInt64?

    enum CodingKeys: String, CodingKey {
        case sessionID, originalSleepDisabled, methApplied, appliedAt, bootSessionID,
             deadlineContinuousNanos, deadlineWall, leaseExpiresContinuousNanos
    }
}

/// Outcome of a restore attempt.
public enum RestoreOutcome: Equatable, Sendable {
    /// We wrote `disablesleep 0` back.
    case restored
    /// The setting was already 0 (someone else restored it); nothing to do.
    case alreadyRestored
    /// It was 1 before Meth started, so Meth leaves it at 1.
    case leftAsOriginal
}

/// The helper's decision logic, independent of XPC, launchd and pmset.
public final class OverdoseEngine: @unchecked Sendable {
    public static let maxDeadlineSeconds = MethDuration.maximumOverdoseSeconds
    public static let maxLeaseSeconds = 3600

    private let backend: SleepDisableBackend
    private let store: FileStoreProtocol
    private let clock: MethClock
    private let lock = NSRecursiveLock()
    public private(set) var record: OverdoseRecord?

    public init(backend: SleepDisableBackend, store: FileStoreProtocol, clock: MethClock) {
        self.backend = backend
        self.store = store
        self.clock = clock
        self.record = store.loadRecord()
    }

    /// Called at helper launch. Restores immediately if the record is from a previous
    /// boot (Overdose never survives a restart) or its deadline/lease has passed.
    @discardableResult
    public func recoverAtLaunch() -> (RestoreOutcome?, MethError?) {
        lock.lock(); defer { lock.unlock() }
        guard let r = record else { return (nil, nil) }
        if r.bootSessionID != clock.bootSessionID() || isExpired(r) {
            return restoreLocked()
        }
        return (nil, nil)
    }

    public func begin(sessionID: UUID, deadlineSeconds: Int?, leaseSeconds: Int?) throws(MethError) -> [MethError] {
        lock.lock(); defer { lock.unlock() }
        switch (deadlineSeconds, leaseSeconds) {
        case let (d?, nil):
            guard d > 0, d <= Self.maxDeadlineSeconds else {
                throw MethError(.invalidDuration, "Overdose deadline must be between 1 second and 24 hours.")
            }
        case let (nil, l?):
            guard l > 0, l <= Self.maxLeaseSeconds else {
                throw MethError(.invalidDuration, "Overdose lease must be between 1 second and 1 hour.")
            }
        default:
            throw MethError(.usage, "Exactly one of deadline or lease is required.")
        }

        let nowCont = clock.continuousNanos()
        let deadlineCont = deadlineSeconds.map { nowCont &+ UInt64($0) * 1_000_000_000 }
        let leaseCont = leaseSeconds.map { nowCont &+ UInt64($0) * 1_000_000_000 }
        let deadlineWall = deadlineSeconds.map { clock.now().addingTimeInterval(TimeInterval($0)) }

        if var existing = record {
            // Taking over (mode re-selected / duration changed): keep the ORIGINAL value.
            existing.sessionID = sessionID
            existing.deadlineContinuousNanos = deadlineCont
            existing.deadlineWall = deadlineWall
            existing.leaseExpiresContinuousNanos = leaseCont
            if !(try backend.readSleepDisabled()) {
                // Someone set it back to 0 behind our back; re-apply for the new session.
                try apply()
                existing.methApplied = true
            }
            try save(existing)
            return []
        }

        let original = try backend.readSleepDisabled()
        var applied = false
        if !original {
            // Persist intent *before* changing the system, so a crash between the two
            // steps still leads to a restore at next launch.
            let pending = OverdoseRecord(sessionID: sessionID, originalSleepDisabled: false, methApplied: true,
                                         appliedAt: clock.now(), bootSessionID: clock.bootSessionID(),
                                         deadlineContinuousNanos: deadlineCont, deadlineWall: deadlineWall,
                                         leaseExpiresContinuousNanos: leaseCont)
            try save(pending)
            do {
                try apply()
            } catch {
                try? save(nil)
                throw error
            }
            applied = true
        }
        let rec = OverdoseRecord(sessionID: sessionID, originalSleepDisabled: original, methApplied: applied,
                                 appliedAt: clock.now(), bootSessionID: clock.bootSessionID(),
                                 deadlineContinuousNanos: deadlineCont, deadlineWall: deadlineWall,
                                 leaseExpiresContinuousNanos: leaseCont)
        try save(rec)
        return original
            ? [MethError(.restoreConflict, "System sleep was already disabled before Overdose; Meth will leave it that way when Overdose ends.")]
            : []
    }

    public func renew(sessionID: UUID) throws(MethError) {
        lock.lock(); defer { lock.unlock() }
        guard var r = record, r.sessionID == sessionID else {
            throw MethError(.privilegedOperationFailed, "No active Overdose session with that identifier.")
        }
        guard r.leaseExpiresContinuousNanos != nil else { return } // deadline sessions need no renewal
        r.leaseExpiresContinuousNanos = clock.continuousNanos() &+ UInt64(SessionController.overdoseLeaseSeconds) * 1_000_000_000
        try save(r)
    }

    public func end(sessionID: UUID) throws(MethError) -> (RestoreOutcome?, [MethError]) {
        lock.lock(); defer { lock.unlock() }
        guard let r = record else { return (nil, []) }   // idempotent
        guard r.sessionID == sessionID else {
            throw MethError(.unauthorizedClient, "Overdose is owned by a different session.")
        }
        let (outcome, err) = restoreLocked()
        if let err { throw err }
        return (outcome, [])
    }

    /// Called by the helper's timer. Restores if the deadline or lease has passed.
    @discardableResult
    public func enforceDeadline() -> (RestoreOutcome?, MethError?) {
        lock.lock(); defer { lock.unlock() }
        guard let r = record, isExpired(r) else { return (nil, nil) }
        return restoreLocked()
    }

    /// Nanoseconds until the next deadline/lease check, if any.
    public func nanosUntilNextCheck() -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        guard let r = record else { return nil }
        let now = clock.continuousNanos()
        let candidates = [r.deadlineContinuousNanos, r.leaseExpiresContinuousNanos].compactMap { $0 }
        guard let next = candidates.min() else { return nil }
        return next > now ? next - now : 0
    }

    public func status(version: String) -> HelperStatus {
        lock.lock(); defer { lock.unlock() }
        let now = try? backend.readSleepDisabled()
        guard let r = record else {
            return HelperStatus(active: false, sessionID: nil, sleepDisabledNow: now, originalSleepDisabled: nil,
                                remainingSeconds: nil, helperVersion: version)
        }
        let remaining = r.deadlineContinuousNanos.map { d -> Int in
            let c = clock.continuousNanos()
            return d > c ? Int((d - c) / 1_000_000_000) : 0
        }
        return HelperStatus(active: true, sessionID: r.sessionID, sleepDisabledNow: now,
                            originalSleepDisabled: r.originalSleepDisabled, remainingSeconds: remaining,
                            helperVersion: version)
    }

    // MARK: Internals

    private func isExpired(_ r: OverdoseRecord) -> Bool {
        if r.bootSessionID != clock.bootSessionID() { return true }
        let now = clock.continuousNanos()
        if let d = r.deadlineContinuousNanos, now >= d { return true }
        if let l = r.leaseExpiresContinuousNanos, now >= l { return true }
        return false
    }

    private func apply() throws(MethError) {
        try backend.writeSleepDisabled(true)
        // Verify: some hardware/OS combinations silently ignore the setting.
        guard try backend.readSleepDisabled() else {
            try? backend.writeSleepDisabled(false)
            throw MethError(.overdoseUnsupported, "This Mac did not accept `disablesleep`; Overdose is unsupported here.")
        }
    }

    /// Restores the original value without clobbering changes made by others.
    private func restoreLocked() -> (RestoreOutcome?, MethError?) {
        guard let r = record else { return (nil, nil) }
        let outcome: RestoreOutcome
        if r.originalSleepDisabled || !r.methApplied {
            outcome = .leftAsOriginal
        } else {
            let current: Bool
            do { current = try backend.readSleepDisabled() } catch { return (nil, error) }
            if !current {
                outcome = .alreadyRestored
            } else {
                do { try backend.writeSleepDisabled(false) } catch { return (nil, error) }
                outcome = .restored
            }
        }
        do { try save(nil) } catch { return (outcome, error) }
        return (outcome, nil)
    }

    private func save(_ r: OverdoseRecord?) throws(MethError) {
        do {
            try store.saveRecord(r)
            record = r
        } catch {
            throw MethError(.internal, "Could not persist Overdose state: \(error.localizedDescription)")
        }
    }
}

public protocol FileStoreProtocol: Sendable {
    func loadRecord() -> OverdoseRecord?
    func saveRecord(_ r: OverdoseRecord?) throws
}

extension FileStore: FileStoreProtocol where Value == OverdoseRecord {
    public func loadRecord() -> OverdoseRecord? { load() }
    public func saveRecord(_ r: OverdoseRecord?) throws { try save(r) }
}

/// `pmset`-based backend used by the root helper.
public struct PMSetBackend: SleepDisableBackend {
    public init() {}

    public func readSleepDisabled() throws(MethError) -> Bool {
        let out = try Self.run(["-g"])
        return Self.parseSleepDisabled(out)
    }

    public func writeSleepDisabled(_ disabled: Bool) throws(MethError) {
        _ = try Self.run(["-a", "disablesleep", disabled ? "1" : "0"])
    }

    /// `pmset -g` prints `SleepDisabled 1` in the system-wide section when set and
    /// omits the line (or prints 0) otherwise.
    public static func parseSleepDisabled(_ output: String) -> Bool {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                return parts[1] == "1"
            }
        }
        return false
    }

    static func run(_ args: [String]) throws(MethError) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            throw MethError(.privilegedOperationFailed, "Could not run pmset: \(error.localizedDescription)")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MethError(.privilegedOperationFailed, "pmset \(args.joined(separator: " ")) exited \(p.terminationStatus): \(msg)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
