import AppKit

// Meth is a menu bar-only app (LSUIElement): no Dock icon, no main window.
// Quitting Meth.app does NOT end the session: sessions are owned by the per-user agent,
// so a timed Bump/High keeps running and expires on schedule. Use Sober to stop.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(controller) {
        app.run()
    }
}
