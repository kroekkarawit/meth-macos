import SwiftUI
import MethCore

/// Actions the popover asks the app controller to perform (alerts, consent, etc.).
@MainActor
protocol MenuBarActions: AnyObject {
    func select(_ mode: SleepMode)
    func soberUp()
    func durationChanged(to duration: MethDuration)
    func installCLI()
    func manageOverdoseHelper()
    func setAllowOverdoseFromCLI(_ allow: Bool)
    func setLaunchAtLogin(_ enabled: Bool)
    var showsTimeInMenuBar: Bool { get }
    func setShowTimeInMenuBar(_ show: Bool)
    func setLanguage(_ choice: LanguageManager.Choice)
    func chooseCustomDuration()
    func chooseUntilTime()
    func startWhileAppRuns(pid: Int32)
    func extendSession(bySeconds seconds: Int)
    func setBatteryLimit(_ percent: Int?)
    func setEndOnBatteryPower(_ on: Bool)
    func setRule(whileCharging mode: SleepMode?)
    func setRule(withExternalDisplay mode: SleepMode?)
    func setGlobalShortcuts(_ on: Bool)
    func setKeepStatusActive(_ on: Bool)
    func setLockAfterIdle(minutes: Int?)
    func checkForUpdates()
    func showAbout()
    func quit()
}

struct MenuBarView: View {
    @Bindable var model: SessionModel
    let updates: UpdateManager
    let automation: AutomationSettings
    weak var actions: MenuBarActions?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(model: model) { actions?.quit() }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            MenuSeparator()

            VStack(spacing: 0) {
                ModeRow(mode: .sober, symbol: "leaf.fill",
                        title: "Sober", subtitle: String(localized: "Mac sleeps as usual"),
                        model: model, shortcut: "0") { actions?.soberUp() }
                ModeRow(mode: .bump, symbol: "bolt.fill",
                        title: "Bump", subtitle: String(localized: "Keep Mac awake"),
                        model: model, shortcut: "1") { actions?.select(.bump) }
                ModeRow(mode: .high, symbol: "eye.fill",
                        title: "High", subtitle: String(localized: "Keep screen awake"),
                        model: model, shortcut: "2") { actions?.select(.high) }
                ModeRow(mode: .overdose, symbol: "staroflife.fill",
                        title: "Overdose", subtitle: String(localized: "Disable system sleep"),
                        model: model, shortcut: "3") { actions?.select(.overdose) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)

            MenuSeparator()

            HStack {
                Text("Duration")
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                DurationSelector(selection: Binding(
                    get: { model.selectedDuration },
                    set: { actions?.durationChanged(to: $0) }
                ))
                MoreTimeMenu(model: model, actions: actions)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if let error = model.lastError {
                NoticeView(text: ErrorText.localized(error), isError: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else if let warning = model.lastWarnings.first {
                NoticeView(text: ErrorText.localized(warning), isError: false)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else if let ended = EndReasonText.recent(model.snapshot) {
                NoticeView(text: ended, isError: false)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            MenuSeparator()

            FooterView(model: model, updates: updates, automation: automation, actions: actions)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .frame(width: 320)
    }
}

// MARK: - Building blocks (modelled on macOS menu bar extras / Control Center)

/// Hairline separator inset like the ones in system menu bar extras.
struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
            .padding(.horizontal, 14)
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 9)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rounded hover/keyboard-focus highlight used by every clickable row, like system
/// menus. Replaces the default rectangular focus ring; keyboard focus stays visible.
struct RowHighlight: ViewModifier {
    @State private var hovering = false
    @Environment(\.isFocused) private var focused
    @Environment(KeyboardNavigation.self) private var keyboard
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering || (focused && keyboard.isActive) ? Color.primary.opacity(0.08) : .clear)
            )
            .onHover { hovering = $0 }
    }
}

/// Like system menus, nothing is highlighted when the popover opens; the keyboard
/// focus highlight appears once the user starts navigating with Tab or the arrow keys.
@MainActor
@Observable
final class KeyboardNavigation {
    var isActive = false
}

// MARK: - Header

struct HeaderView: View {
    let model: SessionModel
    var onQuit: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Meth")
                    .font(.system(size: 13, weight: .bold))
                StatusLine(model: model)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            QuitButton(action: onQuit)
        }
    }
}

