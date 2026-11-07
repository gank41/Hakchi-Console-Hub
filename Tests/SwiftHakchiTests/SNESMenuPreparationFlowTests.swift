import Foundation
import Testing
@testable import SwiftHakchi

@MainActor struct SNESMenuPreparationFlowTests {
    private func record(_ phase: SNESFirmwareJournal.Phase) -> SNESReviewedInstallationRecord {
        let check = SNESReviewedConsoleCheck(operation: URL(fileURLWithPath: "/tmp/operation"), planSHA256: String(repeating: "a", count: 64),
            review: .init(directory: URL(fileURLWithPath: "/tmp/review"), sha256: String(repeating: "b", count: 64)))
        return .init(check: check, phase: phase)
    }

    @Test func onlyConfirmedInstallCanPrepareAndUsesItsOwnRecord() async throws {
        var calls = 0
        let expected = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/menu"), manifestSHA256: String(repeating: "c", count: 64))
        let operation: (SNESReviewedConsoleCheck) async throws -> SNESSetupRecordReceipt = { check in
            calls += 1
            #expect(check.operation.path == "/tmp/operation")
            return expected
        }
        for phase: SNESFirmwareJournal.Phase in [.prepared, .writeIntent, .readbackVerified, .startupVerified, .uncertain] {
            #expect(throws: (any Error).self) { try SNESMenuPreparationFlow(record: record(phase), prepare: operation) }
        }
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: operation)
        await flow.prepare()
        #expect(calls == 1 && flow.phase == .prepared && flow.candidate?.directory == expected.directory)
        await flow.prepare()
        #expect(calls == 1)
    }

    @Test func preparationFailureKeepsInstallationAndDoesNotRepeatAutomatically() async throws {
        var calls = 0
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in
            calls += 1; throw RecoveryProbeError.refused("Could not prepare the files.")
        })
        await flow.prepare(); await flow.prepare()
        #expect(calls == 1 && flow.phase == .failed && flow.candidate == nil)
        #expect(flow.error != nil)
    }

    @Test func rejectsWrongOutputAndDoesNotPrepareTwiceWhileRunning() async throws {
        var calls = 0, continuation: CheckedContinuation<Void, Never>?
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in
            calls += 1
            await withCheckedContinuation { continuation = $0 }
            return .init(kind: .backup, directory: URL(fileURLWithPath: "/tmp/not-a-menu"), manifestSHA256: String(repeating: "c", count: 64))
        })
        let first = Task { await flow.prepare() }
        for _ in 0..<1000 { if continuation != nil { break }; await Task.yield() }
        guard let continuation else { first.cancel(); Issue.record("Preparation did not start."); return }
        await flow.prepare()
        #expect(calls == 1 && flow.phase == .preparing)
        continuation.resume(); await first.value
        #expect(flow.phase == .failed && flow.candidate == nil)
    }

    @Test func consoleCheckRequiresReadinessAndNormalReturnBeforeItCanContinue() async throws {
        var checks = 0
        let candidate = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/menu"), manifestSHA256: String(repeating: "c", count: 64))
        let receipt = SNESStartupPreflightReceipt(record: .init(kind: .preflight, directory: URL(fileURLWithPath: "/tmp/check"), manifestSHA256: String(repeating: "d", count: 64)), backupMatches: true)
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in candidate }, check: { check, input in
            checks += 1; #expect(check.operation.path == "/tmp/operation" && input.directory == candidate.directory); return receipt
        })
        await flow.prepare(); await flow.runCheck(ready: false)
        #expect(checks == 0 && flow.phase == .prepared)
        await flow.runCheck(ready: true)
        #expect(checks == 1 && flow.phase == .returnToNormal)
        await flow.runCheck(ready: true)
        #expect(checks == 1)
        flow.confirmNormalMenu(visible: true)
        #expect(flow.phase == .checked && flow.preflight?.backupMatches == true)
    }

    @Test func changedBackupOrFailedCheckDoesNotAdvance() async throws {
        let candidate = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/menu"), manifestSHA256: String(repeating: "c", count: 64))
        let receipt = SNESStartupPreflightReceipt(record: .init(kind: .preflight, directory: URL(fileURLWithPath: "/tmp/check"), manifestSHA256: String(repeating: "d", count: 64)), backupMatches: false)
        let mismatch = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in candidate }, check: { _, _ in receipt })
        await mismatch.prepare(); await mismatch.runCheck(ready: true); mismatch.confirmNormalMenu(visible: true)
        #expect(mismatch.phase == .needsBackup)
        let failure = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in candidate }, check: { _, _ in throw RecoveryProbeError.refused("Connection lost") })
        await failure.prepare(); await failure.runCheck(ready: true)
        #expect(failure.phase == .returnToNormal)
        failure.confirmNormalMenu(visible: true)
        #expect(failure.phase == .checkFailed)
        let menuFailure = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in candidate }, check: { _, _ in receipt })
        await menuFailure.prepare(); await menuFailure.runCheck(ready: true); menuFailure.confirmNormalMenu(visible: false)
        #expect(menuFailure.phase == .needsAttention)
    }

    @Test func temporaryMenuRequiresReadinessGameConfirmationAndReturnToNormal() async throws {
        let candidate = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/menu"), manifestSHA256: String(repeating: "c", count: 64))
        let preflight = SNESStartupPreflightReceipt(record: .init(kind: .preflight, directory: URL(fileURLWithPath: "/tmp/check"), manifestSHA256: String(repeating: "d", count: 64)), backupMatches: true)
        let started = SNESSetupRecordReceipt(kind: .trialStarted, directory: URL(fileURLWithPath: "/tmp/started"), manifestSHA256: String(repeating: "e", count: 64))
        let played = SNESSetupRecordReceipt(kind: .trialPlayed, directory: URL(fileURLWithPath: "/tmp/played"), manifestSHA256: String(repeating: "f", count: 64))
        var starts = 0, captures = 0
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in candidate }, check: { _, _ in preflight }, trial: { _, _, _, prior in
            if let prior { captures += 1; #expect(prior.directory == started.directory); return played }
            starts += 1; return started
        })
        await flow.prepare(); await flow.runCheck(ready: true); flow.confirmNormalMenu(visible: true)
        await flow.startTrial(ready: false)
        #expect(flow.phase == .checked && starts == 0)
        await flow.startTrial(ready: true)
        await flow.startTrial(ready: true)
        #expect(flow.phase == .trialPlaying && starts == 1)
        await flow.confirmTrialGame(works: true)
        #expect(flow.phase == .trialReturnToNormal && captures == 1 && flow.played?.directory == played.directory)
        flow.confirmTrialNormalMenu(visible: true)
        #expect(flow.phase == .trialComplete)
    }

    @Test func failedTrialCannotPrepareAnUpdateOrSkipTheNormalReturn() async throws {
        let candidate = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/menu"), manifestSHA256: String(repeating: "c", count: 64))
        let preflight = SNESStartupPreflightReceipt(record: .init(kind: .preflight, directory: URL(fileURLWithPath: "/tmp/check"), manifestSHA256: String(repeating: "d", count: 64)), backupMatches: true)
        let started = SNESSetupRecordReceipt(kind: .trialStarted, directory: URL(fileURLWithPath: "/tmp/started"), manifestSHA256: String(repeating: "e", count: 64))
        var captures = 0
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in candidate }, check: { _, _ in preflight }, trial: { _, _, _, prior in
            if prior != nil { captures += 1 }; return started
        })
        await flow.prepare(); await flow.runCheck(ready: true); flow.confirmNormalMenu(visible: true)
        await flow.startTrial(ready: true); await flow.confirmTrialGame(works: false)
        #expect(flow.phase == .trialReturnToNormal && captures == 0)
        flow.confirmTrialNormalMenu(visible: true)
        #expect(flow.phase == .trialFailed && flow.played == nil)
    }

    @Test func menuInstallationRequiresPreflightAndSeparateApproval() async throws {
        let candidate = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/menu"), manifestSHA256: String(repeating: "c", count: 64))
        let preflight = SNESStartupPreflightReceipt(record: .init(kind: .preflight, directory: URL(fileURLWithPath: "/tmp/check"), manifestSHA256: String(repeating: "d", count: 64)), backupMatches: true)
        let started = SNESSetupRecordReceipt(kind: .trialStarted, directory: URL(fileURLWithPath: "/tmp/started"), manifestSHA256: String(repeating: "e", count: 64))
        let played = SNESSetupRecordReceipt(kind: .trialPlayed, directory: URL(fileURLWithPath: "/tmp/played"), manifestSHA256: String(repeating: "f", count: 64))
        let upgrade = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/upgrade"), reviewSHA256: String(repeating: "a", count: 64))
        var preparations = 0, checks = 0, writes = 0, gameChecks = 0, accepts = 0
        let ops = SNESMenuUpgradeOperations(prepare: { _, c, p, s, t in
            preparations += 1; #expect(c.directory == candidate.directory && p.backupMatches && s.kind == .trialStarted && t.kind == .trialPlayed); return upgrade
        }, preflight: { _, _ in checks += 1 }, install: { _, _ in writes += 1 },
            checkMenu: { _, _ in gameChecks += 1 }, accept: { _, _ in accepts += 1 })
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in candidate }, check: { _, _ in preflight },
            trial: { _, _, _, prior in prior == nil ? started : played }, upgrade: ops)
        await flow.prepare(); await flow.runCheck(ready: true); flow.confirmNormalMenu(visible: true)
        await flow.startTrial(ready: true); await flow.confirmTrialGame(works: true); flow.confirmTrialNormalMenu(visible: true)
        await flow.prepareUpgrade(); await flow.prepareUpgrade()
        #expect(preparations == 1 && flow.phase == .upgradePrepared)
        await flow.runUpgradePreflight(ready: false); #expect(checks == 0)
        await flow.runUpgradePreflight(ready: true); #expect(checks == 1 && flow.phase == .upgradePreflightReturn)
        await flow.installUpgrade(ready: true, approved: true); #expect(writes == 0)
        flow.confirmUpgradePreflightNormalMenu(visible: true)
        await flow.installUpgrade(ready: true, approved: false); await flow.installUpgrade(ready: false, approved: true)
        #expect(writes == 0 && flow.phase == .upgradeReady)
        await flow.installUpgrade(ready: true, approved: true); await flow.installUpgrade(ready: true, approved: true)
        #expect(writes == 1 && flow.phase == .upgradeRestart)
        await flow.checkInstalledMenu(visible: true); await flow.confirmInstalledGame(works: true)
        #expect(gameChecks == 1 && accepts == 1 && flow.phase == .upgradeComplete)
    }

    @Test func uncertainMenuInstallationIsNeverRetried() async throws {
        let candidate = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/menu"), manifestSHA256: String(repeating: "c", count: 64))
        let preflight = SNESStartupPreflightReceipt(record: .init(kind: .preflight, directory: URL(fileURLWithPath: "/tmp/check"), manifestSHA256: String(repeating: "d", count: 64)), backupMatches: true)
        let started = SNESSetupRecordReceipt(kind: .trialStarted, directory: URL(fileURLWithPath: "/tmp/started"), manifestSHA256: String(repeating: "e", count: 64))
        let played = SNESSetupRecordReceipt(kind: .trialPlayed, directory: URL(fileURLWithPath: "/tmp/played"), manifestSHA256: String(repeating: "f", count: 64))
        let upgrade = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/upgrade"), reviewSHA256: String(repeating: "a", count: 64))
        var writes = 0
        let ops = SNESMenuUpgradeOperations(prepare: { _, _, _, _, _ in upgrade }, preflight: { _, _ in },
            install: { _, _ in writes += 1; throw SNESFirmwareTransactionError.uncertain }, checkMenu: { _, _ in }, accept: { _, _ in })
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in candidate }, check: { _, _ in preflight },
            trial: { _, _, _, prior in prior == nil ? started : played }, upgrade: ops)
        await flow.prepare(); await flow.runCheck(ready: true); flow.confirmNormalMenu(visible: true)
        await flow.startTrial(ready: true); await flow.confirmTrialGame(works: true); flow.confirmTrialNormalMenu(visible: true)
        await flow.prepareUpgrade(); await flow.runUpgradePreflight(ready: true); flow.confirmUpgradePreflightNormalMenu(visible: true)
        await flow.installUpgrade(ready: true, approved: true); await flow.installUpgrade(ready: true, approved: true)
        #expect(writes == 1 && flow.phase == .upgradeUncertain)
    }

    @Test func changedDataRequiresFreshBackupAndNormalReturnBeforeRechecking() async throws {
        let old = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/old"), manifestSHA256: String(repeating: "c", count: 64))
        let new = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/new"), manifestSHA256: String(repeating: "e", count: 64))
        let preflight = SNESStartupPreflightReceipt(record: .init(kind: .preflight, directory: URL(fileURLWithPath: "/tmp/check"), manifestSHA256: String(repeating: "d", count: 64)), backupMatches: false)
        let backup = SNESDataSnapshotReceipt(directory: URL(fileURLWithPath: "/tmp/fresh"), manifestSHA256: String(repeating: "a", count: 64))
        var backups = 0, rebuilt = 0
        let ops = SNESMenuFreshBackupOperations(backup: { _ in backups += 1; return backup }, rebuild: { _, receipt in
            rebuilt += 1; #expect(receipt.directory == backup.directory); return new
        })
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in old }, check: { _, _ in preflight }, freshBackup: ops)
        await flow.prepare(); await flow.runCheck(ready: true); flow.confirmNormalMenu(visible: true)
        flow.reviewFreshBackup(); await flow.startFreshBackup(ready: false)
        #expect(backups == 0 && flow.phase == .backupInstructions)
        await flow.startFreshBackup(ready: true); await flow.rebuildWithFreshBackup()
        #expect(backups == 1 && rebuilt == 0 && flow.phase == .backupReturnToNormal)
        flow.confirmBackupNormalMenu(visible: true); await flow.rebuildWithFreshBackup()
        #expect(rebuilt == 1 && flow.phase == .prepared && flow.candidate?.directory == new.directory && flow.preflight == nil)
    }

    @Test func stoppedMenuWriteRequiresNormalReturnBeforeNewBackup() async throws {
        let candidate = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/menu"), manifestSHA256: String(repeating: "c", count: 64))
        let preflight = SNESStartupPreflightReceipt(record: .init(kind: .preflight, directory: URL(fileURLWithPath: "/tmp/check"), manifestSHA256: String(repeating: "d", count: 64)), backupMatches: true)
        let started = SNESSetupRecordReceipt(kind: .trialStarted, directory: URL(fileURLWithPath: "/tmp/started"), manifestSHA256: String(repeating: "e", count: 64))
        let played = SNESSetupRecordReceipt(kind: .trialPlayed, directory: URL(fileURLWithPath: "/tmp/played"), manifestSHA256: String(repeating: "f", count: 64))
        let upgrade = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/upgrade"), reviewSHA256: String(repeating: "a", count: 64))
        let backup = SNESDataSnapshotReceipt(directory: URL(fileURLWithPath: "/tmp/fresh"), manifestSHA256: String(repeating: "b", count: 64))
        let ops = SNESMenuUpgradeOperations(prepare: { _, _, _, _, _ in upgrade }, preflight: { _, _ in },
            install: { _, _ in throw RecoveryProbeError.refused("Stopped before writing") }, checkMenu: { _, _ in }, accept: { _, _ in })
        let fresh = SNESMenuFreshBackupOperations(backup: { _ in backup }, rebuild: { _, _ in candidate })
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in candidate }, check: { _, _ in preflight },
            trial: { _, _, _, prior in prior == nil ? started : played }, upgrade: ops, freshBackup: fresh)
        await flow.prepare(); await flow.runCheck(ready: true); flow.confirmNormalMenu(visible: true)
        await flow.startTrial(ready: true); await flow.confirmTrialGame(works: true); flow.confirmTrialNormalMenu(visible: true)
        await flow.prepareUpgrade(); await flow.runUpgradePreflight(ready: true); flow.confirmUpgradePreflightNormalMenu(visible: true)
        await flow.installUpgrade(ready: true, approved: true); flow.reviewFreshBackup()
        #expect(flow.phase == .upgradeWriteReturnToNormal)
        flow.confirmStoppedWriteNormalMenu(visible: true); flow.reviewFreshBackup()
        #expect(flow.phase == .backupInstructions)
    }

    @Test func failedFreshBackupCannotPrepareAnUpdate() async throws {
        let candidate = SNESSetupRecordReceipt(kind: .candidate, directory: URL(fileURLWithPath: "/tmp/menu"), manifestSHA256: String(repeating: "c", count: 64))
        let preflight = SNESStartupPreflightReceipt(record: .init(kind: .preflight, directory: URL(fileURLWithPath: "/tmp/check"), manifestSHA256: String(repeating: "d", count: 64)), backupMatches: false)
        var rebuilds = 0
        let ops = SNESMenuFreshBackupOperations(backup: { _ in throw RecoveryProbeError.refused("Backup stopped") }, rebuild: { _, _ in rebuilds += 1; return candidate })
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in candidate }, check: { _, _ in preflight }, freshBackup: ops)
        await flow.prepare(); await flow.runCheck(ready: true); flow.confirmNormalMenu(visible: true)
        flow.reviewFreshBackup(); await flow.startFreshBackup(ready: true)
        #expect(flow.phase == .backupReturnToNormal && flow.freshBackup == nil)
        flow.confirmBackupNormalMenu(visible: true); await flow.rebuildWithFreshBackup()
        #expect(flow.phase == .backupFailed && rebuilds == 0)
    }

    @Test func gameFolderStageMustBeBoundToTheConfirmedMenuUpdate() throws {
        let menu = try SNESMenuSetupStageContext(stage: .menu, parent: nil)
        #expect(menu.stage == .menu && menu.parent == nil)
        #expect(throws: (any Error).self) { try SNESMenuSetupStageContext(stage: .gameFolders, parent: nil) }
        let update = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/upgrade"), reviewSHA256: String(repeating: "a", count: 64))
        #expect(throws: (any Error).self) { try SNESMenuSetupStageContext(stage: .menu, parent: update) }
        let folders = try #require(menu.next(after: update))
        #expect(folders.stage == .gameFolders && folders.parent?.operation == update.operation)
        #expect(folders.next(after: update).map { _ in true } == nil)
    }

    @Test func savedUpgradeCanResumeOnlyAfterItsGameCheckWasAccepted() throws {
        let menu = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/menu-update"), reviewSHA256: String(repeating: "a", count: 64))
        let folder = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/folder-update"), reviewSHA256: String(repeating: "b", count: 64))
        for phase: SNESFirmwareJournal.Phase in [.writeIntent, .uncertain] {
            #expect(throws: (any Error).self) { try SNESMenuSetupResumeTarget.resolve(.init(upgrade: menu, parentMenu: nil, phase: phase)) }
        }
        for phase: SNESFirmwareJournal.Phase in [.prepared, .preflightVerified, .readbackVerified, .startupVerified] {
            let pending = try SNESMenuSetupResumeTarget.resolve(.init(upgrade: folder, parentMenu: menu, phase: phase))
            guard case .verifyUpgrade(let stage, let selected) = pending else { Issue.record("Expected startup recheck"); return }
            #expect(stage.parent?.operation == menu.operation && selected.upgrade.operation == folder.operation)
        }
        let next = try SNESMenuSetupResumeTarget.resolve(.init(upgrade: menu, parentMenu: nil, phase: .menuAccepted))
        guard case .gameFolders(let stage) = next else { Issue.record("Expected game-folder setup"); return }
        #expect(stage.parent?.operation == menu.operation)
        let finish = try SNESMenuSetupResumeTarget.resolve(.init(upgrade: folder, parentMenu: menu, phase: .menuAccepted))
        guard case .includedGames(let stage, let selected) = finish else { Issue.record("Expected included-game check"); return }
        #expect(stage.parent?.operation == menu.operation && selected.operation == folder.operation)
    }

    @Test func resumingWrittenUpgradeRechecksStartupWithoutWritingAgain() async throws {
        let upgrade = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/upgrade"), reviewSHA256: String(repeating: "a", count: 64))
        let reopened = SNESReviewedUpgradeRecord(upgrade: upgrade, parentMenu: nil, phase: .startupVerified)
        var writes = 0, checks = 0, accepts = 0
        let ops = SNESMenuUpgradeOperations(prepare: { _, _, _, _, _ in upgrade }, preflight: { _, _ in },
            install: { _, _ in writes += 1 }, checkMenu: { _, _ in checks += 1 }, accept: { _, _ in accepts += 1 })
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in throw RecoveryProbeError.refused("not used") },
            upgrade: ops, resuming: reopened)
        #expect(flow.phase == .upgradeRestart)
        await flow.installUpgrade(ready: true, approved: true)
        await flow.checkInstalledMenu(visible: true); await flow.confirmInstalledGame(works: true)
        #expect(writes == 0 && checks == 1 && accepts == 1 && flow.phase == .upgradeComplete)
        let uncertain = SNESReviewedUpgradeRecord(upgrade: upgrade, parentMenu: nil, phase: .uncertain)
        #expect(throws: (any Error).self) { try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in throw RecoveryProbeError.refused("not used") }, upgrade: ops, resuming: uncertain) }
    }

    @Test func previouslyCheckedUnwrittenUpgradeStillRequiresFreshApproval() async throws {
        let upgrade = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/upgrade"), reviewSHA256: String(repeating: "a", count: 64))
        let reopened = SNESReviewedUpgradeRecord(upgrade: upgrade, parentMenu: nil, phase: .preflightVerified)
        var writes = 0
        let ops = SNESMenuUpgradeOperations(prepare: { _, _, _, _, _ in upgrade }, preflight: { _, _ in },
            install: { _, _ in writes += 1 }, checkMenu: { _, _ in }, accept: { _, _ in })
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in throw RecoveryProbeError.refused("not used") }, upgrade: ops, resuming: reopened)
        #expect(flow.phase == .upgradePreflightReturn)
        await flow.installUpgrade(ready: true, approved: true)
        #expect(writes == 0)
        flow.confirmUpgradePreflightNormalMenu(visible: true)
        #expect(flow.phase == .upgradeReady)
        await flow.installUpgrade(ready: true, approved: false)
        #expect(writes == 0 && flow.phase == .upgradeReady)
        await flow.installUpgrade(ready: true, approved: true)
        #expect(writes == 1 && flow.phase == .upgradeRestart)

        let stopped = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in throw RecoveryProbeError.refused("not used") }, upgrade: ops, resuming: reopened)
        stopped.confirmUpgradePreflightNormalMenu(visible: false)
        await stopped.installUpgrade(ready: true, approved: true)
        #expect(stopped.phase == .needsAttention && writes == 1)
    }

    @Test func preparedUpgradeMustRunItsNoWriteCheckBeforeApproval() async throws {
        let upgrade = SNESFirmwareJournal.Prepared(operation: URL(fileURLWithPath: "/tmp/upgrade"), reviewSHA256: String(repeating: "a", count: 64))
        let reopened = SNESReviewedUpgradeRecord(upgrade: upgrade, parentMenu: nil, phase: .prepared)
        var checks = 0, writes = 0
        let ops = SNESMenuUpgradeOperations(prepare: { _, _, _, _, _ in upgrade }, preflight: { _, _ in checks += 1 },
            install: { _, _ in writes += 1 }, checkMenu: { _, _ in }, accept: { _, _ in })
        let flow = try SNESMenuPreparationFlow(record: record(.menuAccepted), prepare: { _ in throw RecoveryProbeError.refused("not used") }, upgrade: ops, resuming: reopened)
        #expect(flow.phase == .upgradePrepared)
        await flow.installUpgrade(ready: true, approved: true)
        #expect(writes == 0)
        await flow.runUpgradePreflight(ready: true)
        #expect(checks == 1 && flow.phase == .upgradePreflightReturn)
        flow.confirmUpgradePreflightNormalMenu(visible: true)
        #expect(flow.phase == .upgradeReady && writes == 0)
    }
}
