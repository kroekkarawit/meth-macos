import AppKit
import SwiftUI
import MethCore

/// Owns the status item, the popover and every user-consent dialog.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSPopoverDelegate, MenuBarActions {
    let model = SessionModel()
    let updates = UpdateManager()
    let automation = AutomationSettings()
    private var shortcuts: GlobalShortcuts?
    private var rules: AutomaticRules?
    private var away: AwayHelper?
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var observers: [NSObjectProtocol] = []
    private let keyboardNavigation = KeyboardNavigation()
    private var keyMonitor: Any?

    private static let hasLaunchedKey = "hasLaunchedBefore"
    private static let overdoseAcknowledgedKey = "overdoseAcknowledged"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = ProcessInfo.processInfo.arguments
        let launchedByCLI = args.contains("--launched-by-cli")

        BackgroundServices.ensureAgentRegistered()
        model.connect()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = MenuBarIcon.image(for: .sober)
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.setAccessibilityIdentifier("meth.statusItem")
        }
        updateStatusItem()

        let hosting = NSHostingController(rootView: MenuBarView(model: model, updates: updates,
                                                                automation: automation, actions: self)
            .environment(keyboardNavigation))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        observers.append(NotificationCenter.default.addObserver(forName: .methSessionChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatusItem()
                self?.away?.update()
            }
        })

        shortcuts = GlobalShortcuts { [weak self] mode in self?.select(mode) }
        if automation.globalShortcuts { shortcuts?.register() }
        rules = AutomaticRules(settings: automation, model: model) { [weak self] mode in
            await self?.startSession(mode, duration: .indefinite)
        }
        away = AwayHelper(settings: automation, model: model)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.rules?.evaluate() }

        // UI tests and screenshots open the popover immediately.
        let showNow = args.contains("--show-popover")
        let firstLaunch = !UserDefaults.standard.bool(forKey: Self.hasLaunchedKey)
        UserDefaults.standard.set(true, forKey: Self.hasLaunchedKey)
        if showNow || (firstLaunch && !launchedByCLI) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showPopover() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover() // Re-opening Meth from Finder/Spotlight reveals the popover.
        return false
    }

    // MARK: Status item

    static let showTimeKey = "showTimeInMenuBar"
    private var menuBarTimer: Timer?

    var showsTimeInMenuBar: Bool {
        UserDefaults.standard.object(forKey: Self.showTimeKey) as? Bool ?? true
    }

    func setShowTimeInMenuBar(_ show: Bool) {
        UserDefaults.standard.set(show, forKey: Self.showTimeKey)
        updateStatusItem()
    }

    /// Icon shows the mode; the optional label shows time left. The label is refreshed
    /// once a minute (aligned to the minute it changes), never every second.
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let mode = model.mode
        button.image = MenuBarIcon.image(for: mode)
        let remaining = model.remainingSeconds()

        if showsTimeInMenuBar, mode.isActive, let remaining {
            button.title = " " + MenuBarIcon.timeLabel(remainingSeconds: remaining)
        } else {
            button.title = ""
        }

        var label = "Meth: \(mode.displayName)"
        if let remaining {
            label += ", " + String(localized: "\(RemainingFormatter.compactClock(remaining)) remaining")
        }
        button.setAccessibilityLabel(label)
        button.toolTip = label

        menuBarTimer?.invalidate()
        menuBarTimer = nil
        if showsTimeInMenuBar, mode.isActive, let remaining {
            let untilNextChange = TimeInterval(remaining % 60 == 0 ? 60 : remaining % 60) + 0.2
            let t = Timer(timeInterval: untilNextChange, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatusItem() }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            menuBarTimer = t
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        Task { await model.refresh() }
        keyboardNavigation.isActive = false
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Tab (48) and arrow keys (123–126) turn on the focus highlight.
            if [48, 123, 124, 125, 126].contains(event.keyCode) {
                MainActor.assumeIsolated { self?.keyboardNavigation.isActive = true }
            }
            return event
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: MenuBarActions

    func select(_ mode: SleepMode) {
        // Clicking the mode that is already on turns it off, like a toggle.
        if model.mode == mode, model.pendingMode == nil {
            soberUp()
            return
        }
        Task { await startSession(mode) }
    }

    /// The one path that starts a session (popover, hotkeys, rules, "Until…", "While app…").
    /// Overdose always goes through the helper check and consent dialogs.
    func startSession(_ mode: SleepMode, duration: MethDuration? = nil, whilePID: Int32? = nil) async {
        let d = duration ?? model.selectedDuration
        guard mode == .overdose else {
            await model.activate(mode, duration: d, whilePID: whilePID)
            return
        }
        guard await ensureHelperReady() else { return }
        let indefinite = d.isIndefinite
        if indefinite {
            guard confirmIndefiniteOverdose() else { return }
        } else if !UserDefaults.standard.bool(forKey: Self.overdoseAcknowledgedKey) {
            guard confirmTimedOverdose() else { return }
        }
        await model.activate(.overdose, duration: d, whilePID: whilePID, confirmIndefiniteOverdose: indefinite)
    }

    // MARK: More time options

    func chooseCustomDuration() {
        let alert = makeAlert(title: String(localized: "Custom Duration"),
                              text: String(localized: "Enter a duration such as 45m, 2h or 1h30m."))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "1h30m"
        if let s = model.selectedDuration.seconds { field.stringValue = MethDuration.compact(s) }
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Set"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let maxSeconds = model.mode == .overdose ? MethDuration.maximumOverdoseSeconds : MethDuration.maximumSeconds
        guard let d = try? DurationParser.parse(field.stringValue, maximumSeconds: maxSeconds) else {
            showError(String(localized: "That isn’t a valid duration."),
                      detail: String(localized: "Use forms like 45m, 2h or 1h30m (up to 30 days; 24 hours for Overdose)."))
            return
        }
        durationChanged(to: d)
    }

    func chooseUntilTime() {
        let mode = model.targetMode
        let alert = makeAlert(title: String(localized: "Stay Awake Until…"),
                              text: String(localized: "\(mode.displayName) will end at this time."))
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        picker.datePickerElements = .hourMinute
        picker.datePickerStyle = .textFieldAndStepper
        picker.dateValue = Date().addingTimeInterval(3600)
        picker.sizeToFit()
        alert.accessoryView = picker
        alert.addButton(withTitle: String(localized: "Start"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let cal = Calendar.current
        let c = cal.dateComponents([.hour, .minute], from: picker.dateValue)
        guard let secs = try? CLIParser.secondsUntil(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0),
                                                     now: Date(), calendar: cal) else { return }
        Task { await startSession(mode, duration: .seconds(secs)) }
    }

    func startWhileAppRuns(pid: Int32) {
        Task { await startSession(model.targetMode, duration: .indefinite, whilePID: pid) }
    }

    func extendSession(bySeconds seconds: Int) {
        Task { await model.extend(bySeconds: seconds) }
    }

    // MARK: Battery, automation, shortcuts

    func setBatteryLimit(_ percent: Int?) {
        Task { await model.setBatteryRules(endBelowPercent: percent,
                                           endOnBatteryPower: model.snapshot.preferences.endOnBatteryPower) }
    }

    func setEndOnBatteryPower(_ on: Bool) {
        Task { await model.setBatteryRules(endBelowPercent: model.snapshot.preferences.endBelowBatteryPercent,
                                           endOnBatteryPower: on) }
    }

    func setRule(whileCharging mode: SleepMode?) {
        automation.whileCharging = mode
        rules?.evaluate()
    }

    func setRule(withExternalDisplay mode: SleepMode?) {
        automation.withExternalDisplay = mode
        rules?.evaluate()
    }

    func setGlobalShortcuts(_ on: Bool) {
        automation.globalShortcuts = on
        if on { shortcuts?.register() } else { shortcuts?.unregister() }
    }

    func setKeepStatusActive(_ on: Bool) {
        if on, !AwayHelper.canPostEvents {
            let alert = makeAlert(
                title: String(localized: "Allow Meth to move the pointer?"),
                text: String(localized: "To keep chat apps showing you as active, Meth nudges the pointer by one pixel while you’re away. macOS will ask you to allow Meth in Privacy & Security › Accessibility."))
            alert.addButton(withTitle: String(localized: "Continue"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            AwayHelper.requestPostEventAccess()
        }
        automation.keepStatusActive = on
        away?.update()
    }

    func setLockAfterIdle(minutes: Int?) {
        automation.lockAfterIdleMinutes = minutes
        away?.update()
    }

    func soberUp() {
        Task { await model.sober() }
    }

    func durationChanged(to duration: MethDuration) {
        let previous = model.selectedDuration
        model.selectedDuration = duration
        guard model.mode.isActive else { return }
        Task {
            if model.mode == .overdose {
                if duration.isIndefinite {
                    guard confirmIndefiniteOverdose() else {
                        model.selectedDuration = previous
                        return
                    }
                    await model.activate(.overdose, confirmIndefiniteOverdose: true)
                } else {
                    await model.activate(.overdose)
                }
            } else {
                await model.durationChanged()
            }
        }
    }

    // MARK: Overdose consent

    /// Makes sure the privileged helper is registered *and* approved by the user.
    private func ensureHelperReady() async -> Bool {
        switch BackgroundServices.helperState {
        case .enabled:
            return true
        case .requiresApproval:
            showApprovalAlert()
            return false
        case .notRegistered, .notFound:
            let alert = makeAlert(
                title: String(localized: "Overdose needs a helper"),
                text: String(localized: "To disable system sleep, Meth installs a small privileged helper. It can only turn macOS’s “disablesleep” setting on and back to its original value, and it restores sleep on its own when your time runs out — even if Meth quits.\n\nmacOS will ask you to allow Meth in System Settings › General › Login Items.")
            )
            alert.addButton(withTitle: String(localized: "Install Helper"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            do {
                let state = try BackgroundServices.registerHelper()
                if state == .enabled { return true }
                showApprovalAlert()
            } catch {
                showError(String(localized: "The helper could not be installed."), detail: error.localizedDescription)
            }
            return false
        }
    }

    private func showApprovalAlert() {
        let alert = makeAlert(
            title: String(localized: "Allow Meth in Login Items"),
            text: String(localized: "Turn on Meth under “Allow in the Background” in System Settings › General › Login Items, then choose Overdose again.")
        )
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            BackgroundServices.openLoginItemsSettings()
        }
    }

    private func confirmTimedOverdose() -> Bool {
        let alert = makeAlert(
            title: String(localized: "Start Overdose?"),
            text: String(localized: "Overdose turns off system sleep entirely — including when the lid is closed. Don’t put your Mac in a bag while it is active.\n\nNormal sleep is restored automatically when the time runs out.")
        )
        alert.addButton(withTitle: String(localized: "Start Overdose"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = String(localized: "Don’t ask again for timed sessions")
        let ok = alert.runModal() == .alertFirstButtonReturn
        if ok, alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: Self.overdoseAcknowledgedKey)
        }
        return ok
    }

    private func confirmIndefiniteOverdose() -> Bool {
        let alert = makeAlert(
            title: String(localized: "Overdose with no time limit?"),
            text: String(localized: "System sleep stays off until you choose Sober — including when the lid is closed.\n\nSafety net: if Meth stops running, macOS sleep is restored within 10 minutes, and always at the next restart.")
        )
        alert.alertStyle = .critical
        alert.addButton(withTitle: String(localized: "Start Overdose"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func manageOverdoseHelper() {
        switch BackgroundServices.helperState {
        case .enabled:
            let alert = makeAlert(
                title: String(localized: "Remove the Overdose helper?"),
                text: String(localized: "Overdose will be unavailable until you enable the helper again. Bump and High keep working.")
            )
            alert.addButton(withTitle: String(localized: "Remove Helper"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            Task {
                if model.mode == .overdose { await model.sober() }
                do { try await BackgroundServices.unregisterHelper() } catch {
                    showError(String(localized: "The helper could not be removed."), detail: error.localizedDescription)
                }
            }
        case .requiresApproval:
            showApprovalAlert()
        case .notRegistered, .notFound:
            Task { _ = await ensureHelperReady() }
        }
    }

    func setAllowOverdoseFromCLI(_ allow: Bool) {
        if allow {
            let alert = makeAlert(
                title: String(localized: "Allow Overdose from the command line?"),
                text: String(localized: "Scripts and AI agents running as you will be able to start Overdose with `meth overdose --for <duration>` (24 hours at most). The helper still restores sleep automatically.")
            )
            alert.addButton(withTitle: String(localized: "Allow"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task { await model.setAllowOverdoseFromCLI(allow) }
    }

    // MARK: Settings actions

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try BackgroundServices.setLaunchAtLogin(enabled)
        } catch {
            showError(String(localized: "Launch at Login could not be changed."), detail: error.localizedDescription)
        }
    }

    func installCLI() {
        let userPath = CLIInstaller.Location.user.linkURL.path
        let alert = makeAlert(
            title: String(localized: "Install Command Line Tool"),
            text: String(localized: "Meth will link the `meth` command into \(userPath) for your account. You can also install it for all users in /usr/local/bin (requires an administrator password).")
        )
        alert.addButton(withTitle: String(localized: "Install for Me"))
        alert.addButton(withTitle: String(localized: "Install for All Users…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let response = alert.runModal()
        let location: CLIInstaller.Location
        switch response {
        case .alertFirstButtonReturn: location = .user
        case .alertSecondButtonReturn: location = .system
        default: return
        }
        do {
            try CLIInstaller.install(location)
            var text = String(localized: "Try it: meth status")
            if location == .user && !CLIInstaller.userBinLikelyOnPath {
                text += "\n\n" + String(localized: "If your shell can’t find `meth`, add this line to your shell profile (for example ~/.zshrc):") + "\n\n" + CLIInstaller.pathHint
            }
            let done = makeAlert(title: String(localized: "Command line tool installed"), text: text)
            done.addButton(withTitle: String(localized: "OK"))
            if location == .user { done.addButton(withTitle: String(localized: "Copy PATH Line")) }
            if done.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(CLIInstaller.pathHint, forType: .string)
            }
        } catch {
            showError(String(localized: "The command line tool was not installed."), detail: error.localizedDescription)
        }
    }

    func setLanguage(_ choice: LanguageManager.Choice) {
        guard choice != LanguageManager.current else { return }
        LanguageManager.set(choice)
        let alert = makeAlert(
            title: String(localized: "Relaunch Meth to change the language?"),
            text: String(localized: "Your current session keeps running.")
        )
        alert.addButton(withTitle: String(localized: "Relaunch"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            LanguageManager.relaunch()
        }
    }

    func checkForUpdates() {
        popover.performClose(nil)
        updates.checkForUpdates()
    }

    func showAbout() {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSAttributedString(
            string: String(localized: "Keep your Mac high. Never asleep.\nSleep control for humans and AI agents.\n\nParody notice: Meth’s drug-themed names are a joke. The app only manages macOS power settings.\n\nOpen source under the MIT License."),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    func quit() {
        // The agent owns the session, so it would keep the Mac awake after the app quits.
        // Ask instead of surprising the user.
        guard model.mode.isActive else { NSApp.terminate(nil); return }
        let alert = makeAlert(
            title: String(localized: "Quit Meth?"),
            text: String(localized: "\(model.mode.displayName) is still on. Do you want your Mac to sleep normally again?"))
        alert.addButton(withTitle: String(localized: "Sober and Quit"))
        alert.addButton(withTitle: String(localized: "Keep Awake and Quit"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task {
                await model.sober()
                NSApp.terminate(nil)
            }
        case .alertSecondButtonReturn:
            NSApp.terminate(nil)
        default:
            break
        }
    }

    // MARK: Alerts

    private func makeAlert(title: String, text: String) -> NSAlert {
        popover.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.icon = NSApp.applicationIconImage
        return alert
    }

    private func showError(_ title: String, detail: String) {
        let alert = makeAlert(title: title, text: detail)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
