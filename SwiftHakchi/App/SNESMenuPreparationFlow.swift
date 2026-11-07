import Foundation
import Combine

struct SNESMenuSetupStageContext {
    enum Stage { case menu, gameFolders }
    let stage: Stage
    let parent: SNESFirmwareJournal.Prepared?

    init(stage: Stage, parent: SNESFirmwareJournal.Prepared?) throws {
        guard (stage == .menu && parent == nil) || (stage == .gameFolders && parent != nil) else {
            throw SNESRuntimeBinding.failure()
        }
        self.stage = stage; self.parent = parent
    }

    func next(after update: SNESFirmwareJournal.Prepared) -> Self? {
        guard stage == .menu else { return nil }
        return try? .init(stage: .gameFolders, parent: update)
    }
}

/// A reopened record resumes at the next verified step, without repeating a write.
enum SNESMenuSetupResumeTarget {
    case gameFolders(SNESMenuSetupStageContext)
    case includedGames(SNESMenuSetupStageContext, SNESFirmwareJournal.Prepared)
    case verifyUpgrade(SNESMenuSetupStageContext, SNESReviewedUpgradeRecord)

    static func resolve(_ record: SNESReviewedUpgradeRecord) throws -> Self {
        if record.phase == .prepared || record.phase == .preflightVerified || record.phase == .readbackVerified || record.phase == .startupVerified {
            let stage = try SNESMenuSetupStageContext(stage: record.parentMenu == nil ? .menu : .gameFolders, parent: record.parentMenu)
            return .verifyUpgrade(stage, record)
        }
        guard record.phase == .menuAccepted else { throw SNESRuntimeBinding.failure() }
        if let parent = record.parentMenu {
            guard parent.operation.standardizedFileURL != record.upgrade.operation.standardizedFileURL else { throw SNESRuntimeBinding.failure() }
            return .includedGames(try .init(stage: .gameFolders, parent: parent), record.upgrade)
        }
        return .gameFolders(try .init(stage: .gameFolders, parent: record.upgrade))
    }
}

struct SNESMenuUpgradeOperations {
    let prepare: (SNESReviewedConsoleCheck, SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt, SNESSetupRecordReceipt) async throws -> SNESFirmwareJournal.Prepared
    let preflight: (SNESReviewedConsoleCheck, SNESFirmwareJournal.Prepared) async throws -> Void
    let install: (SNESReviewedConsoleCheck, SNESFirmwareJournal.Prepared) async throws -> Void
    let checkMenu: (SNESReviewedConsoleCheck, SNESFirmwareJournal.Prepared) async throws -> Void
    let accept: (SNESReviewedConsoleCheck, SNESFirmwareJournal.Prepared) async throws -> Void
}

struct SNESMenuFreshBackupOperations {
    let backup: (SNESReviewedConsoleCheck) async throws -> SNESDataSnapshotReceipt
    let rebuild: (SNESReviewedConsoleCheck, SNESDataSnapshotReceipt) async throws -> SNESSetupRecordReceipt
}

/// Guides the menu update after a confirmed first startup update.
@MainActor final class SNESMenuPreparationFlow: ObservableObject {
    enum Phase { case ready, preparing, prepared, checking, returnToNormal, checked, needsBackup, checkFailed, needsAttention, failed,
        trialStarting, trialPlaying, trialChecking, trialReturnToNormal, trialComplete, trialFailed,
        upgradePreparing, upgradePrepared, upgradePreflighting, upgradePreflightReturn, upgradeReady, upgrading, upgradeRestart,
        upgradeVerifying, upgradeGameTest, upgradeAccepting, upgradeComplete, upgradeStopped, upgradeUncertain, upgradeWriteReturnToNormal,
        backupInstructions, backingUp, backupReturnToNormal, backupReady, backupPreparing, backupFailed }
    @Published private(set) var phase: Phase = .ready
    @Published private(set) var candidate: SNESSetupRecordReceipt?
    @Published private(set) var preflight: SNESStartupPreflightReceipt?
    @Published private(set) var started: SNESSetupRecordReceipt?
    @Published private(set) var played: SNESSetupRecordReceipt?
    @Published private(set) var upgrade: SNESFirmwareJournal.Prepared?
    @Published private(set) var freshBackup: SNESDataSnapshotReceipt?
    @Published private(set) var error: String?
    private let check: SNESReviewedConsoleCheck
    private let operation: (SNESReviewedConsoleCheck) async throws -> SNESSetupRecordReceipt
    private let checkOperation: ((SNESReviewedConsoleCheck, SNESSetupRecordReceipt) async throws -> SNESStartupPreflightReceipt)?
    private let trialOperation: ((SNESReviewedConsoleCheck, SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt?) async throws -> SNESSetupRecordReceipt)?
    private let upgradeOperations: SNESMenuUpgradeOperations?
    private let freshBackupOperations: SNESMenuFreshBackupOperations?

