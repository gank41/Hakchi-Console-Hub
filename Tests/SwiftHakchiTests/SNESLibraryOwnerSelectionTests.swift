import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibraryOwnerSelectionTests {
    func reference(_ id: UUID = UUID()) -> SNESLibraryInstallationReference {
        .init(hwid: String(repeating: "1", count: 32), operationID: id, reviewSHA256: String(repeating: "a", count: 64),
            catalog: URL(fileURLWithPath: "/tmp/SNES-Original-Games-" + UUID().uuidString), catalogSHA256: String(repeating: "b", count: 64))
    }
    @Test func aMatchingCachedInstallationDoesNotScanOrReplaceHistory() async throws {
        let cached = reference(), calls = SNESOwnerSelectionCalls()
        let chosen = try await SNESLibraryOwnerSelection.choose(cached: cached, deviceVersion: 0x6a07, resolve: { ref in
            await calls.add("resolve"); #expect(ref == cached); return (ref.operationID.uuidString, UInt16(0x6a07))
        }, discover: { await calls.add("discover"); return nil })
        #expect(chosen.reference == cached && chosen.owner == cached.operationID.uuidString)
        #expect(await calls.values == ["resolve"])
    }
    @Test(arguments: [UInt16(0x6a07),UInt16(0x6a0b)]) func reconnectAfterAnUpgradeResolvesTheAcceptedMatchingVersionInsteadOfKeepingTheOldHint(_ upgradedVersion:UInt16) async throws {
        let old = reference(), updated = reference(), calls = SNESOwnerSelectionCalls()
        let chosen = try await SNESLibraryOwnerSelection.choose(cached: old, deviceVersion: upgradedVersion, resolve: { ref in
            await calls.add(ref == old ? "old" : "new")
            return (ref.operationID.uuidString, ref == old ? UInt16(0x6a05) : upgradedVersion)
        }, discover: { await calls.add("discover"); return updated })
        #expect(chosen.reference == updated && chosen.owner == updated.operationID.uuidString)
        #expect(await calls.values == ["old", "discover", "new"])
    }
    @Test(arguments: ["damaged-cache-source", "missing-new-version", "wrong-new-version", "foreign-hardware"])
    func invalidEvidenceCannotSilentlyRefreshTheIndex(_ fault: String) async throws {
        let old = reference(), updated = reference(), calls = SNESOwnerSelectionCalls()
        await #expect(throws: (any Error).self) {
            try await SNESLibraryOwnerSelection.choose(cached: old, deviceVersion: 0x6a07, resolve: { ref in
                await calls.add("resolve")
                if fault == "damaged-cache-source" { throw SNESLibraryInstallation.failure() }
                return (ref.operationID.uuidString, UInt16(0x6a05))
            }, discover: {
                await calls.add("discover")
                if fault == "missing-new-version" { return nil }
                if fault == "foreign-hardware" {
                    return SNESLibraryInstallationReference(hwid: String(repeating: "2", count: 32), operationID: updated.operationID,
                        reviewSHA256: updated.reviewSHA256, catalog: updated.catalog, catalogSHA256: updated.catalogSHA256)
                }
                return updated
            })
        }
        if fault == "damaged-cache-source" { #expect(await calls.values == ["resolve"]) }
    }
}
private actor SNESOwnerSelectionCalls { private(set) var values: [String] = []; func add(_ value: String) { values.append(value) } }
