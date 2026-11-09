import Foundation
import Darwin
import CryptoKit
import os
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESFirmwareMaterialTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    @MainActor func reviewedInstallUsesFreshBackupAndOneOwnedSession() async throws {
        let base = try await SNESFirmwareFixtureCache.shared.value()
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.copyItem(at: base.trial.candidate.backup.directory, to: data)
        let fresh = SNESDataSnapshotReceipt(directory: data, manifestSHA256: BackupManifest.digest(try Data(contentsOf: data.appendingPathComponent("manifest.json"))))
        let store = try RecoveryBootSnapshotStore(root: root)
        let helperDirectory = try await store.saveSNESPortableHelpers()
        let helpers = try SNESPortableHelperPackage.load(directory: helperDirectory)
        let pins = try PinnedFELInputs.load(), recovery = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let candidate = base.trial.candidate
        let preflight = try await SNESStartupPreflightService(wait: {}).capture(candidate: candidate, inputs: recovery, io: SNESStartupPreflightFakeIO(candidate: candidate, fault: "none"))
        let preflightReceipt = try await store.saveSNESStartupPreflightWithReceipt(preflight)
        let trial = try PreparedSNESStartupTrial.prepare(candidate: candidate, receipt: preflightReceipt, recovery: recovery)
        let trialIO = StartupTrialSessionFake(expected: try .checked(trial), fault: "none")
        let trialService = SNESStartupTrialService(wait: {})
        let started = try await trialService.capture(trial: trial, io: trialIO)
        let startedReceipt = try await store.saveSNESStartupTrialStartedWithReceipt(started, trial: trial)
        let played = try await trialService.capture(trial: trial, started: started, io: trialIO)
        let playedReceipt = try await store.saveSNESStartupTrialPlayedWithReceipt(played, trial: trial, started: startedReceipt)
        func receipt(_ kind: SNESSetupRecordReceipt.Kind, _ path: String) throws -> SNESSetupRecordReceipt {
            let url = URL(fileURLWithPath: path)
            return SNESSetupRecordReceipt(kind: kind, directory: url, manifestSHA256: BackupManifest.digest(try Data(contentsOf: url.appendingPathComponent("manifest.json"))))
        }
        let verified = try SNESFirmwareVerifiedInputs(backup: receipt(.backup, base.source.source.directoryURL.path), helpers: helperDirectory,
            candidate: receipt(.candidate, base.paths.candidate), helpersManifestSHA256: helpers.manifestSHA256,
            preflight: preflightReceipt, started: startedReceipt, played: playedReceipt,
            active: receipt(.activeBoot2, base.paths.original), currentData: fresh)
        let initial = try SNESFirmwareMaterial.install(verified: verified, recovery: recovery)
        let snapshot = try SNESDataSnapshotPackage.load(receipt: fresh, source: initial.source)
        let review = try SNESFirstInstallOfflineReview(startupPlanSHA256: BackupManifest.digest(initial.planData()), dataDirectory: data,
            dataManifestSHA256: fresh.manifestSHA256, dataSHA256: snapshot.sha256, dataBytes: snapshot.byteCount)
        let saved = try await store.saveSNESFirstInstallReview(review, startupPlan: initial.planData())
        let reviewed = try SNESFirstInstallReviewMaterial.load(receipt: saved, recovery: recovery).reviewedInstallMaterial()
        let guardValue = try SNESFirmwareGuard.prepare(reviewed)
        let operations = root.appendingPathComponent("operations")
        try FileManager.default.createDirectory(at: operations, withIntermediateDirectories: false)
        let prepared = try SNESFirmwareJournal.prepare(material: reviewed, root: operations, guard: guardValue)
        let journal = try SNESFirmwareJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, material: reviewed, guard: guardValue)
        try await journal.close()
        let baseIO = SNESFirmwareFakeIO(material: reviewed, fault: "none")
        let shell = SNESFirmwareShellFake(material: reviewed, fault: "none", reviewedHash: snapshot.sha256, onFirmwareWrite: { await baseIO.simulateFirmwareWrite() })
        let libraryRoot = root.appendingPathComponent("library-operations")
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: false)
        let hostCalls = OSAllocatedUnfairLock(initialState: 0)
        let menuTrials = OSAllocatedUnfairLock(initialState: 0)
        let snapshotStartup = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let snapshotReaders = OSAllocatedUnfairLock(initialState: [SNESDataSnapshotFakeIO]())
        let upgradeShells = OSAllocatedUnfairLock(initialState: [SNESFirmwareShellFake]())
        let config = AppConfig(); config.lastConsoleType = .snesUsa; config.workspacePath = root.path; config.backupDirectoryPath = root.path
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: { hostCalls.withLock { $0 += 1 } }, firmwareJournalRoot: { operations },
            makeSNESFirmwareIO: { material, checked in
                if material.id == reviewed.id { return try NativeSNESFirmwareIO(material: material, guard: checked, base: baseIO, shell: shell, testLibraryRoot: libraryRoot) }
                let upgradeBase = SNESFirmwareFakeIO(material: material, fault: "none")
                let upgradeShell = SNESFirmwareShellFake(material: material, fault: "none", reviewedHash: material.trial.candidate.backup.sha256, onFirmwareWrite: { await upgradeBase.simulateFirmwareWrite() })
                upgradeShells.withLock { $0.append(upgradeShell) }
                return try NativeSNESFirmwareIO(material: material, guard: checked, base: upgradeBase, shell: upgradeShell, testLibraryRoot: libraryRoot)
            },
            makeSNESInstalledStartupIO: { trial in try StartupTrialSessionFake(expected: .checked(trial), fault: "none", booted: true) },
            makeSNESMenuStartupPreflightIO: { _, parent in try MenuStartupPreflightFake(parent: parent, fault: "none") },
            makeSNESDataSnapshotIO: { source in
                guard let reader = try? SNESDataSnapshotFakeIO(source: source, fault: "none", activeImageOverride: snapshotStartup.withLock({ $0 })) else {
                    preconditionFailure("The simulated snapshot source must be valid")
                }
                snapshotReaders.withLock { $0.append(reader) }
                return reader
            },
            makeSNESStartupTrialIO: { trial in
                let count = menuTrials.withLock { value in value += 1; return value }
                return try StartupTrialSessionFake(expected: .checked(trial), fault: "none", booted: count.isMultiple(of: 2))
            })
        app.isPreparingSync = true
        let selection = SNESReviewedConsoleCheck(operation: prepared.operation, planSHA256: prepared.reviewSHA256, review: saved)
        do {
            try await app.runSNESReviewedInstallation(selection, ready: true, approved: true, progress: { _ in })
        } catch {
            Issue.record("The simulated reviewed write was refused after its fixture was prepared: \(error)")
            return
        }
        #expect(hostCalls.withLock { $0 } == 1)
        #expect(await shell.writeCalls == 1)
        #expect(await baseIO.active == reviewed.target)
        let result = try await SNESFirmwareJournal.reopen(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, recovery: recovery)
        #expect(try await result.phase() == .readbackVerified)
        await #expect(throws: (any Error).self) { try await result.reserveReviewedPreflight() }
        try await result.close()
        let reopenedWritten = try await app.reopenSNESReviewedInstallation(operation: prepared.operation, review: saved)
        #expect(reopenedWritten.phase == .readbackVerified && reopenedWritten.check.planSHA256 == prepared.reviewSHA256)
        #expect(hostCalls.withLock { $0 } == 1)
        await #expect(throws: (any Error).self) { try await app.prepareSNESMenuStartup(after: selection) }
        await #expect(throws: (any Error).self) { try await app.checkSNESReviewedInstallation(selection, ready: false) }
        #expect(hostCalls.withLock { $0 } == 1)
        try await app.checkSNESReviewedInstallation(selection, ready: true)
        #expect(hostCalls.withLock { $0 } == 2)
        await #expect(throws: (any Error).self) { try await app.acceptSNESReviewedInstallation(selection, confirmed: false) }
        try await app.acceptSNESReviewedInstallation(selection, confirmed: true)
        let accepted = try await SNESFirmwareJournal.reopen(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, recovery: recovery)
        #expect(try await accepted.phase() == .menuAccepted)
        try await accepted.close()
        let reopenedAccepted = try await app.reopenSNESReviewedInstallation(operation: prepared.operation, review: saved)
        #expect(reopenedAccepted.phase == .menuAccepted)
        #expect(hostCalls.withLock { $0 } == 2)
        let exerciseFreshBackup = ProcessInfo.processInfo.environment["HC_SNES_FRESH_BACKUP_ONLY"] == "1"
        if exerciseFreshBackup {
            snapshotStartup.withLock { $0 = reviewed.targetImage }
            let captured = try await app.backupSNESReviewedCurrentData(after: selection, ready: true, progress: { _ in })
            let saved = try SNESDataSnapshotPackage.load(receipt: captured, source: reviewed.source)
            let reader = try #require(snapshotReaders.withLock { $0.last })
            #expect(saved.sha256 == reader.digest)
        }
        let menuCandidate = try await app.prepareSNESMenuStartup(after: selection, currentData: fresh)
        let preparedMenu = try SNESStartupAdapterCandidate.load(directory: menuCandidate.directory, expectedManifestSHA256: menuCandidate.manifestSHA256)
        #expect(preparedMenu.hasMenuSupport)
        #expect(preparedMenu.backup.directory.path == fresh.directory.path)
        let menuPreflight = try await app.checkSNESMenuStartup(after: selection, candidate: menuCandidate, ready: true, progress: { _ in })
        #expect(menuPreflight.record.kind == .preflight)
        func runMenuTrial(started: SNESSetupRecordReceipt? = nil) async throws -> SNESSetupRecordReceipt {
            do {
                return try await app.runSNESMenuStartupTrial(after: selection, candidate: menuCandidate, preflight: menuPreflight,
                    started: started, ready: true, progress: { _ in })
            } catch let failure as SNESPreparationDiagnosticSavedError {
                // The test removes its isolated directory on exit. Capture the
                // bounded reason first so a failed simulation is diagnosable.
                let data = try Data(contentsOf: failure.directory.appendingPathComponent("manifest.json"))
                let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                Issue.record("Temporary menu check stopped at \(record?["stage"] ?? "unknown"): \(record?["reason"] ?? "unknown")")
                throw failure
            }
        }
        let menuStarted = try await runMenuTrial()
        #expect(menuStarted.kind == .trialStarted)
        let menuPlayed = try await runMenuTrial(started: menuStarted)
        #expect(menuPlayed.kind == .trialPlayed)
        let menuUpgrade = try await app.prepareSNESMenuUpgrade(after: selection, candidate: menuCandidate, preflight: menuPreflight, started: menuStarted, played: menuPlayed, confirmed: true)
        let menuJournal = try await SNESFirmwareJournal.reopen(operation: menuUpgrade.operation, reviewSHA256: menuUpgrade.reviewSHA256, recovery: recovery)
        let menuMaterial = try await menuJournal.verifiedMaterial()
        #expect(menuMaterial.direction == .install && menuMaterial.parentOperationID == reviewed.id)
        #expect(try await menuJournal.phase() == .prepared)
        try await menuJournal.close()
        await #expect(throws: (any Error).self) { try await app.runSNESMenuUpgrade(menuUpgrade, after: selection, mode: .write, ready: true, progress: { _ in }) }
        #expect(upgradeShells.withLock { $0.isEmpty })
        try await app.runSNESMenuUpgrade(menuUpgrade, after: selection, mode: .preflight, ready: true, progress: { _ in })
        try await app.runSNESMenuUpgrade(menuUpgrade, after: selection, mode: .write, ready: true, approved: true, progress: { _ in })
        let menuWritten = try await SNESFirmwareJournal.reopen(operation: menuUpgrade.operation, reviewSHA256: menuUpgrade.reviewSHA256, recovery: recovery)
        #expect(try await menuWritten.phase() == .readbackVerified)
        try await menuWritten.close()
        try await app.checkSNESMenuUpgrade(menuUpgrade, after: selection, ready: true)
        try await app.acceptSNESMenuUpgrade(menuUpgrade, after: selection, confirmed: true)
        let menuAccepted = try await SNESFirmwareJournal.reopen(operation: menuUpgrade.operation, reviewSHA256: menuUpgrade.reviewSHA256, recovery: recovery)
        #expect(try await menuAccepted.phase() == .menuAccepted)
        try await menuAccepted.close()
        let reopenedMenu = try await app.reopenSNESMenuUpgrade(operation: menuUpgrade.operation, after: selection)
        #expect(reopenedMenu.phase == .menuAccepted && reopenedMenu.upgrade.reviewSHA256 == menuUpgrade.reviewSHA256)
        if exerciseFreshBackup {
            snapshotStartup.withLock { $0 = menuMaterial.targetImage }
            let captured = try await app.backupSNESReviewedCurrentData(after: selection, menu: menuUpgrade, ready: true, progress: { _ in })
            let saved = try SNESDataSnapshotPackage.load(receipt: captured, source: reviewed.source)
            let reader = try #require(snapshotReaders.withLock { $0.last })
            #expect(saved.sha256 == reader.digest)
            snapshotStartup.withLock { $0 = reviewed.targetImage }
            await #expect(throws: (any Error).self) {
                try await app.backupSNESReviewedCurrentData(after: selection, menu: menuUpgrade, ready: true, progress: { _ in })
            }
            let rejected = try #require(snapshotReaders.withLock { $0.last })
            #expect(await rejected.hashes == 0)
            return
        }
        let libraryCandidate = try await app.prepareSNESLibraryStartup(after: selection, menu: menuUpgrade, currentData: fresh, confirmed: true)
        let preparedLibrary = try SNESStartupAdapterCandidate.load(directory: libraryCandidate.directory, expectedManifestSHA256: libraryCandidate.manifestSHA256)
        #expect(preparedLibrary.hasNativeArtworkSupport && preparedLibrary.backup.directory.path == fresh.directory.path)
        let libraryPreflight = try await app.checkSNESMenuStartup(after: selection, menu: menuUpgrade, candidate: libraryCandidate, ready: true, progress: { _ in })
        let libraryStarted = try await app.runSNESMenuStartupTrial(after: selection, menu: menuUpgrade, candidate: libraryCandidate, preflight: libraryPreflight, ready: true, progress: { _ in })
        let libraryPlayed = try await app.runSNESMenuStartupTrial(after: selection, menu: menuUpgrade, candidate: libraryCandidate, preflight: libraryPreflight, started: libraryStarted, ready: true, progress: { _ in })
        let libraryUpgrade = try await app.prepareSNESMenuUpgrade(after: selection, menu: menuUpgrade, candidate: libraryCandidate, preflight: libraryPreflight, started: libraryStarted, played: libraryPlayed, confirmed: true)
        try await app.runSNESMenuUpgrade(libraryUpgrade, after: selection, menu: menuUpgrade, mode: .preflight, ready: true, progress: { _ in })
        try await app.runSNESMenuUpgrade(libraryUpgrade, after: selection, menu: menuUpgrade, mode: .write, ready: true, approved: true, progress: { _ in })
        try await app.checkSNESMenuUpgrade(libraryUpgrade, after: selection, menu: menuUpgrade, ready: true)
        try await app.acceptSNESMenuUpgrade(libraryUpgrade, after: selection, menu: menuUpgrade, confirmed: true)
        let libraryAccepted = try await SNESFirmwareJournal.reopen(operation: libraryUpgrade.operation, reviewSHA256: libraryUpgrade.reviewSHA256, recovery: recovery)
        #expect(try await libraryAccepted.phase() == .menuAccepted)
        try await libraryAccepted.close()
        let reopenedLibrary = try await app.reopenSNESMenuUpgrade(operation: libraryUpgrade.operation, after: selection)
        #expect(reopenedLibrary.phase == .menuAccepted && reopenedLibrary.upgrade.reviewSHA256 == libraryUpgrade.reviewSHA256)
        #expect(reopenedLibrary.parentMenu?.operation.path == menuUpgrade.operation.path && reopenedLibrary.parentMenu?.reviewSHA256 == menuUpgrade.reviewSHA256)

        // A changed live data hash cannot reach the writer.
        let mismatchRoot = root.appendingPathComponent("mismatch-operations")
        try FileManager.default.createDirectory(at: mismatchRoot, withIntermediateDirectories: false)
        let mismatchPlan = try SNESFirmwareJournal.prepare(material: reviewed, root: mismatchRoot, guard: guardValue)
        let mismatchJournal = try SNESFirmwareJournal(operation: mismatchPlan.operation, reviewSHA256: mismatchPlan.reviewSHA256, material: reviewed, guard: guardValue)
        let mismatchBase = SNESFirmwareFakeIO(material: reviewed, fault: "none")
        let mismatchShell = SNESFirmwareShellFake(material: reviewed, fault: "none", reviewedHash: String(repeating: "0", count: 64))
        let mismatchIO = try NativeSNESFirmwareIO(material: reviewed, guard: guardValue, base: mismatchBase, shell: mismatchShell, testLibraryRoot: libraryRoot)
        await #expect(throws: (any Error).self) {
            try await SNESFirmwareTransaction(wait: {}).run(mode: .write, journal: mismatchJournal, guard: guardValue, inputs: recovery, io: mismatchIO)
        }
        #expect(await mismatchShell.writeCalls == 0)
        #expect(try await mismatchJournal.phase() == .prepared)
        try await mismatchJournal.close()

        // A lost/failed response after dispatch must be durable and cannot be retried.
        let failureRoot = root.appendingPathComponent("failed-operations")
        try FileManager.default.createDirectory(at: failureRoot, withIntermediateDirectories: false)
        let failurePlan = try SNESFirmwareJournal.prepare(material: reviewed, root: failureRoot, guard: guardValue)
        let failureJournal = try SNESFirmwareJournal(operation: failurePlan.operation, reviewSHA256: failurePlan.reviewSHA256, material: reviewed, guard: guardValue)
        let failureBase = SNESFirmwareFakeIO(material: reviewed, fault: "none")
        let failureShell = SNESFirmwareShellFake(material: reviewed, fault: "write-exit", reviewedHash: snapshot.sha256)
        let failureIO = try NativeSNESFirmwareIO(material: reviewed, guard: guardValue, base: failureBase, shell: failureShell, testLibraryRoot: libraryRoot)
        await #expect(throws: SNESFirmwareTransactionError.self) {
            try await SNESFirmwareTransaction(wait: {}).run(mode: .write, journal: failureJournal, guard: guardValue, inputs: recovery, io: failureIO)
        }
        #expect(await failureShell.writeCalls == 1)
        #expect(try await failureJournal.phase() == .uncertain)
        await #expect(throws: (any Error).self) { try await failureJournal.reserveReviewedPreflight() }
        try await failureJournal.close()

        // Cancellation at the dispatch boundary must revoke the queued write.
        let cancelRoot = root.appendingPathComponent("cancelled-operations")
        try FileManager.default.createDirectory(at: cancelRoot, withIntermediateDirectories: false)
        let cancelPlan = try SNESFirmwareJournal.prepare(material: reviewed, root: cancelRoot, guard: guardValue)
        let cancelJournal = try SNESFirmwareJournal(operation: cancelPlan.operation, reviewSHA256: cancelPlan.reviewSHA256, material: reviewed, guard: guardValue)
        let cancelBase = SNESFirmwareFakeIO(material: reviewed, fault: "none")
        let cancelShell = SNESFirmwareShellFake(material: reviewed, fault: "none", reviewedHash: snapshot.sha256)
        let cancelIO = try NativeSNESFirmwareIO(material: reviewed, guard: guardValue, base: cancelBase, shell: cancelShell, testLibraryRoot: libraryRoot)
        await cancelShell.holdFirmwareDispatch(before: true)
        let cancelTask = Task { try await SNESFirmwareTransaction(wait: {}).run(mode: .write, journal: cancelJournal, guard: guardValue, inputs: recovery, io: cancelIO) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while !(await cancelShell.firmwareWaiting) && ContinuousClock.now < deadline && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
        guard await cancelShell.firmwareWaiting else {
            cancelTask.cancel(); await cancelShell.releaseFirmwareDispatch(); _ = try? await cancelTask.value
            try? await cancelJournal.close(); Issue.record("The simulated write did not reach its dispatch boundary"); return
        }
        cancelTask.cancel(); await cancelShell.releaseFirmwareDispatch()
        await #expect(throws: SNESFirmwareTransactionError.self) { try await cancelTask.value }
        #expect(await cancelShell.writeCalls == 0)
        #expect(try await cancelJournal.phase() == .uncertain)
        try await cancelJournal.close()

        // A changed backup after readback is recorded must revoke that success.
        let changedRoot = root.appendingPathComponent("changed-after-readback")
        try FileManager.default.createDirectory(at: changedRoot, withIntermediateDirectories: false)
        let changedPlan = try SNESFirmwareJournal.prepare(material: reviewed, root: changedRoot, guard: guardValue)
        let files = try FileManager.default.contentsOfDirectory(atPath: data.path)
        let chunk = try #require(files.filter { $0.hasPrefix("data-") && $0.hasSuffix(".bin") && $0 != "data-header.bin" }.sorted().last)
        let chunkURL = data.appendingPathComponent(chunk), originalChunk = try Data(contentsOf: chunkURL)
        var changedChunk = originalChunk; changedChunk[0] ^= 1
        let changedBytes = changedChunk, triggered = OSAllocatedUnfairLock(initialState: false)
        let changedJournal = try SNESFirmwareJournal(operation: changedPlan.operation, reviewSHA256: changedPlan.reviewSHA256,
            material: reviewed, guard: guardValue, afterRecordRead: {
                guard FileManager.default.fileExists(atPath: changedPlan.operation.appendingPathComponent("0002.json").path) else { return }
                let shouldChange = triggered.withLock { value in if value { return false }; value = true; return true }
                if shouldChange { try changedBytes.write(to: chunkURL) }
            })
        let changedBase = SNESFirmwareFakeIO(material: reviewed, fault: "none")
        let changedShell = SNESFirmwareShellFake(material: reviewed, fault: "none", reviewedHash: snapshot.sha256,
            onFirmwareWrite: { await changedBase.simulateFirmwareWrite() })
        let changedIO = try NativeSNESFirmwareIO(material: reviewed, guard: guardValue, base: changedBase, shell: changedShell, testLibraryRoot: libraryRoot)
        await #expect(throws: SNESFirmwareTransactionError.self) {
            try await SNESFirmwareTransaction(wait: {}).run(mode: .write, journal: changedJournal, guard: guardValue, inputs: recovery, io: changedIO)
        }
        #expect(triggered.withLock { $0 })
        #expect(await changedShell.writeCalls == 1)
        #expect(try await changedJournal.phase() == .uncertain)
        try await changedJournal.close()
    }
    @Test func savedReviewAllowsDifferentJSONFormattingWithoutAcceptingDifferentFields() throws {
        let review=try SNESFirstInstallOfflineReview(startupPlanSHA256:String(repeating:"a",count:64),
            dataDirectory:URL(fileURLWithPath:"/tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111"),
            dataManifestSHA256:String(repeating:"b",count:64),dataSHA256:String(repeating:"c",count:64),dataBytes:1048576)
        let canonical=try review.canonicalBytes()
        var fields=try #require(JSONSerialization.jsonObject(with:canonical) as? [String:Any])
        let alternate=try JSONSerialization.data(withJSONObject:fields,options:[.prettyPrinted,.sortedKeys])
        #expect(alternate != canonical)
        let loaded=try SNESFirstInstallOfflineReview.load(alternate,expectedSHA256:BackupManifest.digest(alternate))
        #expect(try loaded.canonicalBytes() == canonical)
        fields["unexpected"]=true
        let extra=try JSONSerialization.data(withJSONObject:fields)
        #expect(throws:(any Error).self) {try SNESFirstInstallOfflineReview.load(extra,expectedSHA256:BackupManifest.digest(extra))}
        fields.removeValue(forKey:"unexpected");fields["schemaVersion"]=true
        let wrongType=try JSONSerialization.data(withJSONObject:fields)
        #expect(throws:(any Error).self) {try SNESFirstInstallOfflineReview.load(wrongType,expectedSHA256:BackupManifest.digest(wrongType))}
    }
    @Test func oldOversizedReviewExplainsHowToProceed() throws {
        let root=try testDirectory().standardizedFileURL;defer {try? FileManager.default.removeItem(at:root)}
        let plan=Data(repeating:0x20,count:16385)
        let review=try SNESFirstInstallOfflineReview(startupPlanSHA256:BackupManifest.digest(plan),
            dataDirectory:root.appendingPathComponent("SNES-Current-Data-11111111-1111-1111-1111-111111111111",isDirectory:true),
            dataManifestSHA256:String(repeating:"a",count:64),dataSHA256:String(repeating:"b",count:64),dataBytes:1048576)
        let directory=root.appendingPathComponent("SNES-First-Install-Review-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
        try plan.write(to:directory.appendingPathComponent("startup-plan.json"))
        try review.canonicalBytes().write(to:directory.appendingPathComponent("manifest.json"))
        let receipt=SNESFirstInstallReviewReceipt(directory:directory,sha256:try review.digest())
        do {
            _=try SNESFirstInstallReviewMaterial.load(receipt:receipt,recovery:.init(fes1:Data(),uboot:Data(),bootImage:Data()))
            Issue.record("An oversized review was accepted")
        } catch {
            #expect(error.localizedDescription.localizedCaseInsensitiveContains("too large"))
        }
    }
    @Test func oversizedReviewIsRejectedBeforeCreatingFiles() async throws {
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let plan=Data(repeating:0x20,count:16385)
        let review=try SNESFirstInstallOfflineReview(startupPlanSHA256:BackupManifest.digest(plan),
            dataDirectory:URL(fileURLWithPath:"/tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111"),
            dataManifestSHA256:String(repeating:"a",count:64),dataSHA256:String(repeating:"b",count:64),dataBytes:1048576)
        let store=try RecoveryBootSnapshotStore(root:root)
        await #expect(throws:(any Error).self) {try await store.saveSNESFirstInstallReview(review,startupPlan:plan)}
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
    }
    @Test func savedOfflineReviewRequiresItsExactReceiptAndCannotHideAdditionalFiles() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let startupPlan = Data("example untrusted startup plan".utf8)
        let review = try SNESFirstInstallOfflineReview(startupPlanSHA256: BackupManifest.digest(startupPlan),
            dataDirectory: URL(fileURLWithPath: "/tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111"),
            dataManifestSHA256: String(repeating: "b", count: 64), dataSHA256: String(repeating: "c", count: 64), dataBytes: 1048576)
        let store = try RecoveryBootSnapshotStore(root: root)
        let receipt = try await store.saveSNESFirstInstallReview(review, startupPlan: startupPlan)
        #expect(receipt.sha256 == (try review.digest()))
        #expect(try SNESFirstInstallReviewReceipt.inspect(directory: receipt.directory).sha256 == receipt.sha256)
        let reopened = try SNESFirstInstallReviewReceipt.open(receipt)
        #expect(try reopened.digest() == review.digest())
        let planFile = receipt.directory.appendingPathComponent("startup-plan.json")
        #expect(try Data(contentsOf: planFile) == startupPlan)
        try Data([0]).write(to: planFile)
        #expect(throws: (any Error).self) { try SNESFirstInstallReviewReceipt.open(receipt) }
        try startupPlan.write(to: planFile)
        #expect(throws: (any Error).self) {
            try SNESFirstInstallReviewReceipt.open(receipt, afterRead: { try Data([0]).write(to: planFile) })
        }
        try startupPlan.write(to: planFile)
        let wrong = SNESFirstInstallReviewReceipt(directory: receipt.directory, sha256: String(repeating: "0", count: 64))
        #expect(throws: (any Error).self) { try SNESFirstInstallReviewReceipt.open(wrong) }
        #expect(throws: (any Error).self) {
            try SNESFirstInstallReviewReceipt.open(receipt, afterRead: {
                try Data([2]).write(to: receipt.directory.appendingPathComponent("added-during-read"))
            })
        }
        try FileManager.default.removeItem(at: receipt.directory.appendingPathComponent("added-during-read"))
        let manifest = receipt.directory.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifest)
        #expect(throws: (any Error).self) {
            try SNESFirstInstallReviewReceipt.open(receipt, afterRead: { try Data([0]).write(to: manifest) })
        }
        try original.write(to: manifest)
        try Data([1]).write(to: receipt.directory.appendingPathComponent("extra"))
        #expect(throws: (any Error).self) { try SNESFirstInstallReviewReceipt.open(receipt) }
        try FileManager.default.removeItem(at: receipt.directory.appendingPathComponent("extra"))
        try Data([0]).write(to: receipt.directory.appendingPathComponent("manifest.json"))
        #expect(throws: (any Error).self) { try SNESFirstInstallReviewReceipt.open(receipt) }
    }
    @Test func finalReviewVerifierCannotChangeManifestAndStillReturnSuccess() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let startupPlan = Data("example untrusted startup plan".utf8)
        let review = try SNESFirstInstallOfflineReview(startupPlanSHA256: BackupManifest.digest(startupPlan),
            dataDirectory: URL(fileURLWithPath: "/tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111"),
            dataManifestSHA256: String(repeating: "b", count: 64), dataSHA256: String(repeating: "c", count: 64), dataBytes: 1048576)
        let state = OSAllocatedUnfairLock(initialState: (directory: Optional<URL>.none, calls: 0))
        let store = try RecoveryBootSnapshotStore(root: root)
        do {
            _ = try await store.saveSNESFirstInstallReview(review, startupPlan: startupPlan, afterCreate: { directory in
                state.withLock { $0.directory = directory }
            }, verify: {
                let target = state.withLock { value -> URL? in
                    value.calls += 1; return value.calls == 3 ? value.directory : nil
                }
                if let target { try Data([0x4f]).write(to: target.appendingPathComponent("manifest.json")) }
            })
            Issue.record("Changed review was reported as saved")
        } catch let failure as SNESFirstInstallReviewSaveError {
            #expect(try Data(contentsOf: failure.directory.appendingPathComponent("manifest.json")) == Data([0x4f]))
        }
    }
    @Test func interruptedReviewSavePreservesSubstitutedFiles() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let startupPlan = Data("example untrusted startup plan".utf8)
        let review = try SNESFirstInstallOfflineReview(startupPlanSHA256: BackupManifest.digest(startupPlan),
            dataDirectory: URL(fileURLWithPath: "/tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111"),
            dataManifestSHA256: String(repeating: "b", count: 64), dataSHA256: String(repeating: "c", count: 64), dataBytes: 1048576)
        let store = try RecoveryBootSnapshotStore(root: root)
        do {
            _ = try await store.saveSNESFirstInstallReview(review, startupPlan: startupPlan, afterCreate: { directory in
                try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("displaced"))
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                try Data([0x7a]).write(to: directory.appendingPathComponent("manifest.json"))
            })
            Issue.record("Substituted review directory was accepted")
        } catch let failure as SNESFirstInstallReviewSaveError {
            #expect(try Data(contentsOf: failure.directory.appendingPathComponent("manifest.json")) == Data([0x7a]))
        }
    }
    @Test func offlineReviewCanBeReopenedOnlyWithExactPinnedCanonicalBytes() throws {
        let plan = String(repeating: "a", count: 64), manifest = String(repeating: "b", count: 64)
        let hash = String(repeating: "c", count: 64)
        let directory = URL(fileURLWithPath: "/tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111")
        let original = try SNESFirstInstallOfflineReview(startupPlanSHA256: plan, dataDirectory: directory,
            dataManifestSHA256: manifest, dataSHA256: hash, dataBytes: 1048576)
        let bytes = try original.canonicalBytes(), digest = try original.digest()
        let loaded = try SNESFirstInstallOfflineReview.load(bytes, expectedSHA256: digest)
        #expect(try loaded.digest() == digest)
        #expect(throws: (any Error).self) { try SNESFirstInstallOfflineReview.load(bytes, expectedSHA256: String(repeating: "0", count: 64)) }
        var extra = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        extra["unexpected"] = true
        let changed = try JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys])
        #expect(throws: (any Error).self) { try SNESFirstInstallOfflineReview.load(changed, expectedSHA256: BackupManifest.digest(changed)) }
        var bad = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        bad["dataDirectory"] = "/tmp/../tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111"
        let badBytes = try JSONSerialization.data(withJSONObject: bad, options: [.sortedKeys])
        #expect(throws: (any Error).self) { try SNESFirstInstallOfflineReview.load(badBytes, expectedSHA256: BackupManifest.digest(badBytes)) }
    }
    @Test func offlineReviewBindsIndependentDataBackupWithoutAuthorizingAWrite() throws {
        let startup = String(repeating: "a", count: 64), manifest = String(repeating: "b", count: 64)
        let data = String(repeating: "c", count: 64), directory = URL(fileURLWithPath: "/tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111")
        func review(_ path: URL, _ saved: String, _ hash: String, _ bytes: Int) throws -> SNESFirstInstallOfflineReview {
            try SNESFirstInstallOfflineReview(startupPlanSHA256: startup, dataDirectory: path,
                dataManifestSHA256: saved, dataSHA256: hash, dataBytes: bytes)
        }
        let baseline = try review(directory, manifest, data, 1048576)
        #expect(try baseline.digest() != review(directory, String(repeating: "d", count: 64), data, 1048576).digest())
        #expect(try baseline.digest() != review(directory, manifest, String(repeating: "e", count: 64), 1048576).digest())
        #expect(try baseline.digest() != review(directory, manifest, data, 2097152).digest())
        #expect(try baseline.digest() != review(directory.appendingPathComponent("other"), manifest, data, 1048576).digest())
        #expect(throws: (any Error).self) { try review(directory, "invalid", data, 1048576) }
        #expect(throws: (any Error).self) { try review(directory, manifest, data, 0) }
    }
    @Test func targetPreservesEveryByteBeyondFinalChangedUnit()throws {
        let original=Data(repeating:0x35,count:7340032),image=Data(repeating:0xa5,count:131073)
        let result=try SNESFirmwareRangeTarget.install(image:image,over:original)
        #expect(result.count==7340032)
        #expect(result.prefix(131073)==image)
        #expect(result[131073..<262144].allSatisfy{$0==255})
        #expect(result[262144...].allSatisfy{$0==0x35})
        let exact=try SNESFirmwareRangeTarget.install(image:Data(repeating:0x77,count:131072),over:original)
        #expect(exact[131072...]==original[131072...])
        for bad in [Data(),Data(count:7340033)] {
            #expect(throws:(any Error).self) {try SNESFirmwareRangeTarget.install(image:bad,over:original)}
        }
        #expect(throws:(any Error).self) {try SNESFirmwareRangeTarget.install(image:image,over:Data(count:7340031))}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_WRITER"] != nil))
    func onlyExactReviewedWriterHasWriteHelperType()throws {
        let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_WRITER"])
        let writer=try SNESBoundedWriteHelper.load(URL(fileURLWithPath:path))
        #expect(writer.digest == SNESBoundedWriteHelper.sha256 ||
                SNESPortableHelpers.recognizes(kind: .writer, byteCount: writer.bytes.count, sha256: writer.digest))
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("changed");var changed=writer.bytes;changed[changed.count-1]^=1;try changed.write(to:file)
        #expect(throws:(any Error).self){try SNESBoundedWriteHelper.load(file)}
        try writer.bytes.write(to:file);let link=root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:file)
        #expect(throws:(any Error).self){try SNESBoundedWriteHelper.load(link)}
        try Data([1]).write(to:file)
        #expect(throws:(any Error).self){try SNESBoundedWriteHelper.load(file)}
    }
}

