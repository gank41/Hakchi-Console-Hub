import Foundation

struct LegacyInspectionBackupManifest: Encodable, Sendable {
    let formatVersion = 1
    let createdAt: Date
    let sourcePaths: [String]
    let byteCount: Int
    let sha256: String
    let observedReport: LegacyConsoleReport
    let archiveFilename = "console.tar"
    let transport = "legacy-clovershell"
    let deviceIdentityVerified = false
    let eligibleForAutomaticRestore = false
    let remoteArchiveHashMatched = true
    let scope = "Original games, hakchi/custom-game files and saves. Not a full NAND image or a validated stock-kernel recovery image."
}
