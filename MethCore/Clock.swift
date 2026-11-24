import Foundation
import Darwin

/// Time source abstraction so tests can drive expiry deterministically.
///
/// Deadlines are tracked on the *continuous* clock (`mach_continuous_time`), which
/// keeps counting while the Mac sleeps and is unaffected by wall-clock changes. The
/// wall clock is used only for display and for recovery across restarts.
public protocol MethClock: Sendable {
    func now() -> Date
    func continuousNanos() -> UInt64
    func bootSessionID() -> String
}

public struct SystemClock: MethClock {
    public init() {}

    public func now() -> Date { Date() }

    public func continuousNanos() -> UInt64 {
        // CLOCK_MONOTONIC on Darwin is backed by mach_continuous_time (includes sleep).
        clock_gettime_nsec_np(CLOCK_MONOTONIC)
    }

    public func bootSessionID() -> String {
        SystemClock.cachedBootSessionID
    }

    private static let cachedBootSessionID: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else {
            return "unknown-boot"
        }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buf, &size, nil, 0) == 0 else {
            return "unknown-boot"
        }
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }()
}

/// One-shot timer scheduling on the continuous clock.
public protocol MethScheduler: Sendable {
    /// Calls `handler` once `nanos` of continuous time have elapsed. Returns a token
    /// whose `cancel()` prevents the call.
    func schedule(afterNanos nanos: UInt64, _ handler: @escaping @Sendable () -> Void) -> ScheduledTask
}

public protocol ScheduledTask: Sendable {
    func cancel()
}

/// Production scheduler backed by Swift's `ContinuousClock`, which dispatch maps to
/// its monotonic (sleep-inclusive) clock: a deadline that passes while the Mac is
/// asleep fires promptly on wake, and setting the system clock does not move it.
public struct ContinuousScheduler: MethScheduler {
    public init() {}

    public func schedule(afterNanos nanos: UInt64, _ handler: @escaping @Sendable () -> Void) -> ScheduledTask {
        let task = Task.detached {
            do {
                try await Task.sleep(for: .nanoseconds(Int64(clamping: nanos)), tolerance: .seconds(1), clock: .continuous)
            } catch {
                return // cancelled
            }
            handler()
        }
        return TaskToken(task: task)
    }

    struct TaskToken: ScheduledTask {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }
}
