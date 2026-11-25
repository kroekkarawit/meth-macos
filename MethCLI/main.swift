// meth — command-line interface to Meth.
//
// A thin client: it parses arguments, sends one request to the per-user agent over XPC,
// prints the result and exits. It never holds assertions itself and never runs as root.

import Foundation
import MethCore

let cliVersion = MethVersion.current
let args = Array(CommandLine.arguments.dropFirst())
let wantsJSON = args.contains("--json") || args.contains("-j")

func languageFor(_ explicit: CLILanguage?) -> CLILanguage {
    CLILanguage.resolve(
        explicit: explicit,
        environment: ProcessInfo.processInfo.environment,
        appLanguages: UserDefaults(suiteName: MethIdentifiers.appBundleID)?.stringArray(forKey: "AppleLanguages"),
        preferred: Locale.preferredLanguages
    )
}

func writeOut(_ s: String) { FileHandle.standardOutput.write(Data((s + "\n").utf8)) }
func writeErr(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func fail(_ e: MethError, json: Bool, strings: CLIStrings) -> Never {
    if json {
        writeOut(CLIOutput.errorJSON(e))
    } else {
        writeErr("meth: \(strings.label(.error)): \(strings.message(for: e))")
    }
    exit(e.code.exitCode)
}

/// Locates Meth.app: the bundle containing this executable (when run via the installed
/// symlink), else whatever LaunchServices knows by bundle identifier.
func appBundleURL() -> URL? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    var url = exe
    for _ in 0..<4 {
        url.deleteLastPathComponent()
        if url.pathExtension == "app" { return url }
    }
    return nil
}

/// Starts Meth.app in the background (no window, no focus) so it can register the agent.
func launchAppInBackground() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let app = appBundleURL() {
        p.arguments = ["-g", "-j", app.path, "--args", "--launched-by-cli"]
    } else {
        p.arguments = ["-g", "-j", "-b", MethIdentifiers.appBundleID, "--args", "--launched-by-cli"]
    }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

func send(_ request: AgentRequest) async throws -> AgentResponse {
    do {
        return try await AgentClient().send(request, source: .cli)
    } catch let e as MethError where e.code == .agentUnavailable {
        // First run, or the agent was never registered: start the app once, then retry.
        launchAppInBackground()
        var lastError = e
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(500))
            do {
                return try await AgentClient().send(request, source: .cli, timeout: 3)
            } catch let e as MethError where e.code == .agentUnavailable {
                lastError = e
            }
        }
        throw lastError
    }
}

let invocation: CLIInvocation
do {
    invocation = try CLIParser.parse(args)
} catch {
    fail(error, json: wantsJSON, strings: CLIStrings(languageFor(nil)))
}
let strings = CLIStrings(languageFor(invocation.language))

let request: AgentRequest
switch invocation.command {
case .help:
    writeOut(strings.help)
    exit(0)
case .version:
    writeOut(invocation.json ? CLIOutput.versionJSON(cliVersion: cliVersion, build: MethVersion.build) : "Meth v\(cliVersion) (\(MethVersion.build))")
    exit(0)
case .status:
    request = .status
case .sober:
    request = .sober
case let .activate(mode, duration, whilePID):
    request = .activate(mode: mode, durationSeconds: duration.seconds, confirmIndefiniteOverdose: false, whilePID: whilePID)
case let .extend(seconds):
    request = .extend(seconds: seconds)
}

// Run off the main actor; the main thread just waits.
let done = DispatchSemaphore(value: 0)
Task.detached {
    defer { done.signal() }
    do {
        let response = try await send(request)
        if let error = response.error {
            fail(error, json: invocation.json, strings: strings)
        }
        guard let snapshot = response.snapshot else {
            fail(MethError(.internal, "Agent returned no state."), json: invocation.json, strings: strings)
        }
        if invocation.json {
            writeOut(CLIOutput.statusJSON(snapshot, cliVersion: cliVersion, warnings: response.warnings))
        } else {
            writeOut(CLIOutput.statusText(snapshot, cliVersion: cliVersion, strings: strings))
            for w in response.warnings {
                writeErr("meth: \(strings.label(.warning)): \(strings.message(for: w))")
            }
        }
    } catch let e as MethError {
        fail(e, json: invocation.json, strings: strings)
    } catch {
        fail(MethError(.internal, error.localizedDescription), json: invocation.json, strings: strings)
    }
}
done.wait()
exit(0)
