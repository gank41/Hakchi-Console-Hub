import Foundation
import Testing
import os
@testable import SwiftHakchi

struct SNESFirmwareDiagnosticTests {
    @Test func preparedReviewMustStillMatchTheSavedReceipt() throws {
        let folder=URL(fileURLWithPath:"/tmp/SNES-First-Install-Review-11111111-1111-1111-1111-111111111111")
        let digest=String(repeating:"a",count:64)
        let summary=SNESFirstInstallReviewSummary(reviewDirectory:folder,dataDirectory:folder,reviewSHA256:digest,changedUnits:1)
        try summary.requireReceipt(.init(directory:folder,sha256:digest))
        #expect(throws:(any Error).self) {try summary.requireReceipt(.init(directory:folder,sha256:String(repeating:"b",count:64)))}
        #expect(throws:(any Error).self) {try summary.requireReceipt(.init(directory:folder.deletingLastPathComponent(),sha256:digest))}
    }
    @Test func interruptedInstallationStatusWarnsAgainstRetrying() {
        for phase: SNESFirmwareJournal.Phase in [.writeIntent, .uncertain] {
            let status = SNESInstallationProgress(phase: phase)
            #expect(status.needsAttention)
            #expect(status.detail.localizedCaseInsensitiveContains("do not try"))
        }
        for phase: SNESFirmwareJournal.Phase in [.readbackVerified, .startupVerified] {
            #expect(SNESInstallationProgress(phase: phase).needsAttention)
        }
        let completed = SNESInstallationProgress(phase: .menuAccepted)
        #expect(!completed.needsAttention)
        #expect(completed.detail.localizedCaseInsensitiveContains("saved"))
    }
    @Test func resumedUpgradeIdentifiesItsParentAndRejectsSubstitution() throws {
        // These URLs denote directories. Give them explicit directory semantics
        // rather than relying on Foundation's filesystem-dependent inference.
        let root=try testDirectory().standardizedFileURL;defer {try? FileManager.default.removeItem(at:root)}
        func operation()->URL {root.appendingPathComponent("SNESFirmware-"+UUID().uuidString,isDirectory:true)}
        let initial=operation(),menu=SNESFirmwareJournal.Prepared(operation:operation(),reviewSHA256:String(repeating:"a",count:64))
        let check=SNESReviewedConsoleCheck(operation:initial,planSHA256:String(repeating:"b",count:64),review:.init(directory:root,sha256:String(repeating:"c",count:64)))
        let direct=SNESFirmwareJournal.Prepared(operation:initial,reviewSHA256:check.planSHA256)
        #expect(try AppState.resolveSNESUpgradeParent(direct, after:check, supplied:nil, root:root) == nil)
        let candidate = try AppState.resolveSNESUpgradeParent(menu, after:check, supplied:nil, root:root)
        let resolved = try #require(candidate)
        #expect(resolved.operation.path==menu.operation.path && resolved.reviewSHA256==menu.reviewSHA256)
        let wrong=SNESFirmwareJournal.Prepared(operation:menu.operation,reviewSHA256:String(repeating:"0",count:64))
        #expect(throws:(any Error).self) {try AppState.resolveSNESUpgradeParent(menu, after:check, supplied:wrong, root:root)}
        let outside=SNESFirmwareJournal.Prepared(operation:root.deletingLastPathComponent().appendingPathComponent("SNESFirmware-"+UUID().uuidString),reviewSHA256:menu.reviewSHA256)
        #expect(throws:(any Error).self) {try AppState.resolveSNESUpgradeParent(outside, after:check, supplied:nil, root:root)}
    }
    @Test @MainActor func appFirstInstallRequiresReadinessAndApprovalBeforeAnyAccess() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let config = AppConfig(); config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: { calls.withLock { $0 += 1 } },
            firmwareJournalRoot: { calls.withLock { $0 += 1 }; return root },
            makeSNESFirmwareIO: { _, _ in calls.withLock { $0 += 1 }; throw SNESRuntimeBinding.failure() })
        app.isPreparingSync = true
        let check = SNESReviewedConsoleCheck(operation: root, planSHA256: String(repeating: "0", count: 64),
            review: .init(directory: root, sha256: String(repeating: "0", count: 64)))
        await #expect(throws: (any Error).self) { try await app.runSNESReviewedInstallation(check, ready: false, approved: true, progress: { _ in }) }
        await #expect(throws: (any Error).self) { try await app.runSNESReviewedInstallation(check, ready: true, approved: false, progress: { _ in }) }
        app.isPreparingSync = false
        await #expect(throws: (any Error).self) { try await app.reopenSNESReviewedInstallation(operation: root, review: check.review) }
        app.isPreparingSync = true
        await #expect(throws: (any Error).self) { try await app.checkSNESReviewedInstallation(check, ready: false) }
        await #expect(throws: (any Error).self) { try await app.acceptSNESReviewedInstallation(check, confirmed: false) }
        await #expect(throws: (any Error).self) { try await app.inspectSNESUncertainInstallation(after: check, ready: false, progress: { _ in }) }
        await #expect(throws: (any Error).self) { try await app.backupSNESReviewedCurrentData(after: check, ready: false, progress: { _ in }) }
        let candidate = SNESSetupRecordReceipt(kind: .candidate, directory: root, manifestSHA256: String(repeating: "0", count: 64))
        await #expect(throws: (any Error).self) { try await app.checkSNESMenuStartup(after: check, candidate: candidate, ready: false, progress: { _ in }) }
        let preflight = SNESStartupPreflightReceipt(record: .init(kind: .preflight, directory: root, manifestSHA256: String(repeating: "0", count: 64)), backupMatches: true)
        await #expect(throws: (any Error).self) { try await app.runSNESMenuStartupTrial(after: check, candidate: candidate, preflight: preflight, ready: false, progress: { _ in }) }
        let started = SNESSetupRecordReceipt(kind: .trialStarted, directory: root, manifestSHA256: String(repeating: "0", count: 64))
        let played = SNESSetupRecordReceipt(kind: .trialPlayed, directory: root, manifestSHA256: String(repeating: "0", count: 64))
        let outdated = SNESStartupPreflightReceipt(record: preflight.record, backupMatches: false)
        do {
            _ = try await app.runSNESMenuStartupTrial(after: check, candidate: candidate, preflight: outdated, ready: true, progress: { _ in })
            Issue.record("An outdated backup was accepted")
        } catch {
            #expect(error.localizedDescription.contains("new backup"))
        }
        do {
            _ = try await app.prepareSNESMenuUpgrade(after: check, candidate: candidate, preflight: outdated, started: started, played: played, confirmed: true)
            Issue.record("An outdated backup was accepted")
        } catch {
            #expect(error.localizedDescription.contains("new backup"))
        }
        await #expect(throws: (any Error).self) { try await app.prepareSNESMenuUpgrade(after: check, candidate: candidate, preflight: preflight, started: started, played: played, confirmed: false) }
        let upgrade = SNESFirmwareJournal.Prepared(operation: root, reviewSHA256: String(repeating: "0", count: 64))
        await #expect(throws: (any Error).self) { try await app.captureSNESReviewedOriginalGames(upgrade, after: check, menu: upgrade, ready: false) }
        app.isPreparingSync = false
        await #expect(throws: (any Error).self) { try await app.reopenSNESMenuUpgrade(operation: root, after: check) }
        app.isPreparingSync = true
        await #expect(throws: (any Error).self) { try await app.prepareSNESLibraryStartup(after: check, menu: upgrade, confirmed: false) }
        await #expect(throws: (any Error).self) { try await app.checkSNESMenuStartup(after: check, menu: upgrade, candidate: candidate, ready: false, progress: { _ in }) }
        await #expect(throws: (any Error).self) { try await app.runSNESMenuStartupTrial(after: check, menu: upgrade, candidate: candidate, preflight: preflight, ready: false, progress: { _ in }) }
        await #expect(throws: (any Error).self) { try await app.runSNESMenuUpgrade(upgrade, after: check, menu: upgrade, mode: .write, ready: true, progress: { _ in }) }
        await #expect(throws: (any Error).self) { try await app.runSNESMenuUpgrade(upgrade, after: check, mode: .preflight, ready: false, progress: { _ in }) }
        await #expect(throws: (any Error).self) { try await app.runSNESMenuUpgrade(upgrade, after: check, mode: .write, ready: true, progress: { _ in }) }
        await #expect(throws: (any Error).self) { try await app.checkSNESMenuUpgrade(upgrade, after: check, ready: false) }
        await #expect(throws: (any Error).self) { try await app.acceptSNESMenuUpgrade(upgrade, after: check, confirmed: false) }
        app.isPreparingSync = false
        await #expect(throws: (any Error).self) { try await app.prepareSNESMenuStartup(after: check) }
        #expect(calls.withLock { $0 } == 0)
    }
    @Test func failedRestoreNeverTreatsAnAmbiguousWriteAsSafeToRetry() {
        let cause = SNESRuntimeBinding.failure()
        for phase: SNESFirmwareJournal.Phase? in [nil, .writeIntent, .uncertain, .readbackVerified] {
            let reported = SNESFirmwareOutcomeFailure.classify(cause, mode: .write, transactionStarted: true, phase: phase)
            #expect(reported is SNESFirmwareTransactionError)
        }
        let beforeWrite = SNESFirmwareOutcomeFailure.classify(cause, mode: .write, transactionStarted: true, phase: .stoppedBeforeWrite)
        #expect(!(beforeWrite is SNESFirmwareTransactionError))
        let neverStarted = SNESFirmwareOutcomeFailure.classify(cause, mode: .write, transactionStarted: false, phase: nil)
        #expect(!(neverStarted is SNESFirmwareTransactionError))
        let checkOnly = SNESFirmwareOutcomeFailure.classify(cause, mode: .preflight, transactionStarted: true, phase: nil)
        #expect(!(checkOnly is SNESFirmwareTransactionError))
    }
    @Test @MainActor func appRestorePreparationRequiresOpenGuide() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let config = AppConfig(); config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: { calls.withLock { $0 += 1 } },
            firmwareJournalRoot: { calls.withLock { $0 += 1 }; return root },
            makeSNESFirmwareIO: { _, _ in calls.withLock { $0 += 1 }; throw SNESRuntimeBinding.failure() })
        await #expect(throws: (any Error).self) { try await app.prepareSNESStartupRestore(operation: root.appendingPathComponent("invalid")) }
        #expect(calls.withLock { $0 } == 0)
        app.isPreparingSync = true
        await #expect(throws: (any Error).self) { try await app.prepareSNESStartupRestore(operation: root.appendingPathComponent("invalid")) }
        #expect(calls.withLock { $0 } == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_LATEST_PARENT"] != nil))
    @MainActor func appRestoresDeepAcceptedStartupUsingSimulatedConsole() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let original = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_LATEST_PARENT"]))
        let operations = root.appendingPathComponent("operations")
        try FileManager.default.createDirectory(at: operations, withIntermediateDirectories: false)
        var current = original
        while true {
            try FileManager.default.copyItem(at: current, to: operations.appendingPathComponent(current.lastPathComponent))
            let plan = try JSONDecoder().decode(SNESFirmwarePlan.self, from: Data(contentsOf: current.appendingPathComponent("plan.json")))
            guard let parent = plan.parentOperationID else { break }
            current = original.deletingLastPathComponent().appendingPathComponent("SNESFirmware-" + parent.uuidString)
        }
        let copied = operations.appendingPathComponent(original.lastPathComponent)
        let hostCalls = OSAllocatedUnfairLock(initialState: 0)
        let devices = OSAllocatedUnfairLock(initialState: [SNESFirmwareFakeIO]())
        let config = AppConfig(); config.lastConsoleType = .snesUsa; config.workspacePath = root.path; config.backupDirectoryPath = root.path
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: { hostCalls.withLock { $0 += 1 } }, firmwareJournalRoot: { operations },
            makeSNESFirmwareIO: { material, _ in
                let io = SNESFirmwareFakeIO(material: material, fault: "none")
                devices.withLock { $0.append(io) }; return io
            })
        app.isPreparingSync = true
        let restore = try await app.prepareSNESStartupRestore(operation: copied)
        #expect(restore.hasTestedWriter)
        #expect(hostCalls.withLock { $0 } == 0 && devices.withLock { $0.isEmpty })
        await #expect(throws: (any Error).self) {
            try await app.runSNESStartupRestore(restore, mode: .write, ready: true, progress: { _ in })
        }
        #expect(hostCalls.withLock { $0 } == 0 && devices.withLock { $0.isEmpty })
        try await app.runSNESStartupRestore(restore, mode: .preflight, ready: true, progress: { _ in })
        let preflight = try #require(devices.withLock { $0.first })
        #expect(await preflight.writes == 0)
        try await app.runSNESStartupRestore(restore, mode: .write, ready: true, approved: true, progress: { _ in })
        let writer = try #require(devices.withLock { $0.last })
        #expect(await writer.writes == 1)
        #expect(await writer.active == writer.material.original.active)
        #expect(try await app.openSNESStartupRestore(operation: restore.operation).phase == .readbackVerified)
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    @MainActor func appPreparesSavedOriginalStartupWithoutConsoleAccess() async throws {
        let material = try await SNESFirmwareFixtureCache.shared.value()
        let checked = try await SNESFirmwareGuardFixtureCache.shared.value()
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = try SNESFirmwareJournal.prepare(material: material, root: root, guard: checked)
        let journal = try SNESFirmwareJournal(operation: parent.operation, reviewSHA256: parent.reviewSHA256, material: material, guard: checked)
        try await journal.preflightVerified(); _ = try await journal.beginWrite(); try await journal.readbackVerified(); try await journal.close()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let config = AppConfig(); config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: { calls.withLock { $0 += 1 } }, firmwareJournalRoot: { root },
            makeSNESFirmwareIO: { _, _ in calls.withLock { $0 += 1 }; throw SNESRuntimeBinding.failure() })
        app.isPreparingSync = true
        let result = try await app.prepareSNESStartupRestore(operation: parent.operation)
        #expect(calls.withLock { $0 } == 0)
        let pins = try PinnedFELInputs.load(), inputs = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let restored = try await SNESFirmwareJournal.reopen(operation: result.operation, reviewSHA256: result.reviewSHA256, recovery: inputs)
        let restoration = try await restored.verifiedMaterial()
        #expect(restoration.direction == .restore && restoration.target == material.original.active && restoration.preimage == material.target)
        #expect(try await restored.phase() == .prepared)
        try await restored.close()
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    @MainActor func appChecksAndRestoresOnlyAfterReadiness() async throws {
        let material = try await SNESFirmwareFixtureCache.shared.value()
        let checked = try await SNESFirmwareGuardFixtureCache.shared.value()
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let parent = try SNESFirmwareJournal.prepare(material: material, root: root, guard: checked)
        let journal = try SNESFirmwareJournal(operation: parent.operation, reviewSHA256: parent.reviewSHA256, material: material, guard: checked)
        try await journal.preflightVerified(); _ = try await journal.beginWrite(); try await journal.readbackVerified(); try await journal.close()
        let hostCalls = OSAllocatedUnfairLock(initialState: 0)
        let devices = OSAllocatedUnfairLock(initialState: [SNESFirmwareFakeIO]())
        let config = AppConfig(); config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: { hostCalls.withLock { $0 += 1 } }, firmwareJournalRoot: { root },
            makeSNESFirmwareIO: { material, _ in
                let io = SNESFirmwareFakeIO(material: material, fault: "none")
                devices.withLock { $0.append(io) }; return io
            })
        app.isPreparingSync = true
        let restore = try await app.prepareSNESStartupRestore(operation: parent.operation)
        let opened = try await app.openSNESStartupRestore(operation: restore.operation)
        #expect(opened.restore.reviewSHA256 == restore.reviewSHA256 && opened.phase == .prepared)
        await #expect(throws: (any Error).self) {
            try await app.runSNESStartupRestore(restore, mode: .preflight, ready: false, progress: { _ in })
        }
        #expect(hostCalls.withLock { $0 } == 0 && devices.withLock { $0.isEmpty })
        try await app.runSNESStartupRestore(restore, mode: .preflight, ready: true, progress: { _ in })
        #expect(try await app.openSNESStartupRestore(operation: restore.operation).phase == .preflightVerified)
        let first = try #require(devices.withLock { $0.first })
        #expect(await first.writes == 0)
        await #expect(throws: (any Error).self) {
            try await app.runSNESStartupRestore(restore, mode: .write, ready: true, progress: { _ in })
        }
        #expect(hostCalls.withLock { $0 } == 1 && devices.withLock { $0.count } == 1)
        try await app.runSNESStartupRestore(restore, mode: .write, ready: true, approved: true, progress: { _ in })
        let second = try #require(devices.withLock { $0.last })
        #expect(await second.writes == 1)
        #expect(await second.active == material.original.active)
        let pins = try PinnedFELInputs.load(), inputs = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let result = try await SNESFirmwareJournal.reopen(operation: restore.operation, reviewSHA256: restore.reviewSHA256, recovery: inputs)
        #expect(try await result.phase() == .readbackVerified)
        try await result.close()
        #expect(try await app.openSNESStartupRestore(operation: restore.operation).phase == .readbackVerified)
        await #expect(throws: (any Error).self) { try await app.acceptSNESStartupRestore(restore, confirmed: false) }
        try await app.acceptSNESStartupRestore(restore, confirmed: true)
        #expect(try await app.openSNESStartupRestore(operation: restore.operation).phase == .menuAccepted)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_PORTABLE_POSITIVE"] != nil))
    func portableRequestPreparesAndReopensOfflineWithExactHelpers() async throws {
        let existing=try await SNESFirmwareFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let helpers=try await RecoveryBootSnapshotStore(root:root).saveSNESPortableHelpers()
        let request=SNESPortableFirmwareRequest(candidate:existing.paths.candidate,preflight:existing.paths.preflight,
            started:existing.paths.started,played:existing.paths.played,original:existing.paths.original,helpers:helpers.path)
        let path=root.appendingPathComponent("request.json");try JSONEncoder().encode(request).write(to:path)
        let journals=root.appendingPathComponent("journals")
        try FileManager.default.createDirectory(at:journals,withIntermediateDirectories:false)
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let calls=OSAllocatedUnfairLock(initialState:0)
        let output=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--prepare-snes-firmware",path.path],
            loadInputs:{inputs},root:{journals},checkHost:{calls.withLock{$0+=1}},
            makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()}))
        let result=try #require(JSONSerialization.jsonObject(with:Data(output.utf8)) as? [String:Any])
        #expect(result["USBOpened"] as? Bool == false && result["firmwareWritten"] as? Bool == false)
        #expect(calls.withLock{$0}==0)
        let operation=URL(fileURLWithPath:try #require(result["operation"] as? String))
        let review=try #require(result["reviewSHA256"] as? String)
        let journal=try await SNESFirmwareJournal.reopen(operation:operation,reviewSHA256:review,recovery:inputs)
        let material=try await journal.verifiedMaterial()
        #expect(material.reader.digest==SNESPortableHelpers.Version.v1.reader.sha256)
        #expect(material.writer.digest==SNESPortableHelpers.Version.v1.writer.sha256)
        #expect(material.paths.reader==helpers.appendingPathComponent("reader").path)
        #expect(material.paths.writer==helpers.appendingPathComponent("writer").path)
        try await journal.close()
        let legacyRequest=root.appendingPathComponent("legacy-request.json")
        try JSONEncoder().encode(existing.paths).write(to:legacyRequest)
        let legacyJournals=root.appendingPathComponent("legacy-journals")
        try FileManager.default.createDirectory(at:legacyJournals,withIntermediateDirectories:false)
        let legacyOutput=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--prepare-snes-firmware",legacyRequest.path],
            loadInputs:{inputs},root:{legacyJournals},checkHost:{calls.withLock{$0+=1}},
            makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()}))
        let legacyResult=try #require(JSONSerialization.jsonObject(with:Data(legacyOutput.utf8)) as? [String:Any])
        #expect(legacyResult["USBOpened"] as? Bool == false && legacyResult["firmwareWritten"] as? Bool == false)
        #expect(calls.withLock{$0}==0)
        let legacyOperation=URL(fileURLWithPath:try #require(legacyResult["operation"] as? String))
        let legacyReview=try #require(legacyResult["reviewSHA256"] as? String)
        let legacyJournal=try await SNESFirmwareJournal.reopen(operation:legacyOperation,reviewSHA256:legacyReview,recovery:inputs)
        let legacyMaterial=try await legacyJournal.verifiedMaterial()
        #expect(legacyMaterial.reader.digest==existing.reader.digest && legacyMaterial.writer.digest==existing.writer.digest)
        try await legacyJournal.close()
    }
    @Test func validSavedHelperRequestReachesOfflineInputCheckingWithoutOpeningConsole() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let directory=try await RecoveryBootSnapshotStore(root:root).saveSNESPortableHelpers()
        let request=SNESPortableFirmwareRequest(candidate:root.appendingPathComponent("candidate").path,
            preflight:root.appendingPathComponent("preflight").path,started:root.appendingPathComponent("started").path,
            played:root.appendingPathComponent("played").path,original:root.appendingPathComponent("original").path,
            helpers:directory.path)
        let path=root.appendingPathComponent("request.json");try JSONEncoder().encode(request).write(to:path)
        let calls=OSAllocatedUnfairLock(initialState:0),host=OSAllocatedUnfairLock(initialState:0)
        await #expect(throws:(any Error).self) {
            try await SNESFirmwareDiagnostic.runIfPresent(["--prepare-snes-firmware",path.path],
                loadInputs:{calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()},
                checkHost:{host.withLock{$0+=1}},makeIO:{_,_ in host.withLock{$0+=1};throw SNESRuntimeBinding.failure()})
        }
        #expect(calls.withLock{$0}==1 && host.withLock{$0}==0)
    }
    @Test func changedSavedHelpersStopPreparationBeforeRecoveryInputsOrConsoleAccess() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let directory=try await RecoveryBootSnapshotStore(root:root).saveSNESPortableHelpers()
        let portable=SNESPortableFirmwareRequest(candidate:root.appendingPathComponent("candidate").path,
            preflight:root.appendingPathComponent("preflight").path,started:root.appendingPathComponent("started").path,
            played:root.appendingPathComponent("played").path,original:root.appendingPathComponent("original").path,
            helpers:directory.path)
        let request=root.appendingPathComponent("request.json")
        try JSONEncoder().encode(portable).write(to:request)
        try Data([0]).write(to:directory.appendingPathComponent("writer"))
        let calls=OSAllocatedUnfairLock(initialState:0)
        await #expect(throws:(any Error).self) {
            try await SNESFirmwareDiagnostic.runIfPresent(["--prepare-snes-firmware",request.path],
                loadInputs:{calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()},
                root:{calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()},
                checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()})
        }
        #expect(calls.withLock{$0}==0)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["none","early","write"])
    func writeRequiresReviewTokenAndPreservesUncertainState(_ fault:String) async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        if fault != "early" {try await j.preflightVerified()};try await j.close()
        let io=SNESFirmwareFakeIO(material:m,fault:fault),pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let args=["--write-snes-firmware",p.operation.path,p.reviewSHA256,"--confirm-reviewed-write"]
        do {
            let raw=try #require(try await SNESFirmwareDiagnostic.runIfPresent(args,loadInputs:{inputs},requireOperation:{_ in},checkHost:{},makeIO:{_,_ in io},detail:{_ in}))
            let result=try #require(JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any])
            #expect(fault=="none" && result["phase"] as? String=="readbackVerified")
        } catch {#expect(fault != "none")}
        let reopened=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        #expect(try await reopened.phase()==(fault=="none" ? .readbackVerified:fault=="early" ? .prepared:.uncertain))
        #expect(await io.writes==(fault=="early" ? 0:1))
        await #expect(throws:(any Error).self){try await reopened.beginWrite()}
        try await reopened.close()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func acceptanceRequiresStartupThenBuildsOriginalRestoreWithoutUSB() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        try await j.preflightVerified();_=try await j.beginWrite();try await j.readbackVerified();try await j.close()
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage),calls=OSAllocatedUnfairLock(initialState:0)
        let accept=["--accept-snes-firmware",p.operation.path,p.reviewSHA256,"--confirm-menu-and-gameplay"]
        await #expect(throws:(any Error).self){try await SNESFirmwareDiagnostic.runIfPresent(accept,loadInputs:{inputs},requireOperation:{_ in},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()},detail:{_ in})}
        let startup=StartupTrialSessionFake(expected:try .checked(m.trial),fault:"none",booted:true)
        let checked=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--check-snes-installed-startup",p.operation.path,p.reviewSHA256],loadInputs:{inputs},requireOperation:{_ in},checkHost:{},makeStartupIO:{_ in startup}))
        #expect(checked.contains("startupVerified"))
        _=try #require(try await SNESFirmwareDiagnostic.runIfPresent(accept,loadInputs:{inputs},requireOperation:{_ in},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()}))
        let raw=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--prepare-snes-stock-restore",p.operation.path,p.reviewSHA256],loadInputs:{inputs},requireOperation:{_ in},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()}))
        let result=try #require(JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any]),operation=try #require(result["operation"] as? String),review=try #require(result["reviewSHA256"] as? String)
        #expect(result["USBOpened"] as? Bool==false && result["firmwareWritten"] as? Bool==false)
        #expect(calls.withLock{$0}==0)
        let restore=try await SNESFirmwareJournal.reopen(operation:URL(fileURLWithPath:operation),reviewSHA256:review,recovery:inputs)
        let material=try await restore.verifiedMaterial()
        #expect(material.direction == .restore && material.target==m.original.active && material.preimage==m.target)
        try await restore.close()
    }
    @Test func retainsBoundedPrivateFailureCause() {
        let failure=SNESFirmwareCommandFailure(transport:-43,exit:19,output:Data("partial".utf8),errors:Data("driver refused".utf8))
        let detail=SNESFirmwareDiagnostic.failureDetail(failure)
        #expect(detail.contains("-43") && detail.contains("19"))
        #expect(!detail.isEmpty && detail.utf8.count<=16384)
    }

    @Test(arguments:[["--prepare-snes-firmware"],["--prepare-snes-firmware","relative"],["--write-snes-firmware","/tmp/anything",String(repeating:"0",count:64)],["--accept-snes-firmware","/tmp/anything",String(repeating:"0",count:64)],["--inspect-snes-firmware"],["--check-snes-installed-startup","relative",String(repeating:"0",count:64)],["--preflight-snes-firmware","/tmp/anything","bad"],["--preflight-snes-firmware","/tmp/anything",String(repeating:"0",count:64),"extra"]])
    func rejectsInvalidRequestsBeforeDependencies(_ args:[String]) async {
        let calls=OSAllocatedUnfairLock(initialState:0)
        await #expect(throws:(any Error).self){try await SNESFirmwareDiagnostic.runIfPresent(args,loadInputs:{calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()},root:{calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()},requireOperation:{_ in calls.withLock{$0+=1}},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()})}
        #expect(calls.withLock{$0}==0)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func refusesOversizedPreparationAndPreflightsOriginalRestore() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),root=try testDirectory(),request=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:request)}
        let path=request.appendingPathComponent("request.json");try JSONEncoder().encode(m.paths).write(to:path)
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let calls=OSAllocatedUnfairLock(initialState:0)
        if m.trial.image.count > 4*1024*1024 {
            await #expect(throws:(any Error).self) {try await SNESFirmwareDiagnostic.runIfPresent(["--prepare-snes-firmware",path.path],loadInputs:{inputs},root:{root},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()})}
        } else {
            // This private fixture can be a normal-size historical image; still
            // exercise the size boundary without treating it as oversized.
            #expect(throws:(any Error).self) {try SNESColdBootPolicy.require(boot1:m.source.boot1,imageByteCount:4*1024*1024+1)}
        }
        #expect(calls.withLock{$0}==0)
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
        // A historically installed oversized image must still be restorable to its original bytes.
        let g=try await SNESFirmwareGuardFixtureCache.shared.value()
        let parentPrepared=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g)
        let parent=try SNESFirmwareJournal(operation:parentPrepared.operation,reviewSHA256:parentPrepared.reviewSHA256,material:m,guard:g)
        try await parent.preflightVerified();_=try await parent.beginWrite();try await parent.readbackVerified();try await parent.close()
        let raw=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--prepare-snes-stock-restore",parentPrepared.operation.path,parentPrepared.reviewSHA256],loadInputs:{inputs},requireOperation:{_ in},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()}))
        #expect(calls.withLock{$0}==0)
        let result=try #require(try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any])
        let operation=try #require(result["operation"] as? String),review=try #require(result["reviewSHA256"] as? String)
        let output=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--preflight-snes-firmware",operation,review],loadInputs:{inputs},requireOperation:{url in #expect(url.deletingLastPathComponent().path==root.path)},checkHost:{calls.withLock{$0+=1}},makeIO:{material,_ in SNESFirmwareFakeIO(material:material,fault:"none")}))
        let checked=try #require(try JSONSerialization.jsonObject(with:Data(output.utf8)) as? [String:Any])
        #expect(checked["firmwareWritten"] as? Bool == false)
        #expect(checked["phase"] as? String == "preflightVerified")
        #expect(calls.withLock{$0}==1)
    }
}
