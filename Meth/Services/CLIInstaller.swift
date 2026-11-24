import Foundation
import AppKit

/// Installs the `meth` command as a symlink to the copy inside Meth.app, so it updates
/// together with the app. Never overwrites a file that is not a Meth symlink and never
/// edits shell configuration files.
@MainActor
enum CLIInstaller {
    enum Location {
        case user    // ~/.local/bin (no admin rights)
        case system  // /usr/local/bin (admin authorization)

        var directory: URL {
            switch self {
            case .user: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
            case .system: URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
            }
        }
        var linkURL: URL { directory.appendingPathComponent("meth") }
    }

    enum InstallError: LocalizedError {
        case bundledToolMissing
        case conflictingFile(String)
        case authorizationFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledToolMissing:
                String(localized: "The command line tool is missing from Meth.app. Please reinstall Meth.")
            case .conflictingFile(let path):
                String(localized: "\(path) already exists and is not Meth’s command line tool. Meth will not overwrite it.")
            case .authorizationFailed(let message):
                message
            }
        }
    }

    static var bundledTool: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/meth")
    }

    enum ExistingState: Equatable {
        case none
        case meth(pointsHere: Bool)
        case foreign
    }

    static func state(at location: Location) -> ExistingState {
        let path = location.linkURL.path
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return .none }
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink,
              let dest = try? fm.destinationOfSymbolicLink(atPath: path) else { return .foreign }
        if dest.hasSuffix(".app/Contents/Helpers/meth") {
            return .meth(pointsHere: dest == bundledTool.path)
        }
        return .foreign
    }

    static var isInstalled: Bool {
        if case .meth = state(at: .user) { return true }
        if case .meth = state(at: .system) { return true }
        return false
    }

    static func install(_ location: Location) throws {
        guard FileManager.default.isExecutableFile(atPath: bundledTool.path) else { throw InstallError.bundledToolMissing }
        if state(at: location) == .foreign { throw InstallError.conflictingFile(location.linkURL.path) }

        switch location {
        case .user:
            let fm = FileManager.default
            try fm.createDirectory(at: location.directory, withIntermediateDirectories: true)
            if state(at: location) != .none { try fm.removeItem(at: location.linkURL) }
            try fm.createSymbolicLink(at: location.linkURL, withDestinationURL: bundledTool)
        case .system:
            // Fixed command with both paths passed through AppleScript's `quoted form of`,
            // so no part of the path can be interpreted by the shell.
            let script = """
            set src to \(appleScriptLiteral(bundledTool.path))
            do shell script "/bin/mkdir -p /usr/local/bin && /bin/ln -sfh " & quoted form of src & " /usr/local/bin/meth" with administrator privileges
            """
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                let message = error[NSAppleScript.errorMessage] as? String ?? String(localized: "Authorization failed.")
                throw InstallError.authorizationFailed(message)
            }
        }
    }

    /// True when `~/.local/bin` appears in the user's login-shell PATH as seen by
    /// launchd. GUI apps don't inherit the shell PATH, so this is a best-effort hint.
    static var userBinLikelyOnPath: Bool {
        let dir = Location.user.directory.path
        return (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == dir }
    }

    static let pathHint = #"export PATH="$HOME/.local/bin:$PATH""#

    private static func appleScriptLiteral(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
