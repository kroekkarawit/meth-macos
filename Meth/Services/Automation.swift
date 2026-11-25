import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Observation
import MethCore

/// App-side automation preferences (stored in the app's UserDefaults).
/// Battery rules live in the agent instead, so they work while the app is closed.
@MainActor
@Observable
final class AutomationSettings {
    private let d = UserDefaults.standard

    /// Start this mode while the power adapter is connected (Macs with a battery). nil = off.
    var whileCharging: SleepMode? { didSet { save(whileCharging, "rule.whileCharging") } }
    /// Start this mode while an external display is connected. nil = off.
    var withExternalDisplay: SleepMode? { didSet { save(withExternalDisplay, "rule.withExternalDisplay") } }
    /// ⌃⌥⌘0…3 anywhere in macOS.
    var globalShortcuts: Bool { didSet { d.set(globalShortcuts, forKey: "globalShortcuts") } }
    /// Nudge the pointer while you're away so chat apps don't show you as away.
    var keepStatusActive: Bool { didSet { d.set(keepStatusActive, forKey: "keepStatusActive") } }
    /// Lock the screen after this many idle minutes while a session is active. nil = off.
    var lockAfterIdleMinutes: Int? { didSet { d.set(lockAfterIdleMinutes ?? 0, forKey: "lockAfterIdleMinutes") } }

    static let lockChoices = [5, 10, 15, 30]

    init() {
        whileCharging = Self.mode(d.string(forKey: "rule.whileCharging"))
        withExternalDisplay = Self.mode(d.string(forKey: "rule.withExternalDisplay"))
        globalShortcuts = d.object(forKey: "globalShortcuts") as? Bool ?? true
        keepStatusActive = d.bool(forKey: "keepStatusActive")
        let lock = d.integer(forKey: "lockAfterIdleMinutes")
        lockAfterIdleMinutes = lock > 0 ? lock : nil
    }

    private func save(_ m: SleepMode?, _ key: String) { d.set(m?.rawValue, forKey: key) }
    private static func mode(_ raw: String?) -> SleepMode? {
        guard let raw, let m = SleepMode(rawValue: raw), m == .bump || m == .high else { return nil }
        return m
    }
}

// MARK: - Global keyboard shortcuts

/// ⌃⌥⌘0 Sober · ⌃⌥⌘1 Bump · ⌃⌥⌘2 High · ⌃⌥⌘3 Overdose (still asks for consent).
/// Carbon hot keys need no Accessibility permission.
@MainActor
final class GlobalShortcuts {
    static let modes: [SleepMode] = [.sober, .bump, .high, .overdose]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private let onPress: (SleepMode) -> Void

    init(onPress: @escaping (SleepMode) -> Void) { self.onPress = onPress }

    var isRegistered: Bool { handler != nil }

    func register() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<GlobalShortcuts>.fromOpaque(userData).takeUnretainedValue()
            let index = Int(id.id)
            MainActor.assumeIsolated {
                if GlobalShortcuts.modes.indices.contains(index) { me.onPress(GlobalShortcuts.modes[index]) }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let keys = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3]
        for (i, key) in keys.enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey | controlKey),
                                             EventHotKeyID(signature: OSType(0x4D45_5448), id: UInt32(i)), // 'METH'
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) }
        }
    }

    func unregister() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
}

// MARK: - Automatic rules (charger / external display)

/// Starts a session when a condition becomes true and ends it when the condition goes
/// away — but only the session it started itself, and only on changes, so choosing
/// Sober while the charger is connected sticks.
@MainActor
final class AutomaticRules {
    private let settings: AutomationSettings
    private let model: SessionModel
    private let start: (SleepMode) async -> Void
    private var lastWanted: SleepMode?
    private var ownedSessionID: UUID?
    private var observers: [NSObjectProtocol] = []
    private var powerTokens: [Int32] = []
    private let power = SystemPowerSource()

    init(settings: AutomationSettings, model: SessionModel, start: @escaping (SleepMode) async -> Void) {
        self.settings = settings
        self.model = model
        self.start = start
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        })
        powerTokens = SystemPowerSource.observe(queue: .main) { [weak self] in
            Task { @MainActor in self?.evaluate() }
        }
    }

    static var hasExternalDisplay: Bool {
        NSScreen.screens.contains { screen in
            guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(n.uint32Value)) == 0
        }
    }

    /// Re-check after settings change or a power/display event.
    func evaluate() {
        let p = power.current()
        var wanted: SleepMode?
        if let m = settings.whileCharging, p.hasBattery, !p.onBattery { wanted = m }
        if let m = settings.withExternalDisplay, Self.hasExternalDisplay {
            wanted = (wanted == .high || m == .high) ? .high : m
        }
        guard wanted != lastWanted else { return }
        lastWanted = wanted

        if let wanted {
            guard model.mode == .sober || model.snapshot.sessionID == ownedSessionID else { return }
            Task {
                await start(wanted)
                if model.mode == wanted { ownedSessionID = model.snapshot.sessionID }
            }
        } else if let owned = ownedSessionID, model.snapshot.sessionID == owned {
            ownedSessionID = nil
            Task { await model.sober() }
        }
    }
}

// MARK: - Away-from-keyboard helpers

/// While a session is active: optionally nudges the pointer so chat apps keep you
/// "active", and optionally locks the screen after a period without real input.
@MainActor
final class AwayHelper {
    private let settings: AutomationSettings
    private let model: SessionModel
    private var timer: Timer?
    private var lockedThisIdlePeriod = false

    init(settings: AutomationSettings, model: SessionModel) {
        self.settings = settings
        self.model = model
    }

    /// Call when the session or settings change. Runs a 30 s timer only when needed.
    func update() {
        let needed = model.mode.isActive && (settings.keepStatusActive || settings.lockAfterIdleMinutes != nil)
        if needed, timer == nil {
            let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            t.tolerance = 5
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !needed {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Seconds since the last *hardware* input. Our own synthetic nudges are posted from a
    /// private event source, so they don't reset this.
    static var hardwareIdleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
    }

    private func tick() {
        let idle = Self.hardwareIdleSeconds
        if idle < 30 { lockedThisIdlePeriod = false }

        if let minutes = settings.lockAfterIdleMinutes, idle >= Double(minutes * 60), !lockedThisIdlePeriod {
            lockedThisIdlePeriod = true
            Self.lockScreen()
            return
        }
        if settings.keepStatusActive, idle >= 50, !lockedThisIdlePeriod {
            Self.nudgePointer()
        }
    }

    /// Whether macOS lets Meth post pointer events (Privacy & Security › Accessibility).
    static var canPostEvents: Bool { CGPreflightPostEventAccess() }
    @discardableResult static func requestPostEventAccess() -> Bool { CGRequestPostEventAccess() }

    static func nudgePointer() {
        guard canPostEvents, let src = CGEventSource(stateID: .privateState) else { return }
        let p = CGEvent(source: nil)?.location ?? .zero
        for dx in [1.0, -1.0] {
            let e = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                            mouseCursorPosition: CGPoint(x: p.x + dx, y: p.y), mouseButton: .left)
            e?.post(tap: .cghidEventTap)
        }
    }

    /// Locks like ⌃⌘Q. Uses the system's lock call when available, else sleeps the display
    /// (which locks when "Require password immediately" is on).
    static func lockScreen() {
        typealias LockFn = @convention(c) () -> Void
        if let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let sym = dlsym(h, "SACLockScreenImmediate") {
            unsafeBitCast(sym, to: LockFn.self)()
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }
}
