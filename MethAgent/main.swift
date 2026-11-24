// MethAgent — the per-user session controller.
//
// Launched on demand by launchd (MachServices) or at login (RunAtLoad), registered by
// Meth.app through SMAppService. It is the *only* process that holds Meth's IOKit power
// assertions and the only client of the privileged helper, so the app and the CLI can
// never compete. It exits when idle; launchd restarts it on the next request.

import Foundation
import os
import MethCore

let log = Logger(subsystem: MethIdentifiers.agentBundleID, category: "agent")

// MARK: - Privileged helper client

final class HelperClient: PrivilegedPowerProviding {
    func begin(sessionID: UUID, deadlineSeconds: Int?, leaseSeconds: Int?) async throws -> HelperResponse {
        try await send(.begin(sessionID: sessionID, deadlineSeconds: deadlineSeconds, leaseSeconds: leaseSeconds))
    }
    func renew(sessionID: UUID) async throws -> HelperResponse { try await send(.renew(sessionID: sessionID)) }
    func end(sessionID: UUID) async throws -> HelperResponse { try await send(.end(sessionID: sessionID)) }
    func status() async throws -> HelperResponse { try await send(.status) }

    private func send(_ request: HelperRequest) async throws -> HelperResponse {
        let c = NSXPCConnection(machServiceName: MethIdentifiers.helperMachService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: MethHelperXPC.self)
        if #available(macOS 13.0, *) {
            c.setCodeSigningRequirement(CodeSigning.requirement(identifiers: [MethIdentifiers.helperBundleID],
                                                                 teamID: CodeSigning.selfTeamID))
        }
        c.resume()
        defer { c.invalidate() }
        let requester = XPCRequester<MethHelperXPC>(connection: c) { conn, onError in
            conn.remoteObjectProxyWithErrorHandler { onError($0) } as? MethHelperXPC
        }
        let payload = MethJSON.encode(HelperEnvelope(request: request))
        let data: Data
        do {
            data = try await requester.send(timeout: 20) { proxy, reply in proxy.perform(payload, reply: reply) }
        } catch {
            throw MethError(.helperUnavailable,
                            "The Overdose helper is not available. Enable Overdose from Meth’s menu (it must be allowed in System Settings › General › Login Items). \(error.localizedDescription)")
        }
        return try MethJSON.decoder().decode(HelperResponse.self, from: data)
    }
}

// MARK: - XPC service

final class AgentService: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let controller: SessionController
    private let lock = NSLock()
    private struct Client {
        let connection: NSXPCConnection
        let source: CommandSource
    }
    private var clients: [ObjectIdentifier: Client] = [:]
    private var idleTimer: DispatchSourceTimer?
    let requirement = CodeSigning.requirement(
        identifiers: [MethIdentifiers.appBundleID, MethIdentifiers.cliBundleID],
        teamID: CodeSigning.selfTeamID)

    init(controller: SessionController) {
        self.controller = controller
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The code-signing requirement itself is enforced by XPC (set on the listener
        // below); here we only map the verified identity to a command source.
        let source: CommandSource
        switch CodeSigning.signingIdentifier(auditToken: connection.methAuditToken) {
        case MethIdentifiers.appBundleID: source = .app
        case MethIdentifiers.cliBundleID: source = .cli
        default:
            log.error("Rejected XPC client pid \(connection.processIdentifier): unexpected identity")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: MethAgentXPC.self)
        connection.exportedObject = ConnectionHandler(service: self, source: source)
        let key = ObjectIdentifier(connection)
        connection.invalidationHandler = { [weak self] in self?.remove(key) }
        connection.interruptionHandler = { [weak self] in self?.remove(key) }
        // Only the app exports a client interface for pushed updates. The CLI is
        // request/response only; pushing to it would tear down its connection.
        if source == .app {
            connection.remoteObjectInterface = NSXPCInterface(with: MethAgentClientXPC.self)
        }
        lock.withLock { clients[key] = Client(connection: connection, source: source) }
        cancelIdleExit()
        connection.resume()
        return true
    }

    private func remove(_ key: ObjectIdentifier) {
        lock.withLock { clients[key] = nil }
        scheduleIdleExitCheck()
    }

    func broadcast(_ snapshot: SessionSnapshot) {
        let data = MethJSON.encode(snapshot)
        let conns = lock.withLock { clients.values.filter { $0.source == .app }.map(\.connection) }
        for c in conns {
            (c.remoteObjectProxyWithErrorHandler { _ in } as? MethAgentClientXPC)?.sessionDidChange(data)
        }
        if !snapshot.mode.isActive { scheduleIdleExitCheck() }
    }

    // Exit after 30 s with no clients and no active session; launchd relaunches on demand.
    func scheduleIdleExitCheck() {
        lock.lock(); defer { lock.unlock() }
        idleTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 30)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                let idle = await self.controller.isIdle
                let noClients = self.lock.withLock { self.clients.isEmpty }
                if idle && noClients {
                    log.info("Idle; exiting")
                    exit(0)
                }
            }
        }
        idleTimer = t
        t.resume()
    }

    private func cancelIdleExit() {
        lock.lock(); idleTimer?.cancel(); idleTimer = nil; lock.unlock()
    }
}

final class ConnectionHandler: NSObject, MethAgentXPC, @unchecked Sendable {
    weak var service: AgentService?
    let source: CommandSource

    init(service: AgentService, source: CommandSource) {
        self.service = service
        self.source = source
    }

    func perform(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let service else { return }
        let envelope: AgentEnvelope
        do {
            envelope = try MethJSON.decoder().decode(AgentEnvelope.self, from: request)
        } catch {
            reply(MethJSON.encode(AgentResponse(snapshot: nil, error: MethError(.usage, "Malformed request."))))
            return
        }
        guard envelope.protocolVersion == AgentEnvelope.currentVersion else {
            reply(MethJSON.encode(AgentResponse(snapshot: nil, error: MethError(
                .usage, "Protocol version \(envelope.protocolVersion) is not supported by agent \(MethVersion.current). Relaunch Meth.app."))))
            return
        }
        // The caller's identity comes from its code signature, never from the envelope.
        let source = self.source
        Task {
            let response = await service.controller.handle(envelope.request, source: source)
            reply(MethJSON.encode(response))
            if case .restartIfIdle = envelope.request, await service.controller.isIdle {
                log.info("Restart requested by app (update); exiting while idle")
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
        }
    }
}

// MARK: - Startup

let controller = SessionController(
    assertions: IOKitPowerAssertions(),
    privileged: HelperClient(),
    store: FileSessionStore()
)
let service = AgentService(controller: controller)

let listener = NSXPCListener(machServiceName: MethIdentifiers.agentMachService)
// Only Meth.app and the meth CLI (same team when Developer ID signed) may connect.
listener.setConnectionCodeSigningRequirement(service.requirement)
listener.delegate = service

// Restore persisted state *before* accepting clients, so nobody observes a stale mode.
Task {
    await controller.setOnChange { snapshot in service.broadcast(snapshot) }
    let warnings = await controller.restore()
    for w in warnings { log.warning("Restore: \(w.code.rawValue, privacy: .public) \(w.message, privacy: .public)") }
    listener.resume()
    service.scheduleIdleExitCheck()
    log.info("MethAgent \(MethVersion.current, privacy: .public) started")
}

// Graceful termination (logout, launchctl bootout): release assertions and always end
// Overdose so a system-wide change never outlives its controller.
signal(SIGTERM, SIG_IGN)
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
termSource.setEventHandler {
    Task {
        await controller.prepareForTermination()
        exit(0)
    }
}
termSource.resume()

dispatchMain()