    init(record: SNESReviewedInstallationRecord,
         prepare: @escaping (SNESReviewedConsoleCheck) async throws -> SNESSetupRecordReceipt,
         check: ((SNESReviewedConsoleCheck, SNESSetupRecordReceipt) async throws -> SNESStartupPreflightReceipt)? = nil,
         trial: ((SNESReviewedConsoleCheck, SNESSetupRecordReceipt, SNESStartupPreflightReceipt, SNESSetupRecordReceipt?) async throws -> SNESSetupRecordReceipt)? = nil,
         upgrade: SNESMenuUpgradeOperations? = nil, freshBackup: SNESMenuFreshBackupOperations? = nil,
         resuming: SNESReviewedUpgradeRecord? = nil) throws {
        guard record.phase == .menuAccepted else {
            throw RecoveryProbeError.refused("Finish checking the first startup update before preparing the menu.")
        }
        self.check = record.check; operation = prepare; checkOperation = check; trialOperation = trial; upgradeOperations = upgrade; freshBackupOperations = freshBackup
        if let resuming {
            self.upgrade = resuming.upgrade
            switch resuming.phase {
            case .prepared: phase = .upgradePrepared
            // The durable check does not record whether the normal menu was
            // seen afterward, so ask again before offering installation.
            case .preflightVerified: phase = .upgradePreflightReturn
            default:
                _ = try SNESInstalledStartupCheck.recordStartupTransition(for: resuming.phase)
                phase = .upgradeRestart
            }
        }
    }

    func prepare() async {
        guard phase == .ready else { return }
        phase = .preparing
        do {
            let receipt = try await operation(check)
            guard receipt.kind == .candidate else { throw SNESRuntimeBinding.failure() }
            candidate = receipt; phase = .prepared
        } catch { self.error = error.localizedDescription; phase = .failed }
    }

    func runCheck(ready: Bool) async {
        guard phase == .prepared, ready, let candidate, let checkOperation else { return }
        phase = .checking; error = nil
        do {
            let result = try await checkOperation(check, candidate)
            guard result.record.kind == .preflight else { throw SNESRuntimeBinding.failure() }
            preflight = result
        } catch { self.error = error.localizedDescription }
        // Even a failed check may have started the console in temporary mode.
        phase = .returnToNormal
    }

    func confirmNormalMenu(visible: Bool) {
        guard phase == .returnToNormal else { return }
        guard visible else { phase = .needsAttention; return }
        guard let preflight else { phase = .checkFailed; return }
        phase = preflight.backupMatches ? .checked : .needsBackup
    }

    func startTrial(ready: Bool) async {
        guard phase == .checked, ready, let candidate, let preflight, preflight.backupMatches, let trialOperation else { return }
        phase = .trialStarting; error = nil
        do {
            let receipt = try await trialOperation(check, candidate, preflight, nil)
            guard receipt.kind == .trialStarted else { throw SNESRuntimeBinding.failure() }
            started = receipt; phase = .trialPlaying
        } catch { self.error = error.localizedDescription; phase = .trialReturnToNormal }
    }

    func confirmTrialGame(works: Bool) async {
        guard phase == .trialPlaying else { return }
        guard works else {
            error = "The temporary menu or game did not work. No update was installed."
            phase = .trialReturnToNormal; return
        }
        guard let candidate, let preflight, let started, let trialOperation else {
            error = "The temporary test record is missing. No update was installed."
            phase = .trialReturnToNormal; return
        }
        phase = .trialChecking
        do {
            let receipt = try await trialOperation(check, candidate, preflight, started)
            guard receipt.kind == .trialPlayed else { throw SNESRuntimeBinding.failure() }
            played = receipt
        } catch { self.error = error.localizedDescription }
        phase = .trialReturnToNormal
    }

