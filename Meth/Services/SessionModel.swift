import Foundation
import Observation
import MethCore
import os

let appLog = Logger(subsystem: MethIdentifiers.appBundleID, category: "app")

/// The app's view of the agent's state. The app never decides the mode itself: it sends
/// requests and renders whatever the agent reports, so the GUI and the CLI always agree.
@MainActor
@Observable
final class SessionModel {
    private(set) var snapshot: SessionSnapshot = .sober(version: MethVersion.current)
    /// Continuous-clock instant when `snapshot` arrived; used for the local countdown.
    private(set) var receivedAt: ContinuousClock.Instant = .now
    private(set) var isConnected = false
    /// Mode currently being requested (shows a spinner on that button).
    private(set) var pendingMode: SleepMode?
    var lastError: MethError?
    var lastWarnings: [MethError] = []

    var selectedDuration: MethDuration {
        didSet { Self.saveDuration(selectedDuration) }
    }

    @ObservationIgnored private var client: AgentClient?
    @ObservationIgnored private lazy var receiver = SnapshotReceiver(model: self)
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var didRequestAgentRestart = false
    @ObservationIgnored private var didRepairAgent = false

    init() {
        selectedDuration = Self.loadDuration()
    }

    var mode: SleepMode { snapshot.mode }

    /// Seconds remaining right now, derived locally from the last snapshot.
    func remainingSeconds(at instant: ContinuousClock.Instant = .now) -> Int? {
        guard let r = snapshot.remainingSeconds else { return nil }
        let elapsed = Int((instant - receivedAt).components.seconds)
        return max(0, r - elapsed)
    }

    // MARK: Connection

    func connect() {
        let c = AgentClient(
            exportedClient: receiver,
            invalidationHandler: { [weak self] in Task { @MainActor in self?.connectionLost() } },
            interruptionHandler: { [weak self] in Task { @MainActor in self?.connectionLost() } }
        )
        client = c
        Task { await refresh() }
    }

    private func connectionLost() {
        isConnected = false
        client = nil
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    func refresh() async {
        await send(.status, pending: nil)
    }

    // MARK: Commands

    /// Starts `mode`. `duration` defaults to the popover's selection; `whilePID` ties the
    /// session to a running app.
    func activate(_ mode: SleepMode, duration: MethDuration? = nil, whilePID: Int32? = nil,
                  confirmIndefiniteOverdose: Bool = false) async {
        guard mode != .sober else { return await sober() }
        await send(.activate(mode: mode, durationSeconds: (duration ?? selectedDuration).seconds,
                             confirmIndefiniteOverdose: confirmIndefiniteOverdose, whilePID: whilePID), pending: mode)
    }

    func extend(bySeconds seconds: Int) async {
        await send(.extend(seconds: seconds), pending: nil)
    }

    func setBatteryRules(endBelowPercent: Int?, endOnBatteryPower: Bool) async {
        await send(.setBatteryRules(endBelowBatteryPercent: endBelowPercent, endOnBatteryPower: endOnBatteryPower), pending: nil)
    }

    /// The mode "Until…" / "While an app is running" apply to: the active one, else the
    /// last one used (High by default).
    var targetMode: SleepMode {
        if mode.isActive { return mode }
        return SleepMode(rawValue: UserDefaults.standard.string(forKey: "lastActiveMode") ?? "") ?? .high
    }

    /// The running session can take more time (timed, not indefinite).
    var canExtend: Bool { mode.isActive && snapshot.remainingSeconds != nil }

    func sober() async {
        await send(.sober, pending: .sober)
    }

    /// Duration changed in the popover: if a session is active, restart it with the new
    /// duration (the countdown restarts from now). Documented in docs/ARCHITECTURE.md.
    func durationChanged() async {
        guard mode.isActive else { return }
        if mode == .overdose && selectedDuration.isIndefinite { return } // caller confirms first
        await activate(mode)
    }

    func setAllowOverdoseFromCLI(_ allow: Bool) async {
        await send(.setAllowOverdoseFromCLI(allow), pending: nil)
    }

    private func send(_ request: AgentRequest, pending: SleepMode?) async {
        if client == nil { connect() }
        guard let client else { return }
        pendingMode = pending
        defer { pendingMode = nil }
        do {
            let response = try await client.send(request, source: .app)
            isConnected = true
            if let s = response.snapshot { apply(s) }
            lastError = response.error
            lastWarnings = response.warnings
            if let e = response.error { appLog.error("Agent error: \(e.code.rawValue, privacy: .public) \(e.message, privacy: .public)") }
        } catch let e as MethError {
            isConnected = false
            if e.code == .agentUnavailable, !didRepairAgent {
                // One self-repair attempt: re-register the LaunchAgent and retry.
                didRepairAgent = true
                await BackgroundServices.reregisterAgent()
                self.client = nil
                connect()
                try? await Task.sleep(for: .seconds(1))
                return await send(request, pending: pending)
            }
            lastError = e
        } catch {
            isConnected = false
            lastError = MethError(.internal, error.localizedDescription)
        }
    }

    fileprivate func apply(_ s: SessionSnapshot) {
        snapshot = s
        receivedAt = .now
        if s.mode.isActive { UserDefaults.standard.set(s.mode.rawValue, forKey: "lastActiveMode") }
        isConnected = true
        // After a Sparkle update the running agent may be older than the app. Swap it
        // for the new binary only while nothing is active, so no session is interrupted.
        if s.agentVersion != MethVersion.current, !s.mode.isActive, !didRequestAgentRestart {
            didRequestAgentRestart = true
            Task { await send(.restartIfIdle, pending: nil) }
        }
        NotificationCenter.default.post(name: .methSessionChanged, object: nil)
    }

    // MARK: Duration persistence

    private static let durationKey = "selectedDurationSeconds"

    private static func loadDuration() -> MethDuration {
        let d = UserDefaults.standard
        guard d.object(forKey: durationKey) != nil else { return .defaultPreset }
        let v = d.integer(forKey: durationKey)
        return v <= 0 ? .indefinite : .seconds(v)
    }

    private static func saveDuration(_ duration: MethDuration) {
        UserDefaults.standard.set(duration.seconds ?? 0, forKey: durationKey)
    }
}

extension Notification.Name {
    static let methSessionChanged = Notification.Name("MethSessionChanged")
}

/// Receives pushed snapshots from the agent on an XPC queue and hops to the main actor.
final class SnapshotReceiver: NSObject, MethAgentClientXPC, @unchecked Sendable {
    weak var model: SessionModel?

    @MainActor init(model: SessionModel) {
        self.model = model
    }

    func sessionDidChange(_ data: Data) {
        guard let snapshot = try? MethJSON.decoder().decode(SessionSnapshot.self, from: data) else { return }
        Task { @MainActor [weak self] in self?.model?.apply(snapshot) }
    }
}
