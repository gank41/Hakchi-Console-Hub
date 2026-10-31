import Foundation
import Testing
@testable import SwiftHakchi

struct StockRestoreDiagnosticTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func alternateJournalRootCannotStartStockPreflight() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try StockRestoreJournal.prepare(material: await knownRestoreMaterial(), root: root)
        await #expect(throws: (any Error).self) {
            try await StockRestoreDiagnostic.run(mode: .preflight(prepared.operation.path, prepared.reviewSHA256),
                loadInputs: { Issue.record("alternate stock root reached recovery payload"); throw RecoveryProbeError.refused("unexpected") },
                makeIO: { Issue.record("alternate stock root opened USB"); return NativeStockRestoreIO() })
        }
    }
    @Test func explicitModesRejectAmbiguousArguments() throws {
        #expect(try StockRestoreDiagnosticOptions.parseIfPresent([]) == nil)
        #expect(try StockRestoreDiagnosticOptions.parseIfPresent(["--inspect"]) == nil)
        let sha=String(repeating:"a",count:64)
        #expect(try StockRestoreDiagnosticOptions.parseIfPresent(["--prepare-stock-restore","/snapshot","/stock","/journals"]) == .prepare("/snapshot","/stock","/journals"))
        #expect(try StockRestoreDiagnosticOptions.parseIfPresent(["--write-stock-boot2","/operation",sha]) == .write("/operation",sha))
        for args in [["--write-stock-boot2"],["--preflight-stock-restore","relative",sha],["--inspect-stock-restore","/operation","bad"],["--confirm-stock-menu","/operation",sha,"extra"],["--prepare-stock-restore","/snapshot","/stock"]] {
            #expect(throws:(any Error).self){try StockRestoreDiagnosticOptions.parseIfPresent(args)}
        }
    }
    @Test func invalidJournalStopsBeforePayloadOrNativeFactory() async throws {
        for mode: StockRestoreDiagnosticOptions in [.prepare("/missing","/missing","/missing"),.inspect("/missing",String(repeating:"a",count:64)),.preflight("/missing",String(repeating:"a",count:64)),.write("/missing",String(repeating:"a",count:64)),.confirm("/missing",String(repeating:"a",count:64))] {
            await #expect(throws:(any Error).self) {
                try await StockRestoreDiagnostic.run(mode:mode,loadInputs:{Issue.record("invalid journal loaded payload");throw RecoveryProbeError.refused("unexpected")},makeIO:{Issue.record("invalid journal opened native IO");return NativeStockRestoreIO()})
            }
        }
        #expect(!StockRestoreDiagnostic.failureMessage(writeRequested:true,error:RecoveryProbeError.refused("test")).contains("No flash"))
        #expect(StockRestoreDiagnostic.failureMessage(writeRequested:true,error:RecoveryProbeError.refused("test")).contains("do not retry"))
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_RECOVERY_TEST_BACKUPS"] != nil))
    func offlineInspectionAndMenuConfirmationNeverLoadPayloadOrOpenUSB() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try StockRestoreJournal.prepare(material:await knownRestoreMaterial(),root:root)
        func offline(_ mode:StockRestoreDiagnosticOptions) async throws -> String {
            try await StockRestoreDiagnostic.run(mode:mode,loadInputs:{Issue.record("offline loaded payload");throw RecoveryProbeError.refused("unexpected")},makeIO:{Issue.record("offline opened USB");return NativeStockRestoreIO()})
        }
        #expect(try await offline(.inspect(p.operation.path,p.reviewSHA256)).contains("prepared"))
        await #expect(throws:(any Error).self){try await offline(.confirm(p.operation.path,p.reviewSHA256))}
        do {
            let j=try StockRestoreJournal(operation:p.operation,reviewSHA256:p.reviewSHA256)
            try await j.append(.preflightVerified);try await j.append(.burnIntent);try await j.append(.readbackVerified)
            try await j.close()
        }
        #expect(try await offline(.confirm(p.operation.path,p.reviewSHA256)).contains("menuAccepted"))
        // A second writer must be rejected before obtaining payloads/native IO.
        await #expect(throws:(any Error).self){try await offline(.write(p.operation.path,p.reviewSHA256))}
    }
}
