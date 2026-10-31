import Foundation
import Testing
@testable import SwiftHakchi

struct LegacyStorageReportTests {
    @Test func measuresActiveGamesSeparatelyFromPreviousMenusAndTransfers() throws {
        let report = try LegacyStorageReport.parse(Data("""
        STORAGE_V1
        FREE_KIB=165200
        31000	/var/lib/hakchi/games/nes
        42000	/var/lib/hakchi/games/nes.swift-old-4386FFF9-67E1-49C1-9A45-2023D58130A2
        28000	/var/lib/hakchi/.swift-hakchi-sync-4386FFF9-67E1-49C1-9A45-2023D58130A2
        1000	/var/lib/clover/profiles/0
        END_STORAGE

        """.utf8))
        #expect(report.freeBytes == 165200 * 1024)
        #expect(report.activeGameBytes == 31000 * 1024)
        #expect(report.temporaryBytes == 70000 * 1024)
        #expect(report.entries.count == 4)
    }

    @Test func rejectsPartialOrUnsafeStorageMeasurements() {
        for text in ["STORAGE_V1\nFREE_KIB=10\n", "STORAGE_V1\nFREE_KIB=-1\nEND_STORAGE\n",
                     "STORAGE_V1\nFREE_KIB=10\n5\t/var/lib/hakchi/games/../nes\nEND_STORAGE\n"] {
            #expect(throws: (any Error).self) { try LegacyStorageReport.parse(Data(text.utf8)) }
        }
    }
}
