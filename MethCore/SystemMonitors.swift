import Foundation
import Darwin
import IOKit.ps
import notify

// MARK: - Processes ("keep awake while this app is running")

public protocol ProcessWatching: Sendable {
    /// Identity of a running process, or nil if `pid` isn't running.
    func identity(pid: Int32) -> WatchedProcess?
    /// Calls `onExit` once when the process exits (immediately if it already has).
    func watch(_ process: WatchedProcess, onExit: @escaping @Sendable () -> Void) -> ScheduledTask
}

public struct SystemProcessWatcher: ProcessWatching {
    public init() {}

    public func identity(pid: Int32) -> WatchedProcess? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let start = UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec)
        let name = withUnsafeBytes(of: info.pbi_name) { raw -> String in
            let s = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            return s
        }
        let fallback = withUnsafeBytes(of: info.pbi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return WatchedProcess(pid: pid, name: name.isEmpty ? fallback : name, startTime: start)
    }

    public func watch(_ process: WatchedProcess, onExit: @escaping @Sendable () -> Void) -> ScheduledTask {
        let once = OnceCall(onExit)
        let source = DispatchSource.makeProcessSource(identifier: process.pid, eventMask: .exit,
                                                      queue: .global(qos: .utility))
        source.setEventHandler { once.call(); source.cancel() }
        source.resume()
        // The process may have exited (or the PID been reused) before the source was armed.
        if identity(pid: process.pid)?.startTime != process.startTime {
            once.call()
            source.cancel()
        }
        return DispatchSourceToken(source: source)
    }

    struct DispatchSourceToken: ScheduledTask, @unchecked Sendable {
        let source: DispatchSourceProcess
        func cancel() { source.cancel() }
    }
}

/// Runs a closure at most once, from any thread.
final class OnceCall: @unchecked Sendable {
    private let lock = NSLock()
    private var body: (@Sendable () -> Void)?
    init(_ body: @escaping @Sendable () -> Void) { self.body = body }
    func call() {
        lock.lock()
        let b = body
        body = nil
        lock.unlock()
        b?()
    }
}

// MARK: - Power source (battery rules)

public struct PowerSourceState: Equatable, Sendable {
    public var hasBattery: Bool
    public var onBattery: Bool
    /// 0…100, nil if unknown or no battery.
    public var batteryPercent: Int?
    public init(hasBattery: Bool, onBattery: Bool, batteryPercent: Int?) {
        self.hasBattery = hasBattery
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
    }
    public static let ac = PowerSourceState(hasBattery: false, onBattery: false, batteryPercent: nil)
}

public protocol PowerSourceReading: Sendable {
    func current() -> PowerSourceState
}

public struct SystemPowerSource: PowerSourceReading {
    public init() {}

    public func current() -> PowerSourceState {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .ac }
        let providing = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPMBatteryPowerKey
        var percent: Int?
        var hasBattery = false
        if let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                hasBattery = true
                if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    percent = Int((Double(cur) / Double(max) * 100).rounded())
                }
            }
        }
        return PowerSourceState(hasBattery: hasBattery, onBattery: onBattery && hasBattery, batteryPercent: percent)
    }

    /// Calls `handler` on `queue` whenever the power source or battery percentage changes.
    /// Uses notifyd, so it works without a run loop (the agent runs `dispatchMain()`).
    /// Returns the notify tokens; pass them to `notify_cancel` to stop.
    @discardableResult
    public static func observe(queue: DispatchQueue, _ handler: @escaping @Sendable () -> Void) -> [Int32] {
        var tokens: [Int32] = []
        for name in [kIOPSNotifyAnyPowerSource] {
            var token: Int32 = 0
            if notify_register_dispatch(name, &token, queue, { _ in handler() }) == NOTIFY_STATUS_OK {
                tokens.append(token)
            }
        }
        return tokens
    }
}
