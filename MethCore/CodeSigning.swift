import Foundation
import Security

/// Code-signing helpers used to authenticate XPC peers.
///
/// Policy: a Meth process signed with a Developer ID team only talks to peers signed
/// by the *same team* with an expected bundle identifier. Ad-hoc (local development)
/// builds fall back to identifier-only checks; the privileged helper refuses to run
/// without a team (see MethHelper/main.swift), so Overdose is never exposed by an
/// unsigned build.
public enum CodeSigning {
    /// Team identifier of the running process, or nil for ad-hoc/unsigned builds.
    public static let selfTeamID: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    /// Builds a code requirement string matching any of `identifiers`.
    public static func requirement(identifiers: [String], teamID: String?) -> String {
        let ids = identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ")
        guard let teamID, Self.isValidTeamID(teamID) else {
            return "(\(ids))"
        }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and (\(ids))"
    }

    public static func isValidTeamID(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// Signing identifier of an XPC peer, read from the kernel by audit token.
    ///
    /// This does no file I/O (unlike SecCodeCopyGuestWithAttributes, which may open the
    /// peer's bundle directory and block on a privacy prompt for external volumes).
    /// It does NOT validate the signature: pair it with
    /// `NSXPCListener.setConnectionCodeSigningRequirement`, which XPC enforces before
    /// any message is delivered.
    public static func signingIdentifier(auditToken: Data?) -> String? {
        guard let auditToken, auditToken.count == MemoryLayout<audit_token_t>.size else { return nil }
        var token = audit_token_t()
        _ = withUnsafeMutableBytes(of: &token) { auditToken.copyBytes(to: $0) }
        guard let task = SecTaskCreateWithAuditToken(nil, token) else { return nil }
        var error: Unmanaged<CFError>?
        return SecTaskCopySigningIdentifier(task, &error) as String?
    }
}

extension NSXPCConnection {
    /// The peer's audit token. Not exposed as public API; read via KVC, a widely used
    /// pattern. Falls back to PID-based validation if unavailable.
    public var methAuditToken: Data? {
        guard responds(to: NSSelectorFromString("auditToken")),
              let value = value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        return withUnsafeBytes(of: &token) { Data($0) }
    }
}
