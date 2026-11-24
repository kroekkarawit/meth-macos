import Foundation

/// Durable storage for the agent's session and preferences.
public protocol SessionStore: Sendable {
    func loadSession() -> SessionRecord?
    func saveSession(_ record: SessionRecord?) throws
    func loadPreferences() -> AgentPreferences
    func savePreferences(_ prefs: AgentPreferences) throws
}

/// JSON files in a private directory (0700), written atomically with 0600 permissions.
public final class FileStore<Value: Codable & Sendable>: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func load() -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MethJSON.decoder().decode(Value.self, from: data)
    }

    public func save(_ value: Value?) throws {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let value else {
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
            return
        }
        let data = try MethJSON.encoder(pretty: true).encode(value)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // rename(2) is atomic within a volume: readers see the old or the new file, never a torn one.
        if rename(tmp.path, url.path) != 0 {
            try? fm.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

public final class FileSessionStore: SessionStore, @unchecked Sendable {
    private let session: FileStore<SessionRecord>
    private let prefs: FileStore<AgentPreferences>

    public init(directory: URL = FileSessionStore.defaultDirectory) {
        session = FileStore(url: directory.appendingPathComponent("session.json"))
        prefs = FileStore(url: directory.appendingPathComponent("agent-preferences.json"))
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Meth", isDirectory: true)
    }

    public func loadSession() -> SessionRecord? { session.load() }
    public func saveSession(_ record: SessionRecord?) throws { try session.save(record) }
    public func loadPreferences() -> AgentPreferences { prefs.load() ?? AgentPreferences() }
    public func savePreferences(_ p: AgentPreferences) throws { try prefs.save(p) }
}
