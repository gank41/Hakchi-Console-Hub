import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

@Suite(.serialized) struct SNESLibraryStartupCandidateTests {
    private static let cleanMaskLiteral = #"test "$mcp_sigblk" = 0000000000000000"#
    @Test func firmwareInstallRefusesRAMOnlyAndUnknownRecipes() throws {
        try SNESFirmwareMaterial.requireInstallableRecipe(10)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(11) }
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(12) }
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(13) }
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(14) }
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(15) }
    }
    @Test func parallelTrialOnlyUpgradesTheCurrentInstalledRecipe() {
        #expect(SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 10, to: 11))
        #expect(!SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 9, to: 11))
        #expect(!SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 11, to: 11))
        #expect(SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 10, to: 12))
        #expect(!SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 9, to: 12))
        #expect(!SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 11, to: 12))
        #expect(!SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 12, to: 12))
        #expect(SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 10, to: 13))
        for previous in [9, 11, 12, 13] { #expect(!SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: previous, to: 13)) }
        #expect(SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 10, to: 14))
        for previous in [9, 11, 12, 13, 14] { #expect(!SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: previous, to: 14)) }
        #expect(!SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 10, to: 15))
        #expect(SNESStartupAdapterCandidate.allowsLibraryUpgrade(from: 4, to: 10))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SNES_PARALLEL_CANDIDATE"] != nil))
    func ramCandidateOnlyChangesTheVerifierAndItsIntegrityRecords() throws {
        let env = ProcessInfo.processInfo.environment
        let old = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_PARALLEL_OLD"])))
        let candidate = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_PARALLEL_CANDIDATE"])))
        #expect(old.libraryRecipeVersion == 10 && candidate.libraryRecipeVersion == 11)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(candidate.libraryRecipeVersion) }
        let before = try LegacyBootImageBuilder.inspect(old.image), after = try LegacyBootImageBuilder.inspect(candidate.image)
        #expect(before.kernel == after.kernel)
        #expect(before.header[64..<576] == after.header[64..<576])
        let a = Dictionary(uniqueKeysWithValues: before.archive.entries.map { ($0.name, $0.data) })
        let b = Dictionary(uniqueKeysWithValues: after.archive.entries.map { ($0.name, $0.data) })
        #expect(Set(a.keys) == Set(b.keys))
        let changed = Set(a.keys.filter { a[$0] != b[$0] })
        #expect(changed == Set(["swifthakchi/library-selector", "swifthakchi/runtime-files.sha256", "swifthakchi/files.sha256"]))
        #expect(b["swifthakchi/library-selector"] == Data(try SNESLibraryStartupScripts.parallelChecksumVerifierCandidate().utf8))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SNES_COMBINED_CANDIDATE"] != nil))
    func combinedRAMCandidateOnlyChangesTheVerifierAndItsIntegrityRecords() throws {
        let env = ProcessInfo.processInfo.environment
        let old = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_COMBINED_OLD"])))
        let candidate = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_COMBINED_CANDIDATE"])))
        #expect(old.libraryRecipeVersion == 10 && candidate.libraryRecipeVersion == 12)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(candidate.libraryRecipeVersion) }
        let before = try LegacyBootImageBuilder.inspect(old.image), after = try LegacyBootImageBuilder.inspect(candidate.image)
        #expect(before.kernel == after.kernel)
        #expect(before.header[64..<576] == after.header[64..<576])
        let a = Dictionary(uniqueKeysWithValues: before.archive.entries.map { ($0.name, $0.data) })
        let b = Dictionary(uniqueKeysWithValues: after.archive.entries.map { ($0.name, $0.data) })
        #expect(Set(a.keys) == Set(b.keys))
        #expect(Set(a.keys.filter { a[$0] != b[$0] }) == Set(["swifthakchi/library-selector", "swifthakchi/runtime-files.sha256", "swifthakchi/files.sha256"]))
        #expect(b["swifthakchi/library-selector"] == Data(try SNESLibraryStartupScripts.combinedStatVerifierCandidate().utf8))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SNES_COMBINED_PREPARE_ROOT"] != nil))
    func prepareCombinedCandidateFromSavedStartupWithoutOpeningConsole() async throws {
        let env = ProcessInfo.processInfo.environment
        let old = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_COMBINED_OLD"])))
        #expect(old.libraryRecipeVersion == 10)
        let candidate = try SNESStartupAdapterCandidate.withLibrarySupport(old, targetRecipe: 12)
        #expect(candidate.libraryRecipeVersion == 12)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(candidate.libraryRecipeVersion) }
        let store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath: try #require(env["HC_SNES_COMBINED_PREPARE_ROOT"])))
        let saved = try await store.saveSNESStartupCandidate(candidate)
        #expect(try SNESStartupAdapterCandidate.load(directory: saved).image == candidate.image)
        let summary: [String: Any] = ["candidate": saved.path, "imageBytes": candidate.image.count,
            "imageSHA256": BackupManifest.digest(candidate.image), "consoleAccessed": false, "firmwareWritten": false]
        let output = URL(fileURLWithPath: try #require(env["HC_SNES_COMBINED_PREPARE_ROOT"])).appendingPathComponent("combined-prepared.json")
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SNES_COMBINED_PARENT_COPY"] != nil))
    func combinedCandidateBindsToAcceptedParentAndSimulatedPreparation() async throws {
        let env = ProcessInfo.processInfo.environment
        let operation = URL(fileURLWithPath: try #require(env["HC_SNES_COMBINED_PARENT_COPY"]))
        let review = try #require(env["HC_SNES_COMBINED_PARENT_REVIEW"])
        let pins = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let journal: SNESFirmwareJournal
        do { journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: review, recovery: inputs) }
        catch { Issue.record("Copied parent journal could not be reopened: \(error)"); throw error }
        let parent: SNESMenuStartupParent
        do { parent = try await journal.combinedLibraryStartupParent(); try await journal.close() }
        catch { try? await journal.close(); Issue.record("Combined trial parent could not be reconstructed: \(error)"); throw error }
        let candidate = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_COMBINED_CANDIDATE"])))
        do { try parent.require(candidate) }
        catch { Issue.record("Saved candidate did not match its reconstructed parent: \(error)"); throw error }
        #expect(candidate.libraryRecipeVersion == 12)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(candidate.libraryRecipeVersion) }
        let io = try MenuStartupPreflightFake(parent: parent, fault: "none")
        let result: SNESStartupPreflightResult
        do { result = try await SNESStartupPreflightService(wait: {}).capture(candidate: candidate, inputs: inputs, io: io, parent: parent) }
        catch { Issue.record("Simulated preparation did not complete: \(error)"); throw error }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try await RecoveryBootSnapshotStore(root: root).saveSNESStartupPreflight(result)
        let trial = try PreparedSNESStartupTrial.prepare(candidate: candidate, evidence: evidence, recovery: inputs, parent: parent)
        try trial.validateCurrent()
        #expect(trial.image == candidate.image)
        #expect(await io.base.stages == 1)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SNES_CONCURRENT_CANDIDATE"] != nil))
    func concurrentRAMCandidateOnlyChangesTheVerifierAndItsIntegrityRecords() throws {
        let env = ProcessInfo.processInfo.environment
        let old = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_CONCURRENT_OLD"])))
        let candidate = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_CONCURRENT_CANDIDATE"])))
        #expect(old.libraryRecipeVersion == 10 && candidate.libraryRecipeVersion == 14)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(candidate.libraryRecipeVersion) }
        let before = try LegacyBootImageBuilder.inspect(old.image), after = try LegacyBootImageBuilder.inspect(candidate.image)
        #expect(before.kernel == after.kernel)
        #expect(before.header[64..<576] == after.header[64..<576])
        let a = Dictionary(uniqueKeysWithValues: before.archive.entries.map { ($0.name, $0.data) })
        let b = Dictionary(uniqueKeysWithValues: after.archive.entries.map { ($0.name, $0.data) })
        #expect(Set(a.keys) == Set(b.keys))
        #expect(Set(a.keys.filter { a[$0] != b[$0] }) == Set(["swifthakchi/library-selector", "swifthakchi/runtime-files.sha256", "swifthakchi/files.sha256"]))
        #expect(b["swifthakchi/library-selector"] == Data(try SNESLibraryStartupScripts.parallelEntryVerifierCandidate().utf8))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SNES_CONCURRENT_PREPARE_ROOT"] != nil))
    func prepareConcurrentCandidateFromSavedStartupWithoutOpeningConsole() async throws {
        let env = ProcessInfo.processInfo.environment
        let old = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_CONCURRENT_OLD"])))
        #expect(old.libraryRecipeVersion == 10)
        let candidate = try SNESStartupAdapterCandidate.withLibrarySupport(old, targetRecipe: 14)
        #expect(candidate.libraryRecipeVersion == 14)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(candidate.libraryRecipeVersion) }
        let store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath: try #require(env["HC_SNES_CONCURRENT_PREPARE_ROOT"])))
        let saved = try await store.saveSNESStartupCandidate(candidate)
        #expect(try SNESStartupAdapterCandidate.load(directory: saved).image == candidate.image)
        let summary: [String: Any] = ["candidate": saved.path, "imageBytes": candidate.image.count,
            "imageSHA256": BackupManifest.digest(candidate.image), "consoleAccessed": false, "firmwareWritten": false]
        let output = URL(fileURLWithPath: try #require(env["HC_SNES_CONCURRENT_PREPARE_ROOT"])).appendingPathComponent("concurrent-prepared.json")
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SNES_CONCURRENT_PARENT_COPY"] != nil))
    func concurrentCandidateBindsToAcceptedParentAndSimulatedPreparation() async throws {
        let env = ProcessInfo.processInfo.environment
        let operation = URL(fileURLWithPath: try #require(env["HC_SNES_CONCURRENT_PARENT_COPY"]))
        let review = try #require(env["HC_SNES_CONCURRENT_PARENT_REVIEW"])
        let pins = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let journal: SNESFirmwareJournal
        do { journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: review, recovery: inputs) }
        catch { Issue.record("Copied parent journal could not be reopened: \(error)"); throw error }
        let parent: SNESMenuStartupParent
        do { parent = try await journal.concurrentLibraryStartupParent(); try await journal.close() }
        catch { try? await journal.close(); Issue.record("Concurrent trial parent could not be reconstructed: \(error)"); throw error }
        let candidate = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_CONCURRENT_CANDIDATE"])))
        do { try parent.require(candidate) }
        catch { Issue.record("Saved candidate did not match its reconstructed parent: \(error)"); throw error }
        #expect(candidate.libraryRecipeVersion == 14)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(candidate.libraryRecipeVersion) }
        let io = try MenuStartupPreflightFake(parent: parent, fault: "none")
        let result: SNESStartupPreflightResult
        do { result = try await SNESStartupPreflightService(wait: {}).capture(candidate: candidate, inputs: inputs, io: io, parent: parent) }
        catch { Issue.record("Simulated preparation did not complete: \(error)"); throw error }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try await RecoveryBootSnapshotStore(root: root).saveSNESStartupPreflight(result)
        let trial = try PreparedSNESStartupTrial.prepare(candidate: candidate, evidence: evidence, recovery: inputs, parent: parent)
        try trial.validateCurrent()
        #expect(trial.image == candidate.image)
        #expect(await io.base.stages == 1)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SNES_QUEUED_CANDIDATE"] != nil))
    func queuedRAMCandidateOnlyChangesTheExpectedAssets() throws {
        let env = ProcessInfo.processInfo.environment
        let old = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_QUEUED_OLD"])))
        let candidate = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_QUEUED_CANDIDATE"])))
        #expect(old.libraryRecipeVersion == 10 && candidate.libraryRecipeVersion == 13)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(candidate.libraryRecipeVersion) }
        let before = try LegacyBootImageBuilder.inspect(old.image), after = try LegacyBootImageBuilder.inspect(candidate.image)
        #expect(before.kernel == after.kernel)
        #expect(before.header[64..<576] == after.header[64..<576])
        let a = Dictionary(uniqueKeysWithValues: before.archive.entries.map { ($0.name, $0.data) })
        let b = Dictionary(uniqueKeysWithValues: after.archive.entries.map { ($0.name, $0.data) })
        #expect(Set(a.keys) == Set(b.keys))
        #expect(Set(a.keys.filter { a[$0] != b[$0] }) == Set(["swifthakchi/library-selector", "swifthakchi/menu-change", "swifthakchi/runtime-files.sha256", "swifthakchi/files.sha256"]))
        #expect(b["swifthakchi/library-selector"] == Data(try SNESLibraryStartupScripts.combinedStatVerifierCandidate().utf8))
        #expect(b["swifthakchi/menu-change"] == Data(try SNESLibraryStartupScripts.queuedChangePageCandidate().utf8))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SNES_QUEUED_PREPARE_ROOT"] != nil))
    func prepareQueuedCandidateFromSavedStartupWithoutOpeningConsole() async throws {
        let env = ProcessInfo.processInfo.environment
        let old = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_QUEUED_OLD"])))
        #expect(old.libraryRecipeVersion == 10)
        let candidate = try SNESStartupAdapterCandidate.withLibrarySupport(old, targetRecipe: 13)
        #expect(candidate.libraryRecipeVersion == 13)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(candidate.libraryRecipeVersion) }
        let store = try RecoveryBootSnapshotStore(root: URL(fileURLWithPath: try #require(env["HC_SNES_QUEUED_PREPARE_ROOT"])))
        let saved = try await store.saveSNESStartupCandidate(candidate)
        #expect(try SNESStartupAdapterCandidate.load(directory: saved).image == candidate.image)
        let summary: [String: Any] = ["candidate": saved.path, "imageBytes": candidate.image.count,
            "imageSHA256": BackupManifest.digest(candidate.image), "consoleAccessed": false, "firmwareWritten": false]
        let output = URL(fileURLWithPath: try #require(env["HC_SNES_QUEUED_PREPARE_ROOT"])).appendingPathComponent("queued-prepared.json")
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .withoutOverwriting)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_SNES_QUEUED_PARENT_COPY"] != nil))
    func queuedCandidateBindsToAcceptedParentAndSimulatedPreparation() async throws {
        let env = ProcessInfo.processInfo.environment
        let operation = URL(fileURLWithPath: try #require(env["HC_SNES_QUEUED_PARENT_COPY"]))
        let review = try #require(env["HC_SNES_QUEUED_PARENT_REVIEW"])
        let pins = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let journal: SNESFirmwareJournal
        do { journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: review, recovery: inputs) }
        catch { Issue.record("Copied parent journal could not be reopened: \(error)"); throw error }
        let parent: SNESMenuStartupParent
        do { parent = try await journal.queuedLibraryStartupParent(); try await journal.close() }
        catch { try? await journal.close(); Issue.record("Queued trial parent could not be reconstructed: \(error)"); throw error }
        let candidate = try SNESStartupAdapterCandidate.load(directory: URL(fileURLWithPath: try #require(env["HC_SNES_QUEUED_CANDIDATE"])))
        do { try parent.require(candidate) }
        catch { Issue.record("Saved candidate did not match its reconstructed parent: \(error)"); throw error }
        #expect(candidate.libraryRecipeVersion == 13)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireInstallableRecipe(candidate.libraryRecipeVersion) }
        let io = try MenuStartupPreflightFake(parent: parent, fault: "none")
        let result: SNESStartupPreflightResult
        do { result = try await SNESStartupPreflightService(wait: {}).capture(candidate: candidate, inputs: inputs, io: io, parent: parent) }
        catch { Issue.record("Simulated preparation did not complete: \(error)"); throw error }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let evidence = try await RecoveryBootSnapshotStore(root: root).saveSNESStartupPreflight(result)
        let trial = try PreparedSNESStartupTrial.prepare(candidate: candidate, evidence: evidence, recovery: inputs, parent: parent)
        try trial.validateCurrent()
        #expect(trial.image == candidate.image)
        #expect(await io.base.stages == 1)
    }
    @Test func libraryStartupHasItsOwnManagementIdentity() throws {
        let expected = SNESStartupTrialExpectation(hwid: String(repeating: "1", count: 32), runtimeSHA256: String(repeating: "a", count: 64),
            wrapperSHA256: String(repeating: "b", count: 64), deviceVersion: 0x6a0b, menuWrapperSHA256: String(repeating: "c", count: 64))
        try expected.validate()
        #expect(expected.menuEnabled)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_LIBRARY_PARENT"] != nil))
    func reconstructsTheAcceptedParentAndPreservesItsKernelKeysAndOldRecipe() async throws {
        let env = ProcessInfo.processInfo.environment
        let operation = URL(fileURLWithPath: try #require(env["SWIFTHAKCHI_SNES_LIBRARY_PARENT"]))
        let review = try #require(env["SWIFTHAKCHI_SNES_LIBRARY_PARENT_REVIEW"])
        let pinned = try PinnedFELInputs.load(), recovery = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        let journal = try await SNESFirmwareJournal.reopen(operation: operation, reviewSHA256: review, recovery: recovery)
        let parent: SNESMenuStartupParent
        do { parent = try await journal.libraryStartupParent(); try await journal.close() }
        catch { try? await journal.close(); throw error }
        let previous = parent.installed.trial.candidate
        #expect(previous.hasMenuSupport && !previous.hasNavigationLaunchSupport)
        #expect(parent.candidate.hasNavigationLaunchSupport && parent.candidate.managementVersion == 0x6a0b)
        try parent.require(parent.candidate)
        let savedParent = try Data(contentsOf: operation.appendingPathComponent("plan.json"))
        try SNESFirmwareJournal.requireUpgradeParent(parent, savedPlan: savedParent, directory: operation)
        var substitutedPlan = savedParent; substitutedPlan.append(32)
        #expect(throws: (any Error).self) { try SNESFirmwareJournal.requireUpgradeParent(parent, savedPlan: substitutedPlan, directory: operation) }
        let original = try LegacyBootImageBuilder.inspect(previous.image), changed = try LegacyBootImageBuilder.inspect(parent.candidate.image)
        #expect(changed.kernel == original.kernel && changed.header[64..<576] == original.header[64..<576])
        #expect(parent.candidate.image.count <= 4 * 1024 * 1024)
        try SNESColdBootPolicy.require(boot1: parent.candidate.material.support.source.preparation.source.boot1, image: parent.candidate.image)
        let changes: Set<String> = ["swifthakchi/prepare", "swifthakchi/service", "swifthakchi/menu-configure", "swifthakchi/runtime-files.sha256", "swifthakchi/files.sha256", "swifthakchi/library-selector", "swifthakchi/menu-change", "swifthakchi/menu-route"]
        for entry in original.archive.entries where !changes.contains(entry.name) {
            var actual = try #require(changed.archive.entries.first(where: { $0.name == entry.name }))
            // Archive-local inode numbering may shift for runtime assets; payloads and other metadata cannot.
            if entry.name.hasPrefix("swifthakchi/") { actual.fields[0] = entry.fields[0] }
            #expect(actual == entry)
        }
        #expect(Set(changed.archive.entries.map(\.name)).subtracting(original.archive.entries.map(\.name)) ==
            (previous.hasLibrarySupport ? Set(["swifthakchi/menu-launch"]):Set(["swifthakchi/library-selector", "swifthakchi/menu-route", "swifthakchi/menu-change", "swifthakchi/menu-launch"])))
        let manifest = try JSONSerialization.jsonObject(with: parent.candidate.checkedExport().manifest) as? [String: Any]
        #expect(manifest?["schemaVersion"] as? Int == 10)
        #expect(manifest?["firmwareInstallEligible"] as? Bool == false)
        try parent.validate()
        if let path=env["SWIFTHAKCHI_CLEAN_MENU_REPORT_EXPORT"] {
            let temporary=try testDirectory();defer {try? FileManager.default.removeItem(at:temporary)}
            let io=try MenuStartupPreflightFake(parent:parent,fault:"none")
            let result=try await SNESStartupPreflightService(wait:{}).capture(candidate:parent.candidate,inputs:recovery,io:io,parent:parent)
            let directory=try await RecoveryBootSnapshotStore(root:temporary).saveSNESStartupPreflight(result)
            let trial=try PreparedSNESStartupTrial.prepare(candidate:parent.candidate,evidence:directory,recovery:recovery,parent:parent)
            let script=try SNESStartupTrialCommands.script(trial:trial,challenge:UUID(uuidString:"11111111-1111-1111-1111-111111111111")!)
            #expect(script.contains("MCP_SIGBLK=%s") && script.contains("UI_SIGBLK=%s") && script.contains(Self.cleanMaskLiteral))
            try Data(script.utf8).write(to:URL(fileURLWithPath:path),options:.withoutOverwriting)
            #expect(await io.base.stages==1)
        }
        if let path = env["SWIFTHAKCHI_SNES_LIBRARY_CANDIDATE_EXPORT"] {
            let root = URL(fileURLWithPath: path), store = try RecoveryBootSnapshotStore(root: root)
            let directory = try await store.saveSNESStartupCandidate(parent.candidate)
            #expect(try SNESStartupAdapterCandidate.load(directory: directory).image == parent.candidate.image)
            let summary: [String: Any] = ["candidate": directory.path, "imageBytes": parent.candidate.image.count,
                "imageSHA256": BackupManifest.digest(parent.candidate.image), "parentOperation": operation.path,
                "parentReviewSHA256": review, "consoleAccessed": false, "firmwareWritten": false]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("prepared.json"))
        }
    }
}