func privateFirmwarePaths()throws->SNESFirmwarePaths {
    let env=ProcessInfo.processInfo.environment
    return try SNESFirmwarePaths(candidate:#require(env["SWIFTHAKCHI_SNES_STARTUP_CANDIDATE"]),preflight:#require(env["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"]),started:#require(env["SWIFTHAKCHI_SNES_STARTUP_STARTED"]),played:#require(env["SWIFTHAKCHI_SNES_STARTUP_PLAYED"]),original:#require(env["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"]),reader:#require(env["SWIFTHAKCHI_SNES_ACTIVE_READER"]),writer:#require(env["SWIFTHAKCHI_SNES_WRITER"]))
}
actor SNESFirmwareFixtureCache {
    static let shared=SNESFirmwareFixtureCache()
    private var material:SNESFirmwareMaterial?
    func value()throws->SNESFirmwareMaterial {
        if let material {return material};let pins=try PinnedFELInputs.load()
        let m=try SNESFirmwareMaterial.install(paths:privateFirmwarePaths(),recovery:.init(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage));material=m;return m
    }
}
struct SNESFirmwareFrozenInputTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func reviewedPlanRetainsExactBytesAcrossJSONFormattingChanges() async throws {
        let material=try await SNESFirmwareFixtureCache.shared.value()
        let original=try material.planData()
        let alternate=try JSONSerialization.data(withJSONObject:JSONSerialization.jsonObject(with:original),options:[.sortedKeys])
        #expect(alternate != original)
        let review=try SNESFirstInstallOfflineReview(startupPlanSHA256:BackupManifest.digest(original),
            dataDirectory:URL(fileURLWithPath:"/tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111"),
            dataManifestSHA256:String(repeating:"a",count:64),dataSHA256:String(repeating:"b",count:64),dataBytes:1048576)
        let receipt=SNESFirstInstallReviewReceipt(directory:URL(fileURLWithPath:"/tmp/SNES-First-Install-Review-22222222-2222-2222-2222-222222222222"),sha256:try review.digest())
        let binding=try SNESFirstInstallPlanBinding(receipt:receipt,review:review,startupPlanID:material.id)
        let first=try material.bindingFirstInstall(binding)
        var plan=try #require(JSONSerialization.jsonObject(with:first.planData()) as? [String:Any])
        var frozen=try #require(plan["firstInstall"] as? [String:Any])
        frozen["startupPlanSHA256"]=BackupManifest.digest(alternate)
        frozen["startupPlanData"]=alternate.base64EncodedString()
        plan["firstInstall"]=frozen
        let decoded=try JSONDecoder().decode(SNESFirmwarePlan.self,from:JSONSerialization.data(withJSONObject:plan))
        #expect(try decoded.reviewedStartupPlanData() == alternate)
        var poisoned=try #require(JSONSerialization.jsonObject(with:alternate) as? [String:Any])
        poisoned["targetSHA256"]=String(repeating:"0",count:64)
        let changed=try JSONSerialization.data(withJSONObject:poisoned,options:[.sortedKeys])
        frozen["startupPlanSHA256"]=BackupManifest.digest(changed)
        frozen["startupPlanData"]=changed.base64EncodedString();plan["firstInstall"]=frozen
        let mismatched=try JSONDecoder().decode(SNESFirmwarePlan.self,from:JSONSerialization.data(withJSONObject:plan))
        #expect(throws:(any Error).self) {try mismatched.reviewedStartupPlanData()}
        var wrongType=try #require(JSONSerialization.jsonObject(with:alternate) as? [String:Any])
        wrongType["schemaVersion"]=true
        let booleanPlan=try JSONSerialization.data(withJSONObject:wrongType,options:[.sortedKeys])
        frozen["startupPlanSHA256"]=BackupManifest.digest(booleanPlan)
        frozen["startupPlanData"]=booleanPlan.base64EncodedString();plan["firstInstall"]=frozen
        let malformed=try JSONDecoder().decode(SNESFirmwarePlan.self,from:JSONSerialization.data(withJSONObject:plan))
        #expect(throws:(any Error).self) {try malformed.reviewedStartupPlanData()}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func duplicatePlanKeysAreRejectedEvenWhenDecodedValuesMatch() async throws {
        let material=try await SNESFirmwareFixtureCache.shared.value()
        let original=try material.planData()
        let compact=try JSONSerialization.data(withJSONObject:JSONSerialization.jsonObject(with:original),options:[.sortedKeys])
        let text=try #require(String(data:compact,encoding:.utf8))
        #expect(text.first == "{")
        let duplicate=Data(("{\"schemaVersion\":1,"+text.dropFirst()).utf8)
        let escaped=Data(("{\"schema\\u0056ersion\":1,"+text.dropFirst()).utf8)
        let encodedPath=String(decoding:try JSONEncoder().encode(material.paths.candidate),as:UTF8.self)
        let nestedText=text.replacingOccurrences(of:"\"paths\":{",with:"\"paths\":{\"candidate\":"+encodedPath+",")
        #expect(nestedText != text)
        let nested=Data(nestedText.utf8)
        #expect(try SNESFirmwarePlan.sameFields(original,compact))
        for bytes in [duplicate,escaped,nested] {
            #expect(throws:(any Error).self) {try SNESFirmwarePlan.sameFields(bytes,original)}
        }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func legacyJournalReopensWhenSavedJSONFormattingDiffers() async throws {
        let material=try await SNESFirmwareFixtureCache.shared.value(),original=try material.planData()
        let saved=try JSONSerialization.data(withJSONObject:JSONSerialization.jsonObject(with:original),options:[.sortedKeys])
        #expect(saved != original)
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let operation=root.appendingPathComponent("SNESFirmware-"+material.id.uuidString),digest=BackupManifest.digest(saved)
        try FileManager.default.createDirectory(at:operation,withIntermediateDirectories:false)
        try saved.write(to:operation.appendingPathComponent("plan.json"))
        try (material.geometry+material.preimage+material.target).write(to:operation.appendingPathComponent("input.bin"))
        try Data(digest.utf8).write(to:operation.appendingPathComponent("preparation.complete"))
        try JSONSerialization.data(withJSONObject:["phase":"prepared","planSHA256":digest,"markerRequired":true],options:[.sortedKeys]).write(to:operation.appendingPathComponent("0000.json"))
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let reopened=try await SNESFirmwareJournal.reopen(operation:operation,reviewSHA256:digest,recovery:inputs)
        #expect(try await reopened.phase() == .prepared)
        #expect(try await reopened.verifiedMaterial().planData() == saved)
        try await reopened.close()
        // Even a digest-consistent journal cannot contain an ambiguous plan.
        let text=try #require(String(data:saved,encoding:.utf8))
        let duplicate=Data(("{\"schemaVersion\":1,"+text.dropFirst()).utf8),duplicateDigest=BackupManifest.digest(duplicate)
        try duplicate.write(to:operation.appendingPathComponent("plan.json"))
        try Data(duplicateDigest.utf8).write(to:operation.appendingPathComponent("preparation.complete"))
        try JSONSerialization.data(withJSONObject:["phase":"prepared","planSHA256":duplicateDigest,"markerRequired":true],options:[.sortedKeys]).write(to:operation.appendingPathComponent("0000.json"))
        await #expect(throws:(any Error).self) {try await SNESFirmwareJournal.reopen(operation:operation,reviewSHA256:duplicateDigest,recovery:inputs)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func reviewedJournalReopensWhenSavedJSONFormattingDiffers() async throws {
        let material=try await SNESFirmwareFixtureCache.shared.value(),original=try material.planData()
        let review=try SNESFirstInstallOfflineReview(startupPlanSHA256:BackupManifest.digest(original),
            dataDirectory:URL(fileURLWithPath:"/tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111"),
            dataManifestSHA256:String(repeating:"a",count:64),dataSHA256:String(repeating:"b",count:64),dataBytes:1048576)
        let receipt=SNESFirstInstallReviewReceipt(directory:URL(fileURLWithPath:"/tmp/SNES-First-Install-Review-22222222-2222-2222-2222-222222222222"),sha256:try review.digest())
        let binding=try SNESFirstInstallPlanBinding(receipt:receipt,review:review,startupPlanID:material.id,startupPlanData:original)
        let first=try material.bindingFirstInstall(binding),encoded=try first.planData()
        let saved=try JSONSerialization.data(withJSONObject:JSONSerialization.jsonObject(with:encoded),options:[.sortedKeys])
        #expect(saved != encoded)
        let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
        let operation=root.appendingPathComponent("SNESFirmware-"+first.id.uuidString),digest=BackupManifest.digest(saved)
        try FileManager.default.createDirectory(at:operation,withIntermediateDirectories:false)
        try saved.write(to:operation.appendingPathComponent("plan.json"))
        try (material.geometry+material.preimage+material.target).write(to:operation.appendingPathComponent("input.bin"))
        try Data(digest.utf8).write(to:operation.appendingPathComponent("preparation.complete"))
        try JSONSerialization.data(withJSONObject:["phase":"prepared","planSHA256":digest,"markerRequired":true],options:[.sortedKeys]).write(to:operation.appendingPathComponent("0000.json"))
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let reopened=try await SNESFirmwareJournal.reopen(operation:operation,reviewSHA256:digest,recovery:inputs)
        #expect(try await reopened.phase() == .prepared)
        #expect(try await reopened.verifiedMaterial().planData() == saved)
        try await reopened.close()

        // The original review's bytes may also use a different JSON encoding.
        let alternateOriginal=try JSONSerialization.data(withJSONObject:JSONSerialization.jsonObject(with:original),options:[.sortedKeys])
        var outer=try #require(JSONSerialization.jsonObject(with:saved) as? [String:Any])
        var frozen=try #require(outer["firstInstall"] as? [String:Any])
        frozen["startupPlanData"]=alternateOriginal.base64EncodedString();frozen["startupPlanSHA256"]=BackupManifest.digest(alternateOriginal)
        outer["firstInstall"]=frozen
        let savedBoth=try JSONSerialization.data(withJSONObject:outer,options:[.sortedKeys]),bothDigest=BackupManifest.digest(savedBoth)
        let secondRoot=try testDirectory();defer {try? FileManager.default.removeItem(at:secondRoot)}
        let second=secondRoot.appendingPathComponent("SNESFirmware-"+first.id.uuidString)
        try FileManager.default.createDirectory(at:second,withIntermediateDirectories:false)
        try savedBoth.write(to:second.appendingPathComponent("plan.json"))
        try (material.geometry+material.preimage+material.target).write(to:second.appendingPathComponent("input.bin"))
        try Data(bothDigest.utf8).write(to:second.appendingPathComponent("preparation.complete"))
        try JSONSerialization.data(withJSONObject:["phase":"prepared","planSHA256":bothDigest,"markerRequired":true],options:[.sortedKeys]).write(to:second.appendingPathComponent("0000.json"))
        let reopenedBoth=try await SNESFirmwareJournal.reopen(operation:second,reviewSHA256:bothDigest,recovery:inputs)
        #expect(try await reopenedBoth.phase() == .prepared)
        #expect(try await reopenedBoth.verifiedMaterial().planData() == savedBoth)
        try await reopenedBoth.close()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func separateReviewedOperationsDoNotReuseTheDraftIdentifier() async throws {
        let material=try await SNESFirmwareFixtureCache.shared.value()
        let review=try SNESFirstInstallOfflineReview(startupPlanSHA256:BackupManifest.digest(material.planData()),
            dataDirectory:URL(fileURLWithPath:"/tmp/SNES-Current-Data-11111111-1111-1111-1111-111111111111"),
            dataManifestSHA256:String(repeating:"a",count:64),dataSHA256:String(repeating:"b",count:64),dataBytes:1048576)
        let receipt=SNESFirstInstallReviewReceipt(directory:URL(fileURLWithPath:"/tmp/SNES-First-Install-Review-22222222-2222-2222-2222-222222222222"),sha256:try review.digest())
        let binding=try SNESFirstInstallPlanBinding(receipt:receipt,review:review,startupPlanID:material.id)
        let first=try material.bindingFirstInstall(binding),second=try material.bindingFirstInstall(binding)
        #expect(first.id != material.id && second.id != material.id && first.id != second.id)
        #expect(first.firstInstall?.startupPlanID == material.id && second.firstInstall?.startupPlanID == material.id)
        #expect(try first.planData() != second.planData())
        let firstPlan=try JSONDecoder().decode(SNESFirmwarePlan.self,from:first.planData())
        #expect(try firstPlan.reviewedStartupPlanData() == material.planData())
        var changed=try #require(JSONSerialization.jsonObject(with:JSONEncoder().encode(binding)) as? [String:Any])
        changed["startupPlanID"]=UUID().uuidString
        let invalid=try JSONDecoder().decode(SNESFirstInstallPlanBinding.self,from:JSONSerialization.data(withJSONObject:changed))
        #expect(throws:(any Error).self) {try material.bindingFirstInstall(invalid)}
        // Discovery must reject malformed plans without relying on a later full
        // reopen: an equal operation/draft ID or a different draft ID breaks the binding.
        for fault in ["valid","equal-id","wrong-draft","pending"] {
            let root=try testDirectory();defer {try? FileManager.default.removeItem(at:root)}
            var plan=try #require(JSONSerialization.jsonObject(with:first.planData()) as? [String:Any])
            var savedBinding=try #require(plan["firstInstall"] as? [String:Any])
            if fault=="equal-id" {plan["id"]=material.id.uuidString}
            if fault=="wrong-draft" {savedBinding["startupPlanID"]=UUID().uuidString;plan["firstInstall"]=savedBinding}
            let planBytes:Data
            if fault=="valid" || fault=="pending" {planBytes=try first.planData()}
            else {planBytes=try JSONSerialization.data(withJSONObject:plan,options:[.prettyPrinted,.sortedKeys])}
            let digest=BackupManifest.digest(planBytes),id=try #require(plan["id"] as? String)
            let operation=root.appendingPathComponent("SNESFirmware-"+id)
            try FileManager.default.createDirectory(at:operation,withIntermediateDirectories:false)
            try planBytes.write(to:operation.appendingPathComponent("plan.json"))
            try (material.geometry+material.preimage+material.target).write(to:operation.appendingPathComponent("input.bin"))
            let marker=fault=="pending" ? "preparation.pending":"preparation.complete"
            try Data(digest.utf8).write(to:operation.appendingPathComponent(marker))
            let record:[String:Any]=["phase":"prepared","planSHA256":digest,"markerRequired":true]
            try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:operation.appendingPathComponent("0000.json"))
            if fault=="valid" {
                try SNESFirmwareJournal.validateSiblingHistory(root:root,excluding:second.id,recoveryParent:nil)
                let matching=try SNESFirmwareJournal(operation:operation,reviewSHA256:digest,material:first)
                try await matching.close()
                #expect(throws:(any Error).self) {
                    try SNESFirmwareJournal(operation:operation,reviewSHA256:BackupManifest.digest(second.planData()),material:second)
                }
            } else {#expect(throws:(any Error).self) {try SNESFirmwareJournal.validateSiblingHistory(root:root,excluding:second.id,recoveryParent:nil)}}
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func verifiedReviewAcceptsAndSealsIndependentNewerData() async throws {
        let base = try await SNESFirmwareFixtureCache.shared.value()
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.copyItem(at: base.trial.candidate.backup.directory, to: data)
        let manifestURL = data.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var files = try #require(manifest["files"] as? [String: String])
        let names = files.keys.filter { $0.hasPrefix("data-") && $0.hasSuffix(".bin") && $0 != "data-header.bin" }.sorted()
        let last = try #require(names.last)
        var full = SHA256()
        for name in names {
            let file = data.appendingPathComponent(name); var bytes = try Data(contentsOf: file)
            if name == last { bytes[bytes.count - 1] ^= 1; try bytes.write(to: file); files[name] = BackupManifest.digest(bytes) }
            full.update(data: bytes)
        }
        manifest["files"] = files
        manifest["sha256"] = full.finalize().map { String(format: "%02x", $0) }.joined()
        let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try bytes.write(to: manifestURL)
        let fresh = SNESDataSnapshotReceipt(directory: data, manifestSHA256: BackupManifest.digest(bytes))
        let store = try RecoveryBootSnapshotStore(root: root)
        let helperDirectory = try await store.saveSNESPortableHelpers()
        let helpers = try SNESPortableHelperPackage.load(directory: helperDirectory)
        let pins = try PinnedFELInputs.load()
        let recovery = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let candidate = base.trial.candidate
        let preflightIO = try SNESStartupPreflightFakeIO(candidate: candidate, fault: "none")
        let preflight = try await SNESStartupPreflightService(wait: {}).capture(candidate: candidate, inputs: recovery, io: preflightIO)
        let preflightReceipt = try await store.saveSNESStartupPreflightWithReceipt(preflight)
        let trial = try PreparedSNESStartupTrial.prepare(candidate: candidate, receipt: preflightReceipt, recovery: recovery)
        let trialIO = StartupTrialSessionFake(expected: try .checked(trial), fault: "none")
        let trialService = SNESStartupTrialService(wait: {})
        let startedResult = try await trialService.capture(trial: trial, io: trialIO)
        let startedReceipt = try await store.saveSNESStartupTrialStartedWithReceipt(startedResult, trial: trial)
        let playedResult = try await trialService.capture(trial: trial, started: startedResult, io: trialIO)
        let playedReceipt = try await store.saveSNESStartupTrialPlayedWithReceipt(playedResult, trial: trial, started: startedReceipt)
        func receipt(_ kind: SNESSetupRecordReceipt.Kind, _ path: String) throws -> SNESSetupRecordReceipt {
            let url = URL(fileURLWithPath: path)
            return SNESSetupRecordReceipt(kind: kind, directory: url, manifestSHA256: BackupManifest.digest(try Data(contentsOf: url.appendingPathComponent("manifest.json"))))
        }
        let verified = try SNESFirmwareVerifiedInputs(
            backup: receipt(.backup, base.source.source.directoryURL.path), helpers: helperDirectory,
            candidate: receipt(.candidate, base.paths.candidate), helpersManifestSHA256: helpers.manifestSHA256,
            preflight: preflightReceipt, started: startedReceipt, played: playedReceipt,
            active: receipt(.activeBoot2, base.paths.original), currentData: fresh)
        let material = try SNESFirmwareMaterial.install(verified: verified, recovery: recovery)
        let checked = try SNESDataSnapshotPackage.load(receipt: fresh, source: material.source)
        #expect(checked.sha256 != material.trial.candidate.backup.sha256)
        let guardValue = try SNESFirmwareGuard.prepare(material, verified: verified)
        try guardValue.requireVerifiedInputs(verified, material: material)
        let review = try SNESFirstInstallOfflineReview(startupPlanSHA256: BackupManifest.digest(material.planData()), dataDirectory: checked.directory,
            dataManifestSHA256: fresh.manifestSHA256, dataSHA256: checked.sha256, dataBytes: checked.byteCount)
        #expect(try review.digest().count == 64)
        let saved = try await store.saveSNESFirstInstallReview(review, startupPlan: material.planData())
        let discovered = try SNESFirstInstallReviewReceipt.inspect(directory: saved.directory)
        #expect(discovered.sha256 == saved.sha256)
        let reopened = try SNESFirstInstallReviewMaterial.load(receipt: saved, recovery: recovery)
        #expect(reopened.startupID == material.id)
        #expect(reopened.data.sha256 == checked.sha256)
        #expect(reopened.candidateBackupSHA256 == candidate.backup.sha256)
        try reopened.revalidate()
        let reviewed = try reopened.reviewedInstallMaterial()
        let ownerGuard=try SNESFirmwareGuard.prepare(reviewed)
        // A competing operation between the startup checks and data hash must
        // invalidate the owner, even if no I/O call is currently in flight.
        let ownerRoot=root.appendingPathComponent("reviewed-session-owner")
        try FileManager.default.createDirectory(at:ownerRoot,withIntermediateDirectories:false)
        let ownerPlan=try SNESFirmwareJournal.prepare(material:reviewed,root:ownerRoot)
        let ownerJournal=try SNESFirmwareJournal(operation:ownerPlan.operation,reviewSHA256:ownerPlan.reviewSHA256,material:reviewed,guard:ownerGuard)
        let ownerBase=SNESFirmwareFakeIO(material:reviewed,fault:"none")
        let ownerShell=SNESFirmwareShellFake(material:reviewed,fault:"none",reviewedHash:checked.sha256)
        let ownerNative=try NativeSNESFirmwareIO(material:reviewed,guard:ownerGuard,base:ownerBase,shell:ownerShell,testLibraryRoot:root)
        let pause=SNESReviewedSessionProgressPause()
        let ownerTask=Task {
            try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:ownerJournal,guard:ownerGuard,inputs:recovery,io:ownerNative,progress:{stage in
                if stage == .readingBootloader {await pause.hold()}
            })
        }
        let progressDeadline=ContinuousClock.now.advanced(by:.seconds(120))
        while !(await pause.waiting) && ContinuousClock.now < progressDeadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(50))}
        guard await pause.waiting else {
            ownerTask.cancel();await pause.release();_=try? await ownerTask.value
            try? await ownerJournal.close();Issue.record("The owner did not reach the between-I/O barrier");return
        }
        let competingRejected:Bool
        do { _=try await ownerNative.inventory();competingRejected=false } catch {competingRejected=true}
        await pause.release()
        let ownerRejected:Bool
        do { _=try await ownerTask.value;ownerRejected=false } catch {ownerRejected=true}
        try #require(competingRejected && ownerRejected)
        #expect(await ownerShell.hashLimits == nil)
        #expect(await ownerShell.writeCalls == 0)
        #expect(try await ownerJournal.phase() == .prepared)
        try await ownerJournal.close()
        // A competing write attempt must revoke ownership even when its
        // permit belongs to a different operation and cannot be used.
        let foreignRoot=root.appendingPathComponent("foreign-permit")
        try FileManager.default.createDirectory(at:foreignRoot,withIntermediateDirectories:false)
        let foreignGuard=try SNESFirmwareGuard.prepare(material)
        let foreignPlan=try SNESFirmwareJournal.prepare(material:material,root:foreignRoot,guard:foreignGuard)
        let foreignJournal=try SNESFirmwareJournal(operation:foreignPlan.operation,reviewSHA256:foreignPlan.reviewSHA256,material:material,guard:foreignGuard)
        try await foreignJournal.preflightVerified()
        let foreignPermit=try await foreignJournal.beginWrite()
        let replaceRoot=root.appendingPathComponent("reviewed-session-replace-owner")
        try FileManager.default.createDirectory(at:replaceRoot,withIntermediateDirectories:false)
        let replacePlan=try SNESFirmwareJournal.prepare(material:reviewed,root:replaceRoot)
        let replaceJournal=try SNESFirmwareJournal(operation:replacePlan.operation,reviewSHA256:replacePlan.reviewSHA256,material:reviewed,guard:ownerGuard)
        let replaceBase=SNESFirmwareFakeIO(material:reviewed,fault:"none")
        let replaceShell=SNESFirmwareShellFake(material:reviewed,fault:"none",reviewedHash:checked.sha256)
        let replaceNative=try NativeSNESFirmwareIO(material:reviewed,guard:ownerGuard,base:replaceBase,shell:replaceShell,testLibraryRoot:root)
        let replacePause=SNESReviewedSessionProgressPause()
        let replaceTask=Task {
            try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:replaceJournal,guard:ownerGuard,inputs:recovery,io:replaceNative,progress:{stage in
                if stage == .readingBootloader {await replacePause.hold()}
            })
        }
        let replaceDeadline=ContinuousClock.now.advanced(by:.seconds(120))
        while !(await replacePause.waiting) && ContinuousClock.now < replaceDeadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(50))}
        guard await replacePause.waiting else {
            replaceTask.cancel();await replacePause.release();_=try? await replaceTask.value
            try? await replaceJournal.close();try? await foreignJournal.close();Issue.record("The write-attempt barrier did not start");return
        }
        let competingWriteRejected:Bool
        do {try await replaceNative.replace(foreignPermit);competingWriteRejected=false} catch {competingWriteRejected=true}
        await replacePause.release()
        let replaceOwnerRejected:Bool
        do {_=try await replaceTask.value;replaceOwnerRejected=false} catch {replaceOwnerRejected=true}
        try #require(competingWriteRejected && replaceOwnerRejected)
        #expect(await replaceShell.writeCalls == 0)
        #expect(try await replaceJournal.phase() == .prepared)
        try await replaceJournal.close();try await foreignJournal.close()
        // Competition after proof verification but before the intentional
        // close must also prevent the transaction from reporting success.
        let closingRoot=root.appendingPathComponent("reviewed-session-close-owner")
        try FileManager.default.createDirectory(at:closingRoot,withIntermediateDirectories:false)
        let closingPlan=try SNESFirmwareJournal.prepare(material:reviewed,root:closingRoot)
        let closingJournal=try SNESFirmwareJournal(operation:closingPlan.operation,reviewSHA256:closingPlan.reviewSHA256,material:reviewed,guard:ownerGuard)
        let closingBase=SNESFirmwareFakeIO(material:reviewed,fault:"none")
        let closingShell=SNESFirmwareShellFake(material:reviewed,fault:"none",reviewedHash:checked.sha256)
        let closingNative=try NativeSNESFirmwareIO(material:reviewed,guard:ownerGuard,base:closingBase,shell:closingShell,testLibraryRoot:root)
        let closingPause=SNESReviewedSessionProgressPause()
        let closingTask=Task {
            try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:closingJournal,guard:ownerGuard,inputs:recovery,io:closingNative,progress:{stage in
                if stage == .closing {await closingPause.hold()}
            })
        }
        let closingDeadline=ContinuousClock.now.advanced(by:.seconds(120))
        while !(await closingPause.waiting) && ContinuousClock.now < closingDeadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(50))}
        guard await closingPause.waiting else {
            closingTask.cancel();await closingPause.release();_=try? await closingTask.value
            try? await closingJournal.close();Issue.record("The close barrier did not start");return
        }
        let closingCompetingRejected:Bool
        do {_=try await closingNative.inventory();closingCompetingRejected=false} catch {closingCompetingRejected=true}
        await closingPause.release()
        let closingOwnerRejected:Bool
        do {_=try await closingTask.value;closingOwnerRejected=false} catch {closingOwnerRejected=true}
        try #require(closingCompetingRejected && closingOwnerRejected)
        #expect(try await closingJournal.phase() == .prepared)
        try await closingJournal.close()
        // The newer reviewed backup must still match after a slow disconnect.
        let changedCloseRoot=root.appendingPathComponent("reviewed-session-close-changed")
        try FileManager.default.createDirectory(at:changedCloseRoot,withIntermediateDirectories:false)
        let changedClosePlan=try SNESFirmwareJournal.prepare(material:reviewed,root:changedCloseRoot)
        let changedCloseJournal=try SNESFirmwareJournal(operation:changedClosePlan.operation,reviewSHA256:changedClosePlan.reviewSHA256,material:reviewed,guard:ownerGuard)
        let changedCloseBase=SNESFirmwareFakeIO(material:reviewed,fault:"none")
        let changedCloseShell=SNESFirmwareShellFake(material:reviewed,fault:"none",reviewedHash:checked.sha256)
        let changedCloseNative=try NativeSNESFirmwareIO(material:reviewed,guard:ownerGuard,base:changedCloseBase,shell:changedCloseShell,testLibraryRoot:root)
        let changedCloseFile=data.appendingPathComponent(last),unchangedCloseBytes=try Data(contentsOf:changedCloseFile)
        await changedCloseBase.holdNextDisconnect()
        let changedCloseTask=Task {try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:changedCloseJournal,guard:ownerGuard,inputs:recovery,io:changedCloseNative)}
        let changedCloseDeadline=ContinuousClock.now.advanced(by:.seconds(180))
        while !(await changedCloseBase.disconnectWaiting) && ContinuousClock.now < changedCloseDeadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(50))}
        guard await changedCloseBase.disconnectWaiting else {
            changedCloseTask.cancel();await changedCloseBase.releaseDisconnect();_=try? await changedCloseTask.value
            try? await changedCloseJournal.close();Issue.record("The held disconnect did not start");return
        }
        var changedCloseBytes=unchangedCloseBytes;changedCloseBytes[changedCloseBytes.count-1] ^= 1
        do {try changedCloseBytes.write(to:changedCloseFile)} catch {
            await changedCloseBase.releaseDisconnect();_=try? await changedCloseTask.value
            try? unchangedCloseBytes.write(to:changedCloseFile);try? await changedCloseJournal.close();throw error
        }
        await changedCloseBase.releaseDisconnect()
        let changedCloseRejected:Bool
        do {_=try await changedCloseTask.value;changedCloseRejected=false} catch {changedCloseRejected=true}
        try unchangedCloseBytes.write(to:changedCloseFile)
        try #require(changedCloseRejected)
        #expect(try await changedCloseJournal.phase() == .prepared)
        try await changedCloseJournal.close()
        // A source change while the journal finishes must not be reported as
        // a successful comparison after the final disconnect.
        let finishRoot=root.appendingPathComponent("reviewed-session-finish-changed")
        try FileManager.default.createDirectory(at:finishRoot,withIntermediateDirectories:false)
        let finishPlan=try SNESFirmwareJournal.prepare(material:reviewed,root:finishRoot)
        let finishFlags=OSAllocatedUnfairLock(initialState:(armed:false,waiting:false))
        let finishRelease=DispatchSemaphore(value:0)
        let finishJournal=try SNESFirmwareJournal(operation:finishPlan.operation,reviewSHA256:finishPlan.reviewSHA256,material:reviewed,guard:ownerGuard,afterRecordRead:{
            let pause=finishFlags.withLock { value in
                if value.armed {value.armed=false;value.waiting=true;return true};return false
            }
            if pause {finishRelease.wait()}
        })
        let finishBase=SNESFirmwareFakeIO(material:reviewed,fault:"none")
        let finishShell=SNESFirmwareShellFake(material:reviewed,fault:"none",reviewedHash:checked.sha256)
        let finishNative=try NativeSNESFirmwareIO(material:reviewed,guard:ownerGuard,base:finishBase,shell:finishShell,testLibraryRoot:root)
        let finishFile=data.appendingPathComponent(last),unchangedFinishBytes=try Data(contentsOf:finishFile)
        let finishTask=Task {try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:finishJournal,guard:ownerGuard,inputs:recovery,io:finishNative,progress:{stage in
            if stage == .closing {finishFlags.withLock {$0.armed=true}}
        })}
        let finishDeadline=ContinuousClock.now.advanced(by:.seconds(180))
        while !finishFlags.withLock({$0.waiting}) && ContinuousClock.now < finishDeadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(50))}
        guard finishFlags.withLock({$0.waiting}) else {
            finishTask.cancel();finishRelease.signal();_=try? await finishTask.value
            try? await finishJournal.close();Issue.record("The journal finish barrier did not start");return
        }
        var changedFinishBytes=unchangedFinishBytes;changedFinishBytes[changedFinishBytes.count-1] ^= 1
        do {try changedFinishBytes.write(to:finishFile)} catch {
            finishRelease.signal();_=try? await finishTask.value
            try? unchangedFinishBytes.write(to:finishFile);try? await finishJournal.close();throw error
        }
        finishRelease.signal()
        let finishRejected:Bool
        do {_=try await finishTask.value;finishRejected=false} catch {finishRejected=true}
        try unchangedFinishBytes.write(to:finishFile)
        try #require(finishRejected)
        #expect(try await finishJournal.phase() == .prepared)
        try await finishJournal.close()
        let planBytes = try reviewed.planData()
        let plan = try JSONDecoder().decode(SNESFirmwarePlan.self, from: planBytes)
        #expect(plan.schemaVersion == 3)
        #expect(plan.firstInstall?.reviewSHA256 == saved.sha256)
        #expect(plan.firstInstall?.startupPlanData == (try material.planData()))
        #expect(plan.firstInstall?.dataSHA256 == checked.sha256)
        #expect(plan.firstInstall?.dataManifestSHA256 == fresh.manifestSHA256)
        #expect(plan.firstInstall?.dataBytes == checked.byteCount)
        #expect(plan.firstInstall?.requiresPreparationMarker == true)
        #expect(try material.planData() != planBytes)
        let interruptedRoot = root.appendingPathComponent("interrupted-firmware")
        try FileManager.default.createDirectory(at: interruptedRoot, withIntermediateDirectories: false)
        let tailURL = data.appendingPathComponent(last), originalTail = try Data(contentsOf: tailURL)
        var alteredTail = originalTail;alteredTail[alteredTail.count-1] ^= 1
        let altered = alteredTail
        let syncCalls = OSAllocatedUnfairLock(initialState: 0)
        let sync: @Sendable (Int32) -> Int32 = { fd in
            let count=syncCalls.withLock { value in value += 1;return value }
            if count==9 {do {try altered.write(to:tailURL)} catch {return -1}}
            return Darwin.fsync(fd)
        }
        #expect(throws: SNESFirmwarePublicationUncertainError.self) {
            try SNESFirmwareJournal.prepare(material:reviewed,root:interruptedRoot,synchronize:sync)
        }
        let interrupted = interruptedRoot.appendingPathComponent("SNESFirmware-"+reviewed.id.uuidString)
        #expect(FileManager.default.fileExists(atPath:interrupted.appendingPathComponent("preparation.pending").path))
        try originalTail.write(to:tailURL)
        await #expect(throws: (any Error).self) {
            try await SNESFirmwareJournal.reopen(operation:interrupted,reviewSHA256:BackupManifest.digest(planBytes),recovery:recovery)
        }
        #expect(throws: (any Error).self) {
            try SNESFirmwareJournal.validateSiblingHistory(root:interruptedRoot,excluding:UUID(),recoveryParent:nil)
        }
        let lateRoot=root.appendingPathComponent("late-firmware")
        try FileManager.default.createDirectory(at:lateRoot,withIntermediateDirectories:false)
        let lateCalls=OSAllocatedUnfairLock(initialState:0)
        let lateSync:@Sendable (Int32)->Int32 = {fd in
            let count=lateCalls.withLock {value in value += 1;return value}
            if count==11 {do {try altered.write(to:tailURL)} catch {return -1}}
            return Darwin.fsync(fd)
        }
        #expect(throws:SNESFirmwarePublicationUncertainError.self) {
            try SNESFirmwareJournal.prepare(material:reviewed,root:lateRoot,synchronize:lateSync)
        }
        let late=lateRoot.appendingPathComponent("SNESFirmware-"+reviewed.id.uuidString)
        #expect(FileManager.default.fileExists(atPath:late.appendingPathComponent("preparation.complete").path))
        try originalTail.write(to:tailURL)
        let lateJournal=try await SNESFirmwareJournal.reopen(operation:late,reviewSHA256:BackupManifest.digest(planBytes),recovery:recovery)
        await #expect(throws:(any Error).self) {try await lateJournal.preflightVerified()}
        await #expect(throws:(any Error).self) {try await lateJournal.beginWrite()}
        try await lateJournal.close()
        let journals = root.appendingPathComponent("firmware-journals")
        try FileManager.default.createDirectory(at: journals, withIntermediateDirectories: false)
        let prepared = try SNESFirmwareJournal.prepare(material: reviewed, root: journals)
        let record = prepared.operation.appendingPathComponent("0000.json")
        let marker = prepared.operation.appendingPathComponent("preparation.complete")
        let originalRecord = try Data(contentsOf: record), originalMarker = try Data(contentsOf: marker)
        var downgraded = try #require(JSONSerialization.jsonObject(with: originalRecord) as? [String:Any])
        downgraded.removeValue(forKey: "markerRequired")
        try JSONSerialization.data(withJSONObject: downgraded, options: [.sortedKeys,.prettyPrinted]).write(to: record)
        try FileManager.default.removeItem(at: marker)
        await #expect(throws: (any Error).self) {
            try await SNESFirmwareJournal.reopen(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, recovery: recovery)
        }
        try originalRecord.write(to: record);try originalMarker.write(to: marker)
        let journal = try SNESFirmwareJournal(operation: prepared.operation, reviewSHA256: prepared.reviewSHA256, material: reviewed)
        let legacyIO=SNESFirmwareFakeIO(material:reviewed,fault:"none")
        let reviewedGuard=try SNESFirmwareGuard.prepare(reviewed)
        await #expect(throws: (any Error).self) {
            try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:journal,guard:reviewedGuard,inputs:recovery,io:legacyIO)
        }
        #expect(await legacyIO.base.events.isEmpty)
        #expect(try await journal.phase() == .prepared)
        await #expect(throws: (any Error).self) { try await journal.preflightVerified() }
        await #expect(throws: (any Error).self) { try await journal.beginWrite() }
        try await journal.close()
        let diagnosticCalls=OSAllocatedUnfairLock(initialState:(host:0,io:0))
        await #expect(throws:(any Error).self) {
            try await SNESFirmwareDiagnostic.runIfPresent(["--preflight-snes-firmware",prepared.operation.path,prepared.reviewSHA256],
                loadInputs:{recovery},requireOperation:{_ in},
                checkHost:{diagnosticCalls.withLock {$0.host += 1}},
                makeIO:{_,_ in diagnosticCalls.withLock {$0.io += 1};return legacyIO},detail:{_ in})
        }
        #expect(diagnosticCalls.withLock {$0.host == 0 && $0.io == 0})
        // Exercise the real Native wrapper and transaction with a fake console.
        // This read-only preflight must compare the selected newer backup during
        // the recovery session; it must never dispatch the firmware writer.
        let preflightRoot=root.appendingPathComponent("reviewed-preflight")
        try FileManager.default.createDirectory(at:preflightRoot,withIntermediateDirectories:false)
        let preflightPlan=try SNESFirmwareJournal.prepare(material:reviewed,root:preflightRoot)
        let preflightJournal=try SNESFirmwareJournal(operation:preflightPlan.operation,reviewSHA256:preflightPlan.reviewSHA256,material:reviewed,guard:reviewedGuard)
        let preflightBase=SNESFirmwareFakeIO(material:reviewed,fault:"none")
        let preflightShell=SNESFirmwareShellFake(material:reviewed,fault:"none",reviewedHash:checked.sha256)
        let preflightNative=try NativeSNESFirmwareIO(material:reviewed,guard:reviewedGuard,base:preflightBase,shell:preflightShell,testLibraryRoot:root)
        _=try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:preflightJournal,guard:reviewedGuard,inputs:recovery,io:preflightNative)
        // A read-only match is not durable permission for a later write.
        try #require(try await preflightJournal.phase() == .prepared)
        #expect(await preflightShell.writeCalls == 0)
        #expect(await preflightShell.hashLimits != nil)
        await #expect(throws:(any Error).self) {try await preflightJournal.beginWrite()}
        try await preflightJournal.close()
        let preflightReopened=try await SNESFirmwareJournal.reopen(operation:preflightPlan.operation,reviewSHA256:preflightPlan.reviewSHA256,recovery:recovery)
        #expect(try await preflightReopened.phase() == .prepared)
        await #expect(throws:(any Error).self) {try await preflightReopened.beginWrite()}
        try await preflightReopened.close()
        let mismatchRoot=root.appendingPathComponent("reviewed-preflight-mismatch")
        try FileManager.default.createDirectory(at:mismatchRoot,withIntermediateDirectories:false)
        let mismatchPlan=try SNESFirmwareJournal.prepare(material:reviewed,root:mismatchRoot)
        let mismatchJournal=try SNESFirmwareJournal(operation:mismatchPlan.operation,reviewSHA256:mismatchPlan.reviewSHA256,material:reviewed,guard:reviewedGuard)
        let mismatchBase=SNESFirmwareFakeIO(material:reviewed,fault:"none")
        let mismatchShell=SNESFirmwareShellFake(material:reviewed,fault:"none",reviewedHash:String(repeating:"0",count:64))
        let mismatchNative=try NativeSNESFirmwareIO(material:reviewed,guard:reviewedGuard,base:mismatchBase,shell:mismatchShell,testLibraryRoot:root)
        await #expect(throws:(any Error).self) {
            try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:mismatchJournal,guard:reviewedGuard,inputs:recovery,io:mismatchNative)
        }
        let mismatchLimits=await mismatchShell.hashLimits,mismatchWrites=await mismatchShell.writeCalls
        #expect(mismatchLimits != nil && mismatchWrites == 0)
        #expect(try await mismatchJournal.phase() == .prepared)
        try await mismatchJournal.close()
        let competingRoot=root.appendingPathComponent("reviewed-preflight-competing")
        try FileManager.default.createDirectory(at:competingRoot,withIntermediateDirectories:false)
        let competingPlan=try SNESFirmwareJournal.prepare(material:reviewed,root:competingRoot)
        let competingJournal=try SNESFirmwareJournal(operation:competingPlan.operation,reviewSHA256:competingPlan.reviewSHA256,material:reviewed,guard:reviewedGuard)
        let competingBase=SNESFirmwareFakeIO(material:reviewed,fault:"none")
        let competingShell=SNESFirmwareShellFake(material:reviewed,fault:"none",reviewedHash:checked.sha256)
        let competingNative=try NativeSNESFirmwareIO(material:reviewed,guard:reviewedGuard,base:competingBase,shell:competingShell,testLibraryRoot:root)
        let secondBase=SNESFirmwareFakeIO(material:reviewed,fault:"none")
        let secondShell=SNESFirmwareShellFake(material:reviewed,fault:"none",reviewedHash:checked.sha256)
        let secondNative=try NativeSNESFirmwareIO(material:reviewed,guard:reviewedGuard,base:secondBase,shell:secondShell,testLibraryRoot:root)
        await competingShell.holdNextHash()
        let observed=SNESObservedFirmwareIO(competingNative)
        let competingTask=Task {try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:competingJournal,guard:reviewedGuard,inputs:recovery,io:observed)}
        let deadline=ContinuousClock.now.advanced(by:.seconds(180))
        while !(await competingShell.hashWaiting) && ContinuousClock.now < deadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(20))}
        guard await competingShell.hashWaiting else {
            competingTask.cancel();await competingShell.releaseHash();_=try? await competingTask.value
            try await competingJournal.close();Issue.record("The live data check did not reach its barrier");return
        }
        // The owner keeps the journal open and unchanged until disconnect.
        await #expect(throws:(any Error).self) {try await competingJournal.close()}
        await #expect(throws:(any Error).self) {try await competingJournal.stoppedBeforeWrite()}
        // A loser given the same I/O must not disconnect the owner's session.
        await #expect(throws:(any Error).self) {
            try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:competingJournal,guard:reviewedGuard,inputs:recovery,io:competingNative)
        }
        #expect(await competingShell.hashWaiting)
        // A different I/O must also be refused before it opens a connection.
        await #expect(throws:(any Error).self) {
            try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:competingJournal,guard:reviewedGuard,inputs:recovery,io:secondNative)
        }
        #expect(await secondBase.base.events.isEmpty)
        await competingBase.holdNextDisconnect()
        await #expect(throws:(any Error).self) {_ = try await competingNative.inventory()}
        // An independent caller begins closing first. The owner must join that
        // close instead of releasing the reservation early.
        let externalClose=Task {await competingNative.disconnect()}
        let closeDeadline=ContinuousClock.now.advanced(by:.seconds(180))
        while !(await competingBase.disconnectWaiting) && ContinuousClock.now < closeDeadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(20))}
        guard await competingBase.disconnectWaiting else {
            competingTask.cancel();await competingShell.releaseHash();await competingBase.releaseDisconnect()
            await externalClose.value;_=try? await competingTask.value
            try await competingJournal.close();Issue.record("The interrupted session did not reach disconnect");return
        }
        await competingShell.releaseHash()
        let ownerDeadline=ContinuousClock.now.advanced(by:.seconds(180))
        while await observed.disconnectCalls == 0 && ContinuousClock.now < ownerDeadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(20))}
        guard await observed.disconnectCalls > 0 else {
            competingTask.cancel();await competingBase.releaseDisconnect();await externalClose.value;_=try? await competingTask.value
            try await competingJournal.close();Issue.record("The owning transaction did not reach disconnect");return
        }
        // Reservation remains held until the first connection has really closed.
        await #expect(throws:(any Error).self) {
            try await SNESFirmwareTransaction(wait:{}).run(mode:.preflight,journal:competingJournal,guard:reviewedGuard,inputs:recovery,io:secondNative)
        }
        #expect(await secondBase.base.events.isEmpty)
        await competingBase.releaseDisconnect();await externalClose.value
        await #expect(throws:(any Error).self) {_ = try await competingTask.value}
        #expect(await competingShell.writeCalls == 0)
        #expect(try await competingJournal.phase() == .prepared)
        try await competingJournal.close()
        // A historical preflight from this fixture explicitly did not match
        // its original backup. A valid-looking draft cannot turn it into proof.
        #expect(!base.trial.evidence.backupMatches)
        let oldBackup = base.trial.candidate.backup
        let uncheckedReview = try SNESFirstInstallOfflineReview(startupPlanSHA256: BackupManifest.digest(base.planData()),
            dataDirectory: oldBackup.directory, dataManifestSHA256: oldBackup.manifestSHA256,
            dataSHA256: oldBackup.sha256, dataBytes: oldBackup.byteCount)
        let uncheckedReceipt = try await store.saveSNESFirstInstallReview(uncheckedReview, startupPlan: base.planData())
        #expect(throws: (any Error).self) { try SNESFirstInstallReviewMaterial.load(receipt: uncheckedReceipt, recovery: recovery) }
        let lastFile = data.appendingPathComponent(last); var changed = try Data(contentsOf: lastFile)
        changed[changed.count - 1] ^= 1; try changed.write(to: lastFile)
        #expect(throws: (any Error).self) { try reviewed.validateReviewedFirstInstall() }
        #expect(throws: (any Error).self) { try guardValue.requireVerifiedInputs(verified, material: material) }
        #expect(throws: (any Error).self) { try reopened.revalidate() }
        // Simulate accepted history in this test-only directory, then remove the
        // newer snapshot. Original startup restoration must remain discoverable.
        var previous=BackupManifest.digest(originalRecord)
        for (index,phase) in ["preflightVerified","writeIntent","readbackVerified","startupVerified","menuAccepted"].enumerated() {
            let entry:[String:Any]=["phase":phase,"planSHA256":prepared.reviewSHA256,"previousSHA256":previous]
            let bytes=try JSONSerialization.data(withJSONObject:entry,options:[.prettyPrinted,.sortedKeys])
            try bytes.write(to:prepared.operation.appendingPathComponent(String(format:"%04d.json",index+1)),options:.withoutOverwriting)
            previous=BackupManifest.digest(bytes)
        }
        try FileManager.default.removeItem(at:data)
        #expect(throws:(any Error).self) {try reviewed.validateReviewedFirstInstall()}
        let history=try await SNESFirmwareJournal.reopen(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,recovery:recovery)
        let restored=try SNESFirmwareMaterial.restore(installed:await history.restorableInstall())
        #expect(restored.direction == .restore && restored.target == material.original.active)
        let menuParent=try await history.menuStartupParent()
        #expect(menuParent.record.operationID == reviewed.id)
        try SNESFirmwareJournal.requireUpgradeParent(menuParent,savedPlan:planBytes,directory:prepared.operation)
        try await history.close()
        let restoreChild=try SNESFirmwareJournal.prepare(material:restored,root:journals)
        let reopenedRestore=try await SNESFirmwareJournal.reopen(operation:restoreChild.operation,reviewSHA256:restoreChild.reviewSHA256,recovery:recovery)
        let restoredMaterial=try await reopenedRestore.verifiedMaterial()
        #expect(restoredMaterial.direction == .restore && restoredMaterial.target == material.original.active)
        #expect(restoredMaterial.preimage == reviewed.target && restoredMaterial.parentOperationID == reviewed.id && restoredMaterial.parentReviewSHA256 == prepared.reviewSHA256)
        try await reopenedRestore.close()
        let references=try SNESFirmwareJournal.acceptedReferences(root:journals,hwid:material.source.source.expectedHWID)
        #expect(references.contains(where:{$0.id == reviewed.id}))

        // Simulate an accepted parent and a restore child written by a JSON
        // encoder with different whitespace. Neither is a console operation.
        let alternateRoot=root.appendingPathComponent("alternate-history")
        try FileManager.default.createDirectory(at:alternateRoot,withIntermediateDirectories:false)
        let alternateParent=alternateRoot.appendingPathComponent(prepared.operation.lastPathComponent)
        try FileManager.default.copyItem(at:prepared.operation,to:alternateParent)
        let alternatePlan=try JSONSerialization.data(withJSONObject:JSONSerialization.jsonObject(with:planBytes),options:[.sortedKeys])
        #expect(alternatePlan != planBytes)
        let alternateDigest=BackupManifest.digest(alternatePlan)
        try alternatePlan.write(to:alternateParent.appendingPathComponent("plan.json"))
        try Data(alternateDigest.utf8).write(to:alternateParent.appendingPathComponent("preparation.complete"))
        let preparedRecord=try JSONSerialization.data(withJSONObject:["phase":"prepared","planSHA256":alternateDigest,"markerRequired":true],options:[.sortedKeys])
        try preparedRecord.write(to:alternateParent.appendingPathComponent("0000.json"))
        var previousAlternate=BackupManifest.digest(preparedRecord)
        for (index,phase) in ["preflightVerified","writeIntent","readbackVerified","startupVerified","menuAccepted"].enumerated() {
            let entry:[String:Any]=["phase":phase,"planSHA256":alternateDigest,"previousSHA256":previousAlternate]
            let bytes=try JSONSerialization.data(withJSONObject:entry,options:[.sortedKeys])
            try bytes.write(to:alternateParent.appendingPathComponent(String(format:"%04d.json",index+1)))
            previousAlternate=BackupManifest.digest(bytes)
        }
        let alternateHistory=try await SNESFirmwareJournal.reopen(operation:alternateParent,reviewSHA256:alternateDigest,recovery:recovery)
        let alternateRestore=try SNESFirmwareMaterial.restore(installed:await alternateHistory.restorableInstall())
        let alternateMenu=try await alternateHistory.menuStartupParent()
        try SNESFirmwareJournal.requireUpgradeParent(alternateMenu,savedPlan:alternatePlan,directory:alternateParent)
        try await alternateHistory.close()
        let alternateChild=try SNESFirmwareJournal.prepare(material:alternateRestore,root:alternateRoot)
        let childPlanURL=alternateChild.operation.appendingPathComponent("plan.json")
        let originalChildPlan=try Data(contentsOf:childPlanURL)
        let childPlan=try JSONSerialization.data(withJSONObject:JSONSerialization.jsonObject(with:originalChildPlan),options:[.sortedKeys])
        #expect(childPlan != originalChildPlan)
        let childDigest=BackupManifest.digest(childPlan)
        try childPlan.write(to:childPlanURL)
        try Data(childDigest.utf8).write(to:alternateChild.operation.appendingPathComponent("preparation.complete"))
        try JSONSerialization.data(withJSONObject:["phase":"prepared","planSHA256":childDigest,"markerRequired":true],options:[.sortedKeys]).write(to:alternateChild.operation.appendingPathComponent("0000.json"))
        let alternateReopened=try await SNESFirmwareJournal.reopen(operation:alternateChild.operation,reviewSHA256:childDigest,recovery:recovery)
        let alternateMaterial=try await alternateReopened.verifiedMaterial()
        #expect(alternateMaterial.direction == .restore && alternateMaterial.parentReviewSHA256 == alternateDigest)
        #expect(try alternateMaterial.planData() == childPlan)
        try await alternateReopened.close()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func buildsExactCompleteInputFromVerifiedOriginalAndTestedCandidate() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),payload=try m.input()
        #expect(m.direction == .install && m.parentReviewSHA256==nil)
        #expect(payload.count==14680088)
        #expect(payload.prefix(24)==m.geometry)
        #expect(payload[24..<7340056]==m.original.active)
        #expect(payload[7340056...]==m.target)
        let count = m.trial.image.count, end = ((count + 131071) / 131072) * 131072
        #expect(m.target.prefix(count)==m.trial.image)
        #expect(m.target[count..<end].allSatisfy{$0==255})
        #expect(m.target[end...]==m.original.active[end...])
        #expect(m.changedUnits.allSatisfy{(0..<(end / 131072)).contains($0)} && !m.changedUnits.isEmpty)
        try m.validateCurrent()
    }
}

private actor SNESReviewedSessionProgressPause {
    private var continuation:CheckedContinuation<Void,Never>?
    var waiting:Bool { continuation != nil }
    func hold() async { await withCheckedContinuation { continuation=$0 } }
    func release() { let value=continuation;continuation=nil;value?.resume() }
}
