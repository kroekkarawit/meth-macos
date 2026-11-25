import Foundation

/// Client for the privileged helper, as seen by the agent. Mocked in tests.
public protocol PrivilegedPowerProviding: Sendable {
    func begin(sessionID: UUID, deadlineSeconds: Int?, leaseSeconds: Int?) async throws -> HelperResponse
    func renew(sessionID: UUID) async throws -> HelperResponse
    func end(sessionID: UUID) async throws -> HelperResponse
    func status() async throws -> HelperResponse
}

/// The single authoritative owner of Meth's sleep state. It lives in the per-user
/// agent process; the app and CLI are thin clients.
///
/// Every transition runs under an async FIFO gate, so concurrent requests (rapid
/// clicks, parallel CLI invocations, a timer firing mid-switch) are applied one at a
/// time even though some of them await the privileged helper.
public actor SessionController {
    public static let overdoseLeaseSeconds = 600
    public static let overdoseLeaseRenewSeconds = 180

    private let assertions: PowerAssertionProviding
    private let privileged: PrivilegedPowerProviding
    private let store: SessionStore
    private let clock: MethClock
    private let scheduler: MethScheduler
    private let version: String
    private let processes: ProcessWatching
    private let power: PowerSourceReading

    private var record: SessionRecord?
    private var group: AssertionGroup = .empty
    private var expiryTask: ScheduledTask?
    private var leaseTask: ScheduledTask?
    private var processTask: ScheduledTask?
    private var lastPower: PowerSourceState?
    private var lastEndReason: SessionEndReason?
    private var lastEndedAt: Date?
    private var preferences: AgentPreferences
    private var onChange: (@Sendable (SessionSnapshot) -> Void)?

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(assertions: PowerAssertionProviding, privileged: PrivilegedPowerProviding,
                store: SessionStore, clock: MethClock = SystemClock(),
                scheduler: MethScheduler = ContinuousScheduler(), version: String = MethVersion.current,
                processes: ProcessWatching = SystemProcessWatcher(),
                power: PowerSourceReading = SystemPowerSource()) {
        self.processes = processes
        self.power = power
        self.assertions = assertions
        self.privileged = privileged
        self.store = store
        self.clock = clock
        self.scheduler = scheduler
        self.version = version
        self.preferences = store.loadPreferences()
    }

    public func setOnChange(_ handler: (@Sendable (SessionSnapshot) -> Void)?) {
        onChange = handler
    }

    // MARK: Public API

    public var isIdle: Bool { record == nil && !busy }

    public func snapshot() -> SessionSnapshot {
        let now = clock.now()
        guard let r = record else {
            var s = SessionSnapshot.sober(version: version, preferences: preferences, now: now)
            s.lastEndReason = lastEndReason
            s.lastEndedAt = lastEndedAt
            return s
        }
        let remaining = remainingSeconds(for: r)
        return SessionSnapshot(
            mode: r.mode,
            sessionID: r.sessionID,
            source: r.source,
            startedAt: r.startedAt,
            expiresAt: remaining.map { now.addingTimeInterval(TimeInterval($0)) },
            remainingSeconds: remaining,
            durationSeconds: r.durationSeconds,
            agentVersion: version,
            preferences: preferences,
            generatedAt: now,
            watchedProcess: r.watchedProcess
        )
    }

    public func handle(_ request: AgentRequest, source: CommandSource) async -> AgentResponse {
        switch request {
        case .status:
            return AgentResponse(snapshot: snapshot())
        case .sober:
            let warnings = await serialized { me in await me.endSessionLocked(reason: .manual) }
            return AgentResponse(snapshot: snapshot(), warnings: warnings)
        case let .activate(mode, durationSeconds, confirm, whilePID):
            return await respond {
                try await self.serializedThrowing { me in
                    var watched: WatchedProcess?
                    if let pid = whilePID {
                        guard let p = me.processes.identity(pid: pid) else {
                            throw MethError(.processNotFound, "No running process with PID \(pid).")
                        }
                        watched = p
                    }
                    return try await me.activateLocked(mode: mode, durationSeconds: durationSeconds, source: source,
                                                       confirmIndefiniteOverdose: confirm, watched: watched)
                }
            }
        case let .extend(seconds):
            return await respond {
                try await self.serializedThrowing { me in try await me.extendLocked(by: seconds, source: source) }
            }
        case let .setBatteryRules(limit, onBattery):
            guard source == .app else {
                return AgentResponse(snapshot: snapshot(),
                                     error: MethError(.unauthorizedClient, "Only Meth.app can change this preference."))
            }
            if let limit, !AgentPreferences.allowedBatteryLimits.contains(limit) {
                return AgentResponse(snapshot: snapshot(), error: MethError(.usage, "Unsupported battery limit \(limit)%."))
            }
            preferences.endBelowBatteryPercent = limit
            preferences.endOnBatteryPower = onBattery
            try? store.savePreferences(preferences)
            notify()
            return AgentResponse(snapshot: snapshot())
        case let .setAllowOverdoseFromCLI(allow):
            guard source == .app else {
                return AgentResponse(snapshot: snapshot(),
                                     error: MethError(.unauthorizedClient, "Only Meth.app can change this preference."))
            }
            preferences.allowOverdoseFromCLI = allow
            try? store.savePreferences(preferences)
            notify()
            return AgentResponse(snapshot: snapshot())
        case .restartIfIdle:
            // Handled by the agent process; the controller just reports state.
            return AgentResponse(snapshot: snapshot())
        }
    }

    private func respond(_ body: () async throws -> [MethError]) async -> AgentResponse {
        do {
            let warnings = try await body()
            return AgentResponse(snapshot: snapshot(), warnings: warnings)
        } catch let e as MethError {
            return AgentResponse(snapshot: snapshot(), error: e)
        } catch {
            return AgentResponse(snapshot: snapshot(), error: MethError(.internal, "\(error)"))
        }
    }

    /// Called by the agent whenever the power source changes (plugged/unplugged, % change).
    public func powerSourceChanged(_ state: PowerSourceState) async {
        await serialized { me in
            let previous = me.lastPower
            me.lastPower = state
            guard me.record != nil, state.onBattery else { return }
            if me.preferences.endOnBatteryPower, previous.map({ !$0.onBattery }) ?? true {
                _ = await me.endSessionLocked(reason: .onBatteryPower)
            } else if let limit = me.preferences.endBelowBatteryPercent, let pct = state.batteryPercent, pct <= limit {
                _ = await me.endSessionLocked(reason: .lowBattery)
            }
        }
    }

    /// Recovers persisted state at agent start-up. Returns non-fatal warnings.
    @discardableResult
    public func restore() async -> [MethError] {
        await serialized { me in await me.restoreLocked() }
    }

    /// Releases everything when the agent is asked to terminate (logout, SIGTERM).
    /// Bump/High records are kept so a timed session can resume; Overdose is always
    /// ended because a system-wide change must never outlive its controller.
    public func prepareForTermination() async {
        await serialized { me in
            guard let r = me.record else { return }
            if r.mode == .overdose {
                _ = await me.endSessionLocked(reason: .manual)
            } else {
                me.assertions.release(me.group)
                me.group = .empty
                me.cancelTimers()
            }
        }
    }

    // MARK: Transitions (call only while holding the gate)

    private func extendLocked(by seconds: Int, source: CommandSource) async throws -> [MethError] {
        guard seconds > 0 else { throw MethError(.invalidDuration, "Extension must be positive.") }
        guard let r = record else { throw MethError(.notExtendable, "Nothing is running. Start a mode first.") }
        guard r.durationSeconds != nil, let remaining = remainingSeconds(for: r) else {
            throw MethError(.notExtendable, "The current session has no time limit.")
        }
        return try await activateLocked(mode: r.mode, durationSeconds: remaining + seconds, source: source,
                                        confirmIndefiniteOverdose: false, watched: r.watchedProcess)
    }

    private func activateLocked(mode: SleepMode, durationSeconds: Int?, source: CommandSource,
                                confirmIndefiniteOverdose: Bool, watched: WatchedProcess? = nil) async throws -> [MethError] {
        guard mode != .sober else { return await endSessionLocked(reason: .manual) }

        if let limit = preferences.endBelowBatteryPercent {
            let p = power.current()
            if p.onBattery, let pct = p.batteryPercent, pct <= limit {
                throw MethError(.batteryLow, "Battery is at \(pct)%, at or below the \(limit)% limit set in Meth. Connect power or change the limit.")
            }
        }

        if let s = durationSeconds {
            let maxSeconds = mode == .overdose ? MethDuration.maximumOverdoseSeconds : MethDuration.maximumSeconds
            guard s > 0 else { throw MethError(.invalidDuration, "Duration must be positive.") }
            guard s <= maxSeconds else {
                throw MethError(.invalidDuration, "Duration exceeds the maximum of \(MethDuration.compact(maxSeconds)) for \(mode.rawValue).")
            }
        }
        if mode == .overdose {
            if source == .cli && !preferences.allowOverdoseFromCLI {
                throw MethError(.overdoseNotAllowed,
                                "Overdose from the command line is disabled. Enable “Allow Overdose from Command Line” in Meth’s menu.")
            }
            if durationSeconds == nil {
                if source == .cli {
                    throw MethError(.durationRequired, "Overdose requires an explicit duration, e.g. --for 1h.")
                }
                guard confirmIndefiniteOverdose else {
                    throw MethError(.indefiniteOverdoseRequiresConfirmation,
                                    "An indefinite Overdose must be explicitly confirmed.")
                }
            }
        }

        let sessionID = UUID()
        let now = clock.now()
        let nowCont = clock.continuousNanos()

        // 1. Acquire the new assertions before releasing the old ones, so there is no
        //    gap in which the Mac could idle-sleep during a switch.
        let newGroup = try assertions.acquire(mode.assertionKinds, reason: "Meth: \(mode.displayName) mode")
        var warnings: [MethError] = []

        // 2. Privileged part. Only on success is the new mode published.
        if mode == .overdose {
            do {
                let response = try await privileged.begin(
                    sessionID: sessionID,
                    deadlineSeconds: durationSeconds,
                    leaseSeconds: durationSeconds == nil ? Self.overdoseLeaseSeconds : nil
                )
                if let err = response.error { throw err }
                warnings += response.warnings
            } catch {
                assertions.release(newGroup)
                throw Self.asMethError(error, fallback: .helperUnavailable)
            }
        } else if let old = record, old.mode == .overdose {
            warnings += await endPrivileged(sessionID: old.sessionID)
        }

        // 3. Commit.
        assertions.release(group)
        group = newGroup
        cancelTimers()
        record = SessionRecord(
            sessionID: sessionID, mode: mode, source: source, startedAt: now,
            durationSeconds: durationSeconds,
            expiresAt: durationSeconds.map { now.addingTimeInterval(TimeInterval($0)) },
            deadlineContinuousNanos: durationSeconds.map { nowCont &+ UInt64($0) * 1_000_000_000 },
            bootSessionID: clock.bootSessionID(),
            watchedProcess: watched
        )
        lastEndReason = nil
        lastEndedAt = nil
        persist()
        scheduleTimers()
        notify()
        return warnings
    }

    private func endSessionLocked(reason: SessionEndReason) async -> [MethError] {
        guard let r = record else { return [] }
        lastEndReason = reason
        lastEndedAt = clock.now()
        var warnings: [MethError] = []
        if r.mode == .overdose {
            warnings += await endPrivileged(sessionID: r.sessionID)
        }
        assertions.release(group)
        group = .empty
        cancelTimers()
        record = nil
        persist()
        notify()
        return warnings
    }

    private func endPrivileged(sessionID: UUID) async -> [MethError] {
        do {
            let response = try await privileged.end(sessionID: sessionID)
            if let err = response.error { return response.warnings + [err] }
            return response.warnings
        } catch {
            // The helper enforces its own deadline/lease, so the change is still bounded.
            return [MethError(.privilegedOperationFailed,
                              "Could not reach the privileged helper to restore sleep settings; it will restore them when its deadline or lease expires. (\(error.localizedDescription))")]
        }
    }

    private func restoreLocked() async -> [MethError] {
        guard let r = store.loadSession() else { return [] }
        let sameBoot = r.bootSessionID == clock.bootSessionID()

        if r.mode == .overdose {
            // Resume only after an agent crash within the same boot, and only if the
            // helper confirms it still holds this exact session. Never re-enable silently.
            if sameBoot, let status = try? await privileged.status().status,
               status.active, status.sessionID == r.sessionID,
               remainingSeconds(for: r).map({ $0 > 0 }) ?? true,
               let g = try? assertions.acquire(r.mode.assertionKinds, reason: "Meth: Overdose mode") {
                group = g
                record = r
                scheduleTimers()
                if r.durationSeconds == nil { await renewLeaseLocked() }
                notify()
                return []
            }
            let warnings = await endPrivileged(sessionID: r.sessionID)
            record = nil
            persist()
            notify()
            return warnings
        }

        // Bump / High.
        let remaining = remainingSeconds(for: r)
        var resumable: Bool
        if let remaining {
            resumable = remaining > 0
        } else {
            resumable = sameBoot // indefinite sessions do not survive a restart
        }
        if let w = r.watchedProcess, processes.identity(pid: w.pid)?.startTime != w.startTime {
            resumable = false // the watched app quit while the agent was down
        }
        guard resumable else {
            record = nil
            persist()
            notify()
            return []
        }
        do {
            group = try assertions.acquire(r.mode.assertionKinds, reason: "Meth: \(r.mode.displayName) mode")
        } catch {
            record = nil
            persist()
            notify()
            return [error]
        }
        var resumed = r
        if !sameBoot, let remaining {
            resumed.bootSessionID = clock.bootSessionID()
            resumed.deadlineContinuousNanos = clock.continuousNanos() &+ UInt64(remaining) * 1_000_000_000
        }
        record = resumed
        persist()
        scheduleTimers()
        notify()
        return []
    }

    private func expire(sessionID: UUID) async {
        _ = await serialized { me in
            guard let r = me.record, r.sessionID == sessionID else { return [MethError]() }
            if let remaining = me.remainingSeconds(for: r), remaining > 0 {
                me.scheduleTimers() // fired early (tolerance); re-arm
                return []
            }
            return await me.endSessionLocked(reason: .expired)
        }
    }

    private func processExited(sessionID: UUID) async {
        _ = await serialized { me in
            guard let r = me.record, r.sessionID == sessionID else { return [MethError]() }
            return await me.endSessionLocked(reason: .processExited)
        }
    }

    private func renewLease(sessionID: UUID) async {
        await serialized { me in
            guard let r = me.record, r.sessionID == sessionID, r.mode == .overdose, r.durationSeconds == nil else { return }
            await me.renewLeaseLocked()
            me.scheduleTimers()
        }
    }

    private func renewLeaseLocked() async {
        guard let r = record else { return }
        do {
            let response = try await privileged.renew(sessionID: r.sessionID)
            if let err = response.error, err.code == .privilegedOperationFailed || err.code == .restoreConflict {
                // The helper no longer holds our session: it already restored sleep.
                // Do not keep claiming Overdose.
                _ = await endSessionLocked(reason: .helperRestored)
            }
        } catch {
            // Transient: try again at the next renewal; the lease outlives three attempts.
        }
    }

    // MARK: Timers

    private func scheduleTimers() {
        cancelTimers()
        guard let r = record else { return }
        if let remaining = remainingNanos(for: r) {
            let id = r.sessionID
            expiryTask = scheduler.schedule(afterNanos: remaining) { [weak self] in
                Task { await self?.expire(sessionID: id) }
            }
        }
        if let w = r.watchedProcess {
            let id = r.sessionID
            processTask = processes.watch(w) { [weak self] in
                Task { await self?.processExited(sessionID: id) }
            }
        }
        if r.mode == .overdose && r.durationSeconds == nil {
            let id = r.sessionID
            leaseTask = scheduler.schedule(afterNanos: UInt64(Self.overdoseLeaseRenewSeconds) * 1_000_000_000) { [weak self] in
                Task { await self?.renewLease(sessionID: id) }
            }
        }
    }

    private func cancelTimers() {
        expiryTask?.cancel(); expiryTask = nil
        leaseTask?.cancel(); leaseTask = nil
        processTask?.cancel(); processTask = nil
    }

    // MARK: Helpers

    private func remainingNanos(for r: SessionRecord) -> UInt64? {
        guard r.durationSeconds != nil else { return nil }
        if r.bootSessionID == clock.bootSessionID(), let deadline = r.deadlineContinuousNanos {
            let now = clock.continuousNanos()
            return deadline > now ? deadline - now : 0
        }
        guard let expiresAt = r.expiresAt else { return 0 }
        let interval = expiresAt.timeIntervalSince(clock.now())
        return interval > 0 ? UInt64(interval * 1_000_000_000) : 0
    }

    func remainingSeconds(for r: SessionRecord) -> Int? {
        remainingNanos(for: r).map { Int(($0 + 999_999_999) / 1_000_000_000) }
    }

    private func persist() {
        try? store.saveSession(record)
    }

    private func notify() {
        onChange?(snapshot())
    }

    static func asMethError(_ error: Error, fallback: MethErrorCode) -> MethError {
        if let e = error as? MethError { return e }
        return MethError(fallback, error.localizedDescription)
    }

    // MARK: FIFO gate

    private func acquireGate() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func releaseGate() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume() // ownership passes directly to the next waiter
        }
    }

    private func serialized<T: Sendable>(_ body: (isolated SessionController) async -> T) async -> T {
        await acquireGate()
        let result = await body(self)
        releaseGate()
        return result
    }

    private func serializedThrowing<T: Sendable>(_ body: (isolated SessionController) async throws -> T) async throws -> T {
        await acquireGate()
        do {
            let result = try await body(self)
            releaseGate()
            return result
        } catch {
            releaseGate()
            throw error
        }
    }
}
