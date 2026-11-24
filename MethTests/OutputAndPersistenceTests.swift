import XCTest
@testable import MethCore

final class JSONOutputTests: XCTestCase {
    let started = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11-17T...Z

    func object(_ s: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
    }

    func testActiveStatusSchema() throws {
        let snap = SessionSnapshot(mode: .high, sessionID: UUID(), source: .cli, startedAt: started,
                                   expiresAt: started.addingTimeInterval(7200), remainingSeconds: 6135,
                                   durationSeconds: 7200, agentVersion: "0.1.0",
                                   preferences: AgentPreferences(), generatedAt: started)
        let json = CLIOutput.statusJSON(snap, cliVersion: "0.1.0")
        let o = try object(json)
        XCTAssertEqual(o["schemaVersion"] as? Int, 1)
        XCTAssertEqual(o["app"] as? String, "Meth")
        XCTAssertEqual(o["mode"] as? String, "high")
        XCTAssertEqual(o["status"] as? String, "active")
        XCTAssertEqual(o["remainingSeconds"] as? Int, 6135)
        XCTAssertEqual(o["durationSeconds"] as? Int, 7200)
        XCTAssertEqual(o["indefinite"] as? Bool, false)
        XCTAssertEqual(o["source"] as? String, "cli")
        let expires = try XCTUnwrap(o["expiresAt"] as? String)
        XCTAssertTrue(expires.hasSuffix("Z"), "UTC ISO 8601")
        XCTAssertNotNil(ISO8601.date(from: expires))
        XCTAssertEqual((o["warnings"] as? [Any])?.count, 0)
        XCTAssertFalse(json.contains("\n"), "single line for easy piping")
    }

    func testSoberStatusHasExplicitNulls() throws {
        let json = CLIOutput.statusJSON(.sober(version: "0.1.0", now: started), cliVersion: "0.1.0")
        let o = try object(json)
        XCTAssertEqual(o["mode"] as? String, "sober")
        XCTAssertEqual(o["status"] as? String, "inactive")
        for key in ["remainingSeconds", "expiresAt", "startedAt", "durationSeconds", "source"] {
            XCTAssertTrue(o.keys.contains(key), "\(key) must always be present")
            XCTAssertTrue(o[key] is NSNull, "\(key) must be null when sober")
        }
    }

    func testKeyOrderIsStable() {
        let json = CLIOutput.statusJSON(.sober(version: "1", now: started), cliVersion: "1")
        XCTAssertTrue(json.hasPrefix(#"{"schemaVersion":1,"app":"Meth","version":"1","agentVersion":"1","mode":"sober""#))
    }

    func testErrorJSON() throws {
        let o = try object(CLIOutput.errorJSON(MethError(.invalidDuration, "Bad \"x\"\n")))
        let err = try XCTUnwrap(o["error"] as? [String: Any])
        XCTAssertEqual(err["code"] as? String, "invalid_duration")
        XCTAssertEqual(err["message"] as? String, "Bad \"x\"\n")
    }

    func testHumanStatusMatchesDocumentedFormat() {
        let snap = SessionSnapshot(mode: .high, remainingSeconds: 6135, durationSeconds: 7200,
                                   agentVersion: "0.1.0", preferences: .init(), generatedAt: started)
        XCTAssertEqual(CLIOutput.statusText(snap, cliVersion: "0.1.0", strings: CLIStrings(.en)), """
        Meth v0.1.0
        Mode: High
        Status: Active
        Remaining: 01:42:15
        """)
        XCTAssertEqual(CLIOutput.statusText(.sober(version: "0.1.0"), cliVersion: "0.1.0", strings: CLIStrings(.en)), """
        Meth v0.1.0
        Mode: Sober
        Status: Inactive
        """)
        XCTAssertTrue(CLIOutput.statusText(snap, cliVersion: "0.1.0", strings: CLIStrings(.th)).contains("เวลาที่เหลือ: 01:42:15"))
    }

    func testIPCRoundTrip() throws {
        let env = AgentEnvelope(source: .cli, request: .activate(mode: .bump, durationSeconds: 60, confirmIndefiniteOverdose: false))
        let decoded = try MethJSON.decoder().decode(AgentEnvelope.self, from: MethJSON.encode(env))
        XCTAssertEqual(decoded.request, env.request)
        XCTAssertEqual(decoded.protocolVersion, 1)
        let h = HelperEnvelope(request: .begin(sessionID: UUID(), deadlineSeconds: 10, leaseSeconds: nil))
        XCTAssertEqual(try MethJSON.decoder().decode(HelperEnvelope.self, from: MethJSON.encode(h)).request, h.request)
    }
}

final class PersistenceTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("meth-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSessionRoundTripAndPermissions() throws {
        let store = FileSessionStore(directory: dir)
        XCTAssertNil(store.loadSession())
        let rec = SessionRecord(sessionID: UUID(), mode: .high, source: .cli, startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                durationSeconds: 60, expiresAt: Date(timeIntervalSince1970: 1_800_000_060),
                                deadlineContinuousNanos: 123, bootSessionID: "b")
        try store.saveSession(rec)
        XCTAssertEqual(store.loadSession(), rec)

        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("session.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
        XCTAssertEqual((dirAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        try store.saveSession(nil)
        XCTAssertNil(store.loadSession())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("session.json").path))
    }

    func testCorruptFileIsTreatedAsNoSession() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("session.json"))
        XCTAssertNil(FileSessionStore(directory: dir).loadSession())
    }

    func testPreferencesDefaultToOverdoseFromCLIDisabled() throws {
        let store = FileSessionStore(directory: dir)
        XCTAssertFalse(store.loadPreferences().allowOverdoseFromCLI)
        try store.savePreferences(AgentPreferences(allowOverdoseFromCLI: true))
        XCTAssertTrue(FileSessionStore(directory: dir).loadPreferences().allowOverdoseFromCLI)
    }

    func testOverdoseRecordFileStore() throws {
        let store = FileStore<OverdoseRecord>(url: dir.appendingPathComponent("o.json"))
        let r = OverdoseRecord(sessionID: UUID(), originalSleepDisabled: false, methApplied: true, appliedAt: Date(timeIntervalSince1970: 1_800_000_000),
                               bootSessionID: "b", deadlineContinuousNanos: 5, deadlineWall: nil, leaseExpiresContinuousNanos: nil)
        try store.saveRecord(r)
        XCTAssertEqual(store.loadRecord(), r)
    }
}

final class CodeSigningTests: XCTestCase {
    func testRequirementStrings() {
        XCTAssertEqual(CodeSigning.requirement(identifiers: ["a.b"], teamID: nil), #"(identifier "a.b")"#)
        XCTAssertEqual(CodeSigning.requirement(identifiers: ["a.b", "c.d"], teamID: "HN37P384P3"),
                       #"anchor apple generic and certificate leaf[subject.OU] = "HN37P384P3" and (identifier "a.b" or identifier "c.d")"#)
        // A malformed team id must never be interpolated into a requirement.
        XCTAssertEqual(CodeSigning.requirement(identifiers: ["a.b"], teamID: #"X" or true"#), #"(identifier "a.b")"#)
    }
}
