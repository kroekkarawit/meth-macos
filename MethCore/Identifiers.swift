import Foundation

/// Stable identifiers shared by every Meth component.
public enum MethIdentifiers {
    public static let appBundleID = "io.github.kroekkarawit.Meth"
    public static let agentBundleID = "io.github.kroekkarawit.Meth.Agent"
    public static let helperBundleID = "io.github.kroekkarawit.Meth.Helper"
    public static let cliBundleID = "io.github.kroekkarawit.Meth.CLI"

    /// Mach service vended by the per-user LaunchAgent (the session controller).
    public static let agentMachService = agentBundleID
    /// Mach service vended by the privileged LaunchDaemon (Overdose only).
    public static let helperMachService = helperBundleID

    /// launchd plist names inside `Meth.app/Contents/Library/...`.
    public static let agentPlistName = "io.github.kroekkarawit.Meth.Agent.plist"
    public static let helperPlistName = "io.github.kroekkarawit.Meth.Helper.plist"

    public static let appName = "Meth"
}

/// The version compiled into whichever executable is running.
public enum MethVersion {
    public static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
    }
    public static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0"
    }
}
