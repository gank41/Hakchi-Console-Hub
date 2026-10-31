import Foundation
import SwiftHakchiCore

/// Bounded private evidence from a rejected header, never an install-ready report.
struct SNESSetupDiagnosticFailure: Error, LocalizedError, Sendable {
    let kernel: SNESKernelBackupReport
    let boot1: Data
    let partitions: Data
    let headerFrame: Data
    let reason: String
    var errorDescription: String? { "The SNES storage check did not accept this format. No console changes were made." }
    func filesForExport() throws -> [String: Data] {
        try SNESBackupPolicy.requireReadOnlyObservation(kernel.observation)
        _ = try RecoveryBootSnapshot(active: .image(kernel.active), backup: kernel.backup.map(RecoveryBoot2Read.image) ?? .unavailable)
        _ = try RecoveryBoot1Snapshot(boot1)
        guard partitions.count <= 16384, let text = String(data: partitions, encoding: .ascii),
              headerFrame.count <= 2208 else {
            throw RecoveryProbeError.refused("The private SNES diagnostic exceeded its capture limits.")
        }
        try StockRestorePartitions.validate(text)
        var files = ["active-boot2.img": kernel.active, "boot1.bin": boot1,
                     "partitions.txt": partitions, "data-header-frame.bin": headerFrame]
        if let backup = kernel.backup { files["backup-boot2.img"] = backup }
        return files
    }
}

struct SNESSetupDiagnosticSavedError: Error, LocalizedError, Sendable {
    let directory: URL
    var errorDescription: String? {
        "The SNES storage check did not accept this format. A private diagnostic was saved on your Mac for investigation. No console changes were made."
    }
}
