import Foundation
import IOKit.pwr_mgt

/// Opaque handle for a set of assertions held together for one mode.
public struct AssertionGroup: Sendable, Equatable {
    public let ids: [UInt32]
    public let kinds: [PowerAssertionKind]
    public init(ids: [UInt32], kinds: [PowerAssertionKind]) {
        self.ids = ids
        self.kinds = kinds
    }
    public static let empty = AssertionGroup(ids: [], kinds: [])
}

/// Creates and releases IOKit power assertions. Mocked in tests.
public protocol PowerAssertionProviding: Sendable {
    /// Creates every assertion for `kinds` or none of them (all-or-nothing).
    func acquire(_ kinds: [PowerAssertionKind], reason: String) throws(MethError) -> AssertionGroup
    func release(_ group: AssertionGroup)
}

/// Native IOPMAssertion implementation. Assertions belong to this process: if the
/// process dies, the kernel releases them automatically, so they can never be orphaned.
public struct IOKitPowerAssertions: PowerAssertionProviding {
    public init() {}

    public func acquire(_ kinds: [PowerAssertionKind], reason: String) throws(MethError) -> AssertionGroup {
        var created: [UInt32] = []
        for kind in kinds {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kind.rawValue as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            guard result == kIOReturnSuccess else {
                created.forEach { IOPMAssertionRelease($0) }
                throw MethError(.assertionFailed,
                                "IOPMAssertionCreateWithName(\(kind.rawValue)) failed with 0x\(String(UInt32(bitPattern: result), radix: 16))")
            }
            created.append(id)
        }
        return AssertionGroup(ids: created, kinds: kinds)
    }

    public func release(_ group: AssertionGroup) {
        for id in group.ids {
            IOPMAssertionRelease(id)
        }
    }
}
