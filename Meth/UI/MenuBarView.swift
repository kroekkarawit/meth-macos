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
    func checkForUpdates()
    func showAbout()
    func quit()
}

struct MenuBarView: View {
    @Bindable var model: SessionModel
    let updates: UpdateManager
    weak var actions: MenuBarActions?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderView(model: model)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            MenuSeparator()

            VStack(spacing: 0) {
                ModeRow(mode: .sober, symbol: "power",
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
            .padding(.horizontal, 5)
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
            }

            MenuSeparator()

            FooterView(model: model, updates: updates, actions: actions)
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "Meth")
                .font(.system(size: 13, weight: .bold))
            StatusLine(model: model)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// "Normal sleep" / "High · 1:42:15 left". Only this line ticks, and only while visible.
struct StatusLine: View {
    let model: SessionModel

    var body: some View {
        Group {
            if model.mode.isActive, model.snapshot.remainingSeconds != nil {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    text(String(localized: "\(model.mode.displayName) · \(RemainingFormatter.compactClock(model.remainingSeconds() ?? 0)) left"))
                }
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
        case .sober: .gray       // matches the grey menu bar icon
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
            .frame(maxWidth: .infinity, minHeight: 24)
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
        case .internal:
            String(localized: "Something went wrong. Please try again.")
        }
    }
}
