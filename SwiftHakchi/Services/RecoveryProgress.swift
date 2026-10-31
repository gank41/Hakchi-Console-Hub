import Foundation

typealias RecoveryProgressSink = @Sendable (RecoveryStage) async -> Void

enum RecoveryStage: String, Sendable, CaseIterable {
    case checkingMaterial, checkingUSB, uploadingRecovery, waitingForRecovery, checkingIdentity
    case checkingPartitions, readingCurrentKernel, readingBootloader, stagingStock, writingStock, stagingLegacy, writingLegacy, readingBack, verifying, closing
    case stagingStartup, writingStartup, restoringStartup
    var title: String {
        switch self {
        case .checkingMaterial: return "Checking local recovery files"
        case .checkingUSB: return "Checking the connected console"
        case .uploadingRecovery: return "Uploading temporary recovery software"
        case .waitingForRecovery: return "Waiting for the recovery connection"
        case .checkingIdentity: return "Verifying the console identity"
        case .checkingPartitions: return "Checking console storage layout"
        case .readingCurrentKernel: return "Reading the installed kernel"
        case .readingBootloader: return "Reading boot1 bootloader evidence"
        case .stagingStock: return "Copying and checking the stock image in temporary memory"
        case .writingStock: return "Writing the stock kernel — keep power and USB connected"
        case .stagingLegacy: return "Copying and checking the preserved legacy image in temporary memory"
        case .writingLegacy: return "Writing the preserved legacy kernel — keep power and USB connected"
        case .stagingStartup: return "Preparing and checking the console update in temporary memory"
        case .writingStartup: return "Updating console startup — keep power and USB connected"
        case .restoringStartup: return "Restoring original console startup — keep power and USB connected"
        case .readingBack: return "Reading back the written kernel"
        case .verifying: return "Finishing verification"
        case .closing: return "Closing the recovery connection"
        }
    }
}
