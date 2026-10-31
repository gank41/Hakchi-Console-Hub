import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESLibrarySavedSnapshotCompatibilityTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_EXISTING_LIBRARY_BACKUP"] != nil))
    func existingPrivateSnapshotStillReopensAfterNewRecoveryFieldsWereAdded() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_EXISTING_LIBRARY_BACKUP"])
        let backup = try SNESLibraryBackup.open(directory: URL(fileURLWithPath: path))
        try backup.validate(); #expect(!backup.inventory.files.isEmpty)
        for record in backup.inventory.files {
            let bytes = try backup.read(path: record.path)
            #expect(bytes.count == record.byteCount && BackupManifest.digest(bytes) == record.sha256)
        }
    }
}
