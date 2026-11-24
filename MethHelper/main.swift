// MethHelper — the privileged (root) LaunchDaemon behind Overdose.
//
// Its entire capability is: set `pmset -a disablesleep 1`, and put the ORIGINAL value
// back. It accepts requests only from MethAgent signed by the same Developer ID team,
// validates every argument, persists what it changed before changing it, and enforces
// its own deadline / lease so a crashed or killed client can never leave sleep disabled.
// At boot (RunAtLoad) it restores any record left from a previous boot.

import Foundation
import os
import MethCore

let log = Logger(subsystem: MethIdentifiers.helperBundleID, category: "helper")
let helperVersion = MethVersion.current

let stateURL = URL(fileURLWithPath: "/Library/Application Support/Meth/overdose-state.json")
let engine = OverdoseEngine(backend: PMSetBackend(),
                            store: FileStore<OverdoseRecord>(url: stateURL),
                            clock: SystemClock())
let scheduler = ContinuousScheduler()
let queue = DispatchQueue(label: "helper")

nonisolated(unsafe) var checkTask: ScheduledTask?
nonisolated(unsafe) var idleTimer: DispatchSourceTimer?

func log(outcome: RestoreOutcome?, error: MethError?, context: String) {
    if let error {
        log.error("\(context, privacy: .public): \(error.code.rawValue, privacy: .public) \(error.message, privacy: .public)")
    } else if let outcome {
        log.notice("\(context, privacy: .public): \(String(describing: outcome), privacy: .public)")
    }
}

/// Re-arms the deadline/lease timer, or the idle-exit timer when nothing is active.
/// Must run on `queue`.
func rearm() {
    checkTask?.cancel(); checkTask = nil
    idleTimer?.cancel(); idleTimer = nil
    if let nanos = engine.nanosUntilNextCheck() {
        checkTask = scheduler.schedule(afterNanos: nanos) {
            queue.async {
                let (o, e) = engine.enforceDeadline()
                log(outcome: o, error: e, context: "deadline")
                rearm()
            }
        }
    } else {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 20)
        t.setEventHandler {
            if engine.record == nil {
                log.info("Idle; exiting")
                exit(0)
            }
        }
        idleTimer = t
        t.resume()
    }
}

final class HelperService: NSObject, NSXPCListenerDelegate, MethHelperXPC, @unchecked Sendable {
    let requirement: String?

    override init() {
        if let team = CodeSigning.selfTeamID {
            requirement = CodeSigning.requirement(identifiers: [MethIdentifiers.agentBundleID], teamID: team)
        } else {
            requirement = nil
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        // Fail closed: an ad-hoc signed helper cannot authenticate callers, so it serves nobody.
        guard let requirement else {
            log.error("Helper is not Developer ID signed; refusing all connections")
            return false
        }
        // The team + identifier requirement is enforced by XPC on the listener; this
        // double-checks the identity without touching the file system.
        guard CodeSigning.signingIdentifier(auditToken: c.methAuditToken) == MethIdentifiers.agentBundleID else {
            log.error("Rejected caller pid \(c.processIdentifier)")
            return false
        }
        c.exportedInterface = NSXPCInterface(with: MethHelperXPC.self)
        c.exportedObject = self
        c.resume()
        return true
    }

    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        queue.async {
            reply(MethJSON.encode(self.handle(request)))
            rearm()
        }
    }

    private func handle(_ data: Data) -> HelperResponse {
        guard data.count < 4096,
              let env = try? MethJSON.decoder().decode(HelperEnvelope.self, from: data),
              env.protocolVersion == HelperEnvelope.currentVersion else {
            return HelperResponse(status: nil, error: MethError(.usage, "Malformed or unsupported request."))
        }
        do {
            switch env.request {
            case .status:
                return HelperResponse(status: engine.status(version: helperVersion))
            case let .begin(sessionID, deadline, lease):
                let warnings = try engine.begin(sessionID: sessionID, deadlineSeconds: deadline, leaseSeconds: lease)
                log.notice("Overdose begin session=\(sessionID.uuidString, privacy: .public) deadline=\(deadline ?? -1) lease=\(lease ?? -1)")
                return HelperResponse(status: engine.status(version: helperVersion), warnings: warnings)
            case let .renew(sessionID):
                try engine.renew(sessionID: sessionID)
                return HelperResponse(status: engine.status(version: helperVersion))
            case let .end(sessionID):
                let (outcome, warnings) = try engine.end(sessionID: sessionID)
                log(outcome: outcome, error: nil, context: "end")
                return HelperResponse(status: engine.status(version: helperVersion), warnings: warnings)
            }
        } catch {
            return HelperResponse(status: engine.status(version: helperVersion), error: error)
        }
    }
}

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("MethHelper must be launched by launchd as root.\n".utf8))
    exit(1)
}

// Boot / crash recovery first.
queue.sync {
    let (o, e) = engine.recoverAtLaunch()
    log(outcome: o, error: e, context: "launch-recovery")
    rearm()
}

// SIGTERM means launchd is stopping us: shutdown, or the user removed Meth from
// Login Items. We might never run again, so restore now (fail closed).
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
termSource.setEventHandler {
    if let r = engine.record {
        let (o, e) = (try? engine.end(sessionID: r.sessionID)).map { ($0.0, nil as MethError?) } ?? (nil, MethError(.internal, "end failed"))
        log(outcome: o, error: e, context: "sigterm")
    }
    exit(0)
}
termSource.resume()

let service = HelperService()
let listener = NSXPCListener(machServiceName: MethIdentifiers.helperMachService)
if let requirement = service.requirement {
    listener.setConnectionCodeSigningRequirement(requirement)
}
listener.delegate = service
listener.resume()
log.info("MethHelper \(helperVersion, privacy: .public) started")
dispatchMain()