/// Small borderless ⏻ button in the header, like other menu bar utilities.
struct QuitButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "power")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(hovering ? Color.primary.opacity(0.1) : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .help(String(localized: "Quit Meth"))
        .accessibilityLabel(Text("Quit Meth"))
        .accessibilityIdentifier("quit")
    }
}

/// "Normal sleep" / "High · 1:42:15 left". Only this line ticks, and only while visible.
struct StatusLine: View {
    let model: SessionModel

    var body: some View {
        Group {
            if model.mode.isActive, model.snapshot.remainingSeconds != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let app = model.snapshot.watchedProcess?.name {
                        text(String(localized: "\(model.mode.displayName) · \(RemainingFormatter.compactClock(model.remainingSeconds() ?? 0)) left · \(app)"))
                    } else {
                        text(String(localized: "\(model.mode.displayName) · \(RemainingFormatter.compactClock(model.remainingSeconds() ?? 0)) left"))
                    }
                }
            } else if model.mode.isActive, let app = model.snapshot.watchedProcess?.name {
                text(String(localized: "\(model.mode.displayName) · Until \(app) quits"))
            } else if model.mode.isActive {
                text(String(localized: "\(model.mode.displayName) · No time limit"))
            } else {
                text(String(localized: "Keep your Mac awake."))
            }
        }
        .accessibilityIdentifier("status.pill")
    }

    private func text(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Mode rows

struct ModeRow: View {
    let mode: SleepMode
    let symbol: String
    let title: String
    let subtitle: String
    let model: SessionModel
    let shortcut: KeyEquivalent
    let action: () -> Void

    private var isSelected: Bool { model.mode == mode }
    private var isPending: Bool { model.pendingMode == mode }
    private var tint: Color {
        switch mode {
        case .overdose: .orange
        default: .accentColor
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                    if isPending {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    }
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(RowHighlight())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: [])
        .focusEffectDisabled()
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .help(isSelected && mode != .sober ? String(localized: "Click again to turn off") : "")
        .accessibilityLabel(Text(verbatim: "\(title), \(subtitle)"))
        .accessibilityHint(isSelected && mode != .sober ? Text("Click again to turn off") : Text(verbatim: ""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("mode.\(mode.rawValue)")
    }
}

// MARK: - Duration

struct DurationSelector: View {
    @Binding var selection: MethDuration

    var body: some View {
        Picker("Duration", selection: $selection) {
            ForEach(MethDuration.presets, id: \.self) { d in
                Text(verbatim: label(d)).tag(d)
                    .accessibilityLabel(accessibilityLabel(d))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("duration")
    }

    private func label(_ d: MethDuration) -> String {
        switch d {
        case .indefinite: "∞"
        case .seconds(let s) where s < 3600: String(localized: "\(s / 60)m", comment: "Minutes, short")
        case .seconds(let s): String(localized: "\(s / 3600)h", comment: "Hours, short")
        }
    }

    private func accessibilityLabel(_ d: MethDuration) -> String {
        switch d {
        case .indefinite: String(localized: "No time limit")
        case .seconds(let s) where s < 3600: String(localized: "\(s / 60) minutes")
        case .seconds(let s): String(localized: "\(s / 3600) hours")
        }
    }
}

/// "⋯" next to the duration picker: custom duration, until a time, while an app runs, add time.
struct MoreTimeMenu: View {
    let model: SessionModel
    weak var actions: MenuBarActions?

    private var isCustom: Bool { !MethDuration.presets.contains(model.selectedDuration) }

    var body: some View {
        Menu {
            Button("Custom Duration…") { actions?.chooseCustomDuration() }
            Button("Until a Time…") { actions?.chooseUntilTime() }
            Menu("While an App Is Running") {
                ForEach(RunningApps.list(), id: \.pid) { app in
                    Button { actions?.startWhileAppRuns(pid: app.pid) } label: {
                        Label { Text(verbatim: app.name) } icon: { Image(nsImage: app.icon) }
                    }
                }
            }
            Divider()
            Section("Add Time") {
                Button("15 Minutes") { actions?.extendSession(bySeconds: 900) }
                Button("30 Minutes") { actions?.extendSession(bySeconds: 1800) }
                Button("1 Hour") { actions?.extendSession(bySeconds: 3600) }
            }
            .disabled(!model.canExtend)
        } label: {
            if isCustom, let s = model.selectedDuration.seconds {
                Text(verbatim: MethDuration.compact(s)).font(.system(size: 12).monospacedDigit())
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusEffectDisabled()
        .help(String(localized: "More Time Options"))
        .accessibilityLabel(Text("More Time Options"))
        .accessibilityIdentifier("duration.more")
    }
}

/// Regular (Dock) apps the user can tie a session to.
enum RunningApps {
    struct App { let pid: Int32; let name: String; let icon: NSImage }

    @MainActor static func list() -> [App] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
            .compactMap { app -> App? in
                guard let name = app.localizedName else { return nil }
                let icon = (app.icon ?? NSImage()).copy() as! NSImage
                icon.size = NSSize(width: 16, height: 16)
                return App(pid: app.processIdentifier, name: name, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Why the last session ended, shown for a while after an automatic end.
enum EndReasonText {
    static func recent(_ s: SessionSnapshot, now: Date = Date()) -> String? {
        guard s.mode == .sober, let reason = s.lastEndReason, let at = s.lastEndedAt,
              now.timeIntervalSince(at) < 3600 else { return nil }
        switch reason {
        case .processExited: return String(localized: "Ended because the app you chose quit.")
        case .lowBattery:
            let limit = s.preferences.endBelowBatteryPercent ?? AgentPreferences.defaultBatteryLimit
            return String(localized: "Ended because the battery reached \(limit)%.")
        case .onBatteryPower: return String(localized: "Ended because the power adapter was disconnected.")
        case .helperRestored: return String(localized: "Overdose ended and normal sleep was restored.")
        case .manual, .expired: return nil
        }
    }
}

// MARK: - Notices

struct NoticeView: View {
    let text: String
    let isError: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(isError ? .orange : .secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("notice")
    }
}

// MARK: - Footer

struct FooterView: View {
    let model: SessionModel
    let updates: UpdateManager
    let automation: AutomationSettings
    weak var actions: MenuBarActions?

    @State private var launchAtLogin = BackgroundServices.launchAtLogin
    @State private var cliInstalled = CLIInstaller.isInstalled
    @State private var helperState = BackgroundServices.helperState
    @State private var autoUpdate = false
    @State private var language = LanguageManager.current
    @State private var showTime = true

    var body: some View {
        Menu {
                Toggle("Launch Meth at Login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { actions?.setLaunchAtLogin($0); launchAtLogin = BackgroundServices.launchAtLogin }
                ))
                Toggle("Show Time Left in Menu Bar", isOn: Binding(
                    get: { showTime },
                    set: { actions?.setShowTimeInMenuBar($0); showTime = $0 }
                ))
                Divider()
                Menu("Automatically Stay Awake") {
                    Picker("While Charging", selection: Binding(
                        get: { automation.whileCharging },
                        set: { actions?.setRule(whileCharging: $0) }
                    )) { RuleChoices() }
                    Picker("With an External Display", selection: Binding(
                        get: { automation.withExternalDisplay },
                        set: { actions?.setRule(withExternalDisplay: $0) }
                    )) { RuleChoices() }
                }
                Menu("Battery") {
                    Picker("End Session at Low Battery", selection: Binding(
                        get: { model.snapshot.preferences.endBelowBatteryPercent },
                        set: { actions?.setBatteryLimit($0) }
                    )) {
                        Text("Off").tag(Int?.none)
                        ForEach(AgentPreferences.allowedBatteryLimits, id: \.self) { Text(verbatim: "\($0)%").tag(Int?.some($0)) }
                    }
                    Toggle("End Session on Battery Power", isOn: Binding(
                        get: { model.snapshot.preferences.endOnBatteryPower },
                        set: { actions?.setEndOnBatteryPower($0) }
                    ))
                }
                Menu("While You’re Away") {
                    Toggle("Keep Chat Apps Showing You as Active", isOn: Binding(
                        get: { automation.keepStatusActive },
                        set: { actions?.setKeepStatusActive($0) }
                    ))
                    Picker("Lock Screen When Idle", selection: Binding(
                        get: { automation.lockAfterIdleMinutes },
                        set: { actions?.setLockAfterIdle(minutes: $0) }
                    )) {
                        Text("Never").tag(Int?.none)
                        ForEach(AutomationSettings.lockChoices, id: \.self) { m in
                            Text("After \(m) Minutes").tag(Int?.some(m))
                        }
                    }
                }
                Toggle("Global Keyboard Shortcuts (⌃⌥⌘0–3)", isOn: Binding(
                    get: { automation.globalShortcuts },
                    set: { actions?.setGlobalShortcuts($0) }
                ))
                Divider()
                Button(helperTitle) { actions?.manageOverdoseHelper() }
                Toggle("Allow Overdose from Command Line", isOn: Binding(
                    get: { model.snapshot.preferences.allowOverdoseFromCLI },
                    set: { actions?.setAllowOverdoseFromCLI($0) }
                ))
                Divider()
                Button(cliInstalled ? String(localized: "Reinstall Command Line Tool…")
                                    : String(localized: "Install Command Line Tool…")) {
                    actions?.installCLI()
                }
                Picker("Language", selection: Binding(
                    get: { language },
                    set: { language = $0; actions?.setLanguage($0) }
                )) {
                    ForEach(LanguageManager.Choice.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                Divider()
                Button("Check for Updates…") { actions?.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
                Toggle("Automatically Check for Updates", isOn: Binding(
                    get: { autoUpdate },
                    set: { updates.automaticallyChecksForUpdates = $0; autoUpdate = $0 }
                ))
                .disabled(!updates.isConfigured)
                Divider()
                Button("About Meth") { actions?.showAbout() }
                Button("Quit Meth") { actions?.quit() }
                    .keyboardShortcut("q")
        } label: {
            HStack {
                Text("Meth Settings")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                Spacer()
                Text(verbatim: model.isConnected ? "v\(MethVersion.current)" : String(localized: "Connecting…"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(Rectangle())
            .modifier(RowHighlight())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .focusEffectDisabled()
        .accessibilityLabel(Text("Settings"))
        .accessibilityIdentifier("settings.menu")
        .onAppear {
            launchAtLogin = BackgroundServices.launchAtLogin
            cliInstalled = CLIInstaller.isInstalled
            helperState = BackgroundServices.helperState
            autoUpdate = updates.automaticallyChecksForUpdates
            language = LanguageManager.current
            showTime = actions?.showsTimeInMenuBar ?? true
        }
    }

    private var helperTitle: String {
        switch helperState {
        case .enabled: String(localized: "Overdose Helper: Enabled")
        case .requiresApproval: String(localized: "Overdose Helper: Awaiting Approval…")
        case .notRegistered, .notFound: String(localized: "Enable Overdose Helper…")
        }
    }
}

/// Off / Bump / High choices for automatic rules (Overdose is never automatic).
struct RuleChoices: View {
    var body: some View {
        Text("Off").tag(SleepMode?.none)
        Text(verbatim: "Bump").tag(SleepMode?.some(.bump))
        Text(verbatim: "High").tag(SleepMode?.some(.high))
    }
}

/// Localized, user-facing text for agent errors.
enum ErrorText {
    static func localized(_ e: MethError) -> String {
        switch e.code {
        case .agentUnavailable:
            String(localized: "Meth’s background controller is not running. If you turned Meth off in System Settings › General › Login Items, turn it back on.")
        case .helperUnavailable:
            String(localized: "Overdose needs its helper. Choose “Enable Overdose Helper…” from the settings menu.")
        case .helperRequiresApproval:
            String(localized: "Allow Meth in System Settings › General › Login Items to use Overdose.")
        case .overdoseNotAllowed:
            String(localized: "Overdose from the command line is turned off.")
        case .overdoseUnsupported:
            String(localized: "This Mac does not support disabling system sleep, so Overdose is unavailable.")
        case .indefiniteOverdoseRequiresConfirmation:
            String(localized: "An Overdose with no time limit must be confirmed.")
        case .restoreConflict:
            String(localized: "Sleep was already disabled by something else; Meth left it unchanged.")
        case .privilegedOperationFailed:
            String(localized: "Changing the system sleep setting failed. Normal sleep will be restored automatically.")
        case .assertionFailed:
            String(localized: "macOS refused the power assertion.")
        case .invalidDuration, .durationRequired, .usage, .unknownCommand:
            String(localized: "Invalid request.")
        case .unauthorizedClient:
            String(localized: "Not authorized.")
        case .processNotFound:
            String(localized: "That app is no longer running.")
        case .notExtendable:
            String(localized: "Only a session with a time limit can be extended.")
        case .batteryLow:
            String(localized: "The battery is below the limit set in Meth › Battery. Connect power or change the limit.")
        case .internal:
            String(localized: "Something went wrong. Please try again.")
        }
    }
}
