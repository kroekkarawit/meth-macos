import Foundation

/// Minimal request/response helper over NSXPCConnection with a timeout. Used by the
/// app and CLI (to reach the agent) and by the agent (to reach the helper).
public final class XPCRequester<Remote>: @unchecked Sendable {
    public let connection: NSXPCConnection
    private let makeProxy: (NSXPCConnection, @escaping @Sendable (Error) -> Void) -> Remote?

    public init(connection: NSXPCConnection,
                makeProxy: @escaping (NSXPCConnection, @escaping @Sendable (Error) -> Void) -> Remote?) {
        self.connection = connection
        self.makeProxy = makeProxy
    }

    /// Sends `payload` through `call` and waits up to `timeout` seconds for the reply.
    public func send(timeout: TimeInterval,
                     _ call: @escaping (Remote, @escaping @Sendable (Data) -> Void) -> Void) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = OnceFlag()
            let finish: @Sendable (Result<Data, Error>) -> Void = { result in
                guard once.claim() else { return }
                cont.resume(with: result)
            }
            guard let proxy = makeProxy(connection, { error in finish(.failure(error)) }) else {
                finish(.failure(MethError(.agentUnavailable, "Could not create XPC proxy.")))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(.failure(MethError(.agentUnavailable, "Timed out waiting for a reply.")))
            }
            call(proxy) { data in finish(.success(data)) }
        }
    }
}

/// Thread-safe one-shot flag.
public final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    public init() {}
    public func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Client for the per-user agent. Thread-safe; reuse one instance per process.
public final class AgentClient: @unchecked Sendable {
    public let connection: NSXPCConnection
    private let requester: XPCRequester<MethAgentXPC>

    /// - Parameter exportedClient: optional object receiving pushed snapshots (the app).
    public init(exportedClient: MethAgentClientXPC? = nil,
                invalidationHandler: (@Sendable () -> Void)? = nil,
                interruptionHandler: (@Sendable () -> Void)? = nil) {
        let c = NSXPCConnection(machServiceName: MethIdentifiers.agentMachService, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: MethAgentXPC.self)
        if let exportedClient {
            c.exportedInterface = NSXPCInterface(with: MethAgentClientXPC.self)
            c.exportedObject = exportedClient
        }
        // Verify we are talking to the genuine agent (same team when signed).
        if #available(macOS 13.0, *) {
            c.setCodeSigningRequirement(CodeSigning.requirement(identifiers: [MethIdentifiers.agentBundleID],
                                                                 teamID: CodeSigning.selfTeamID))
        }
        c.invalidationHandler = invalidationHandler
        c.interruptionHandler = interruptionHandler
        c.resume()
        connection = c
        requester = XPCRequester(connection: c) { conn, onError in
            conn.remoteObjectProxyWithErrorHandler { onError($0) } as? MethAgentXPC
        }
    }

    deinit { connection.invalidate() }

    public func send(_ request: AgentRequest, source: CommandSource, timeout: TimeInterval = 10) async throws -> AgentResponse {
        let payload = MethJSON.encode(AgentEnvelope(source: source, request: request))
        let data: Data
        do {
            data = try await requester.send(timeout: timeout) { proxy, reply in
                proxy.perform(payload, reply: reply)
            }
        } catch let e as MethError {
            throw e
        } catch {
            throw MethError(.agentUnavailable, "Meth agent is not reachable: \(error.localizedDescription)")
        }
        do {
            return try MethJSON.decoder().decode(AgentResponse.self, from: data)
        } catch {
            throw MethError(.internal, "Malformed reply from agent: \(error.localizedDescription)")
        }
    }
}
