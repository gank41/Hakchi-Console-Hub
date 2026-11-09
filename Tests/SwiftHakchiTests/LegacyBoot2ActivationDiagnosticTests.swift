import Foundation
import Testing
@testable import SwiftHakchi

struct LegacyBoot2ActivationDiagnosticTests {
    @Test func firmwareJournalRootIsFixedInsideNESWorkspace() throws {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Development/NES/Backups/StockKernelRestoreJournals", isDirectory: true)
        #expect(RecoveryFirmwareJournalPolicy.root == expected.standardizedFileURL)
        // This legacy workflow is intentionally bound to the evidence owner's
        // account. CI uses another account and must be refused without writing.
        if (try? RecoveryFirmwareJournalPolicy.requireOwner()) != nil {
            try RecoveryFirmwareJournalPolicy.require(expected)
        } else {
            #expect(throws: (any Error).self) {
                try RecoveryFirmwareJournalPolicy.require(expected)
            }
        }
        #expect(throws: (any Error).self) {
            try RecoveryFirmwareJournalPolicy.require(expected.deletingLastPathComponent())
        }
        #expect(throws: (any Error).self) {
            try RecoveryFirmwareJournalPolicy.requireOwner(uid: 0)
        }
        #expect(throws: (any Error).self) {
            try RecoveryFirmwareJournalPolicy.requireOwner(home: URL(fileURLWithPath: "/Users/another-account"))
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func alternateJournalRootCannotStartPhysicalPreflight() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try LegacyBoot2ActivationJournal.prepare(material: knownLegacyActivationMaterial(), root: root)
        await #expect(throws: (any Error).self) {
            try await LegacyBoot2ActivationDiagnostic.run(
                mode: .preflight(prepared.operation.path, prepared.reviewSHA256),
                loadInputs: { Issue.record("alternate root reached recovery payload"); throw RecoveryProbeError.refused("unexpected") },
                makeIO: { Issue.record("alternate root opened USB"); return NativeLegacyBoot2ActivationIO() })
        }
    }
    @Test func modesRequireAbsolutePathsAndReviewedDigest() throws {
        let sha = String(repeating: "a", count: 64)
        #expect(try LegacyBoot2ActivationDiagnosticOptions.parseIfPresent(["--prepare-legacy-boot2", "/snapshot", "/stock", "/journals"]) == .prepare("/snapshot", "/stock", "/journals"))
        #expect(try LegacyBoot2ActivationDiagnosticOptions.parseIfPresent(["--write-legacy-boot2", "/operation", sha]) == .write("/operation", sha))
        #expect(try LegacyBoot2ActivationDiagnosticOptions.parseIfPresent(["--inspect"]) == nil)
        for args in [["--write-legacy-boot2"], ["--preflight-legacy-boot2", "relative", sha],
                     ["--inspect-legacy-boot2", "/operation", "bad"],
                     ["--prepare-legacy-boot2", "/snapshot", "/stock"]] {
            #expect(throws: (any Error).self) { try LegacyBoot2ActivationDiagnosticOptions.parseIfPresent(args) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func offlineReviewAndMenuConfirmationNeverOpenUSBOrRevealHardwareID() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let material = try knownLegacyActivationMaterial()
        let prepared = try LegacyBoot2ActivationJournal.prepare(material: material, root: root)
        func offline(_ mode: LegacyBoot2ActivationDiagnosticOptions) async throws -> String {
            try await LegacyBoot2ActivationDiagnostic.run(mode: mode,
                loadInputs: { Issue.record("offline legacy review loaded recovery payload"); throw RecoveryProbeError.refused("unexpected") },
                makeIO: { Issue.record("offline legacy review opened USB"); return NativeLegacyBoot2ActivationIO() })
        }
        let review = try await offline(.inspect(prepared.operation.path, prepared.reviewSHA256))
        #expect(review.contains("prepared") && review.contains(LegacyBoot2ActivationPlan.legacySHA256))
        #expect(!review.contains(material.plan.expectedHWID))
        await #expect(throws: (any Error).self) { try await offline(.confirm(prepared.operation.path, prepared.reviewSHA256)) }
        do {
            let journal = try LegacyBoot2ActivationJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256)
            try await journal.append(.preflightVerified)
            try await journal.append(.burnIntent)
            try await journal.append(.readbackVerified)
            try await journal.close()
        }
        #expect(try await offline(.confirm(prepared.operation.path, prepared.reviewSHA256)).contains("menuAccepted"))
        await #expect(throws: (any Error).self) { try await offline(.write(prepared.operation.path, prepared.reviewSHA256)) }
    }
}