    func confirmTrialNormalMenu(visible: Bool) {
        guard phase == .trialReturnToNormal else { return }
        guard visible else { phase = .needsAttention; return }
        phase = error == nil && played != nil ? .trialComplete : .trialFailed
    }

    func prepareUpgrade() async {
        guard phase == .trialComplete, let candidate, let preflight, preflight.backupMatches,
              let started, let played, let upgradeOperations else { return }
        phase = .upgradePreparing; error = nil
        do { upgrade = try await upgradeOperations.prepare(check, candidate, preflight, started, played); phase = .upgradePrepared }
        catch { self.error = error.localizedDescription; phase = .upgradeStopped }
    }

    func runUpgradePreflight(ready: Bool) async {
        guard phase == .upgradePrepared, ready, let upgrade, let upgradeOperations else { return }
        phase = .upgradePreflighting; error = nil
        do { try await upgradeOperations.preflight(check, upgrade) }
        catch { self.error = error.localizedDescription }
        phase = .upgradePreflightReturn
    }

    func confirmUpgradePreflightNormalMenu(visible: Bool) {
        guard phase == .upgradePreflightReturn else { return }
        guard visible else { phase = .needsAttention; return }
        phase = error == nil ? .upgradeReady : .upgradeStopped
    }

    func installUpgrade(ready: Bool, approved: Bool) async {
        guard phase == .upgradeReady, ready, approved, let upgrade, let upgradeOperations else { return }
        phase = .upgrading; error = nil
        do { try await upgradeOperations.install(check, upgrade); phase = .upgradeRestart }
        catch { self.error = error.localizedDescription; phase = error is SNESFirmwareTransactionError ? .upgradeUncertain : .upgradeWriteReturnToNormal }
    }

    func confirmStoppedWriteNormalMenu(visible: Bool) {
        guard phase == .upgradeWriteReturnToNormal else { return }
        phase = visible ? .upgradeStopped : .needsAttention
    }

    func checkInstalledMenu(visible: Bool) async {
        guard phase == .upgradeRestart, visible, let upgrade, let upgradeOperations else { return }
        phase = .upgradeVerifying; error = nil
        do { try await upgradeOperations.checkMenu(check, upgrade); phase = .upgradeGameTest }
        catch { self.error = error.localizedDescription; phase = .needsAttention }
    }

    func reportInstalledMenuProblem() {
        guard phase == .upgradeRestart else { return }
        phase = .needsAttention
    }

    func confirmInstalledGame(works: Bool) async {
        guard phase == .upgradeGameTest, let upgrade, let upgradeOperations else { return }
        guard works else { phase = .needsAttention; return }
        phase = .upgradeAccepting; error = nil
        do { try await upgradeOperations.accept(check, upgrade); phase = .upgradeComplete }
        catch { self.error = error.localizedDescription; phase = .needsAttention }
    }

    func reviewFreshBackup() {
        guard (phase == .needsBackup || phase == .upgradeStopped), freshBackupOperations != nil else { return }
        error = nil; phase = .backupInstructions
    }

    func startFreshBackup(ready: Bool) async {
        guard phase == .backupInstructions, ready, let freshBackupOperations else { return }
        phase = .backingUp; error = nil
        do { freshBackup = try await freshBackupOperations.backup(check) }
        catch { self.error = error.localizedDescription }
        phase = .backupReturnToNormal
    }

    func confirmBackupNormalMenu(visible: Bool) {
        guard phase == .backupReturnToNormal else { return }
        guard visible else { phase = .needsAttention; return }
        phase = error == nil && freshBackup != nil ? .backupReady : .backupFailed
    }

    func rebuildWithFreshBackup() async {
        guard phase == .backupReady, let freshBackup, let freshBackupOperations else { return }
        phase = .backupPreparing; error = nil
        do {
            let receipt = try await freshBackupOperations.rebuild(check, freshBackup)
            guard receipt.kind == .candidate else { throw SNESRuntimeBinding.failure() }
            candidate = receipt; preflight = nil; started = nil; played = nil; upgrade = nil; phase = .prepared
        } catch { self.error = error.localizedDescription; phase = .backupFailed }
    }
}
