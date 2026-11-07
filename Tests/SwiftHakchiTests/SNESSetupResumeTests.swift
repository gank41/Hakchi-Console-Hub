import Foundation
import Testing
import SwiftHakchiCore
import Darwin
@testable import SwiftHakchi

private actor ResumeValidationPause {
    private var entered = false
    private var calls = 0
    private var enterWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func validate() async {
        calls += 1
        guard calls == 1 else { return }
        entered = true; enterWaiter?.resume(); enterWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { enterWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

@Suite(.serialized)
struct SNESSetupResumeTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil))
    @MainActor func completeSavedChainCanBeReopenedWithoutConsoleAndRejectsLaterChanges() async throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let original=try #require(try await originalComponentSourceFixture(root:root))
        let oldSetup=original.material.setup.directoryURL
        let backup=root.appendingPathComponent(oldSetup.lastPathComponent)
        try FileManager.default.copyItem(at:oldSetup,to:backup)
        let setup=try SNESOfflineSource.load(snapshot:backup)
        let preparation=try SNESMenuSupportSource.load(setup:setup,preparation:original.material.source.directoryURL)
        let support=try SNESMenuSupportMaterial.load(source:preparation,directory:original.material.directoryURL)
        let source=try SNESOriginalComponentSource(material:support)
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let result=try await SNESOriginalComponentService(wait:{}).capture(source:source,inputs:inputs,io:OriginalComponentFakeIO(source:source))
        let store=try RecoveryBootSnapshotStore(root:root)
        let components=try await store.saveSNESOriginalComponents(result)
        let componentManifest = try Data(contentsOf: components.appendingPathComponent("manifest.json"))
        let componentReceipt = SNESSetupRecordReceipt(kind: .components, directory: components, manifestSHA256: BackupManifest.digest(componentManifest))
        let startupReceipt = SNESSetupRecordReceipt(kind: .startup, directory: preparation.directoryURL, manifestSHA256: preparation.manifestSHA256)
        let supportReceipt = SNESSetupRecordReceipt(kind: .menuSupport, directory: support.directoryURL, manifestSHA256: support.manifestSHA256)
        let chain = SNESSetupRecordChain(startup: startupReceipt, support: supportReceipt, components: componentReceipt)
        let invalidChain = SNESSetupRecordChain(startup: startupReceipt, support: supportReceipt,
            components: SNESSetupRecordReceipt(kind: .components, directory: components, manifestSHA256: String(repeating: "0", count: 64)))
        let backupReceipt = SNESSetupRecordReceipt(kind: .backup, directory: backup, manifestSHA256: setup.manifestSHA256)
        let recovery=try await store.saveSNESRecoveryMaterial(SNESRecoveryMaterial.load(setup:backup))
        try SNESRecoveryMaterial.loadPackage(directory: recovery).requireExactSource(SNESRecoveryMaterial.load(setup: backup))
        let helpers=try await store.saveSNESPortableHelpers()
        let config = AppConfig(); config.workspacePath = root.path; config.backupDirectoryPath = root.path; config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: { Issue.record("Read-only destination reached the USB host") },
            makeSNESDataSnapshotIO: { source in Issue.record("Read-only destination created console I/O"); return NativeSNESDataSnapshotIO(source: source) },
            makeSNESRuntimeIO: { Issue.record("Invalid data backup created console I/O"); return NativeRecoveryProbeIO(observationCommand: SNESBackupPolicy.command) })
        app.isPreparingSync = true
        await #expect(throws: (any Error).self) {
            try await app.backupSNESData(backup: backupReceipt, recovery: recovery, helpers: helpers, chain: invalidChain, progress: { _ in }, detail: { _ in })
        }
        #expect(chmod(root.path, 0o500) == 0)
        await #expect(throws: (any Error).self) {
            try await app.backupSNESData(backup: backupReceipt, recovery: recovery, helpers: helpers, chain: chain, progress: { _ in }, detail: { _ in })
        }
        #expect(chmod(root.path, 0o700) == 0)
        await #expect(throws: (any Error).self) {
            try await app.captureSNESRuntime(backup: backupReceipt, recovery: recovery, helpers: helpers, chain: chain,
                data: SNESDataSnapshotReceipt(directory: root.appendingPathComponent("missing-data"), manifestSHA256: String(repeating: "0", count: 64)), progress: { _ in })
        }
        let saved=try SNESSetupResumeEvidence.load(root:root,backup:backup,recovery:recovery,helpers:helpers,
            startup:preparation.directoryURL,support:support.directoryURL,components:components)
        #expect(saved.stage == .components)
        try saved.revalidate()
        let prior = try SNESSetupResumeEvidence.load(root: root, backup: backup, recovery: recovery, helpers: helpers,
            startup: preparation.directoryURL, support: support.directoryURL)
        #expect(prior.receipt(for: .startup) == startupReceipt)
        #expect(prior.receipt(for: .menuSupport) == supportReceipt)
        _ = try chain.load(setup: setup)
        #expect(throws: (any Error).self) { try invalidChain.load(setup: setup) }
        #expect(try prior.advancing(componentReceipt).stage == .components)
        #expect(throws: (any Error).self) {
            try prior.advancing(SNESSetupRecordReceipt(kind: .components, directory: components, manifestSHA256: String(repeating: "0", count: 64)))
        }
        let found=try await SNESSetupResumeCatalog.resolve(root:root,backup:backup)
        #expect(found.evidence.stage == .components && found.unverifiedCount == 0)
        #expect(found.evidence.backup.path == backup.path)
        let pause = ResumeValidationPause()
        let cancelGuide = SNESBackupGuide(execute: { _ in backupReceipt }, validateResume: { _ in await pause.validate() })
        let firstResume = Task { try await cancelGuide.resume(found.evidence, unverifiedCount: 0) }
        await pause.waitForEntry()
        cancelGuide.cancelResume()
        #expect(cancelGuide.phase == .instructions)
        var secondSucceeded = false
        do { try await cancelGuide.resume(found.evidence, unverifiedCount: 0); secondSucceeded = true } catch {}
        #expect(secondSucceeded && cancelGuide.phase == .resumeConfirmNormal)
        await pause.release()
        await #expect(throws: CancellationError.self) { try await firstResume.value }
        #expect(cancelGuide.phase == .resumeConfirmNormal)
        cancelGuide.cancelResume()
        #expect(cancelGuide.phase == .instructions)
        for _ in 0..<65 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("SNES-US-Setup-" + UUID().uuidString), withIntermediateDirectories: false)
        }
        let listed = try SNESSetupResumeCatalog.list(root: root)
        let choice = try #require(listed.first { $0.backup.path == backup.path })
        try found.evidence.requireBackupManifest(choice.manifestSHA256)
        #expect(throws: (any Error).self) { try found.evidence.requireBackupManifest(String(repeating: "0", count: 64)) }
        let beforeBadChoice = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        await #expect(throws: (any Error).self) {
            try await SNESSetupResumeCatalog.resolve(root: root, backup: backup, expectedManifest: String(repeating: "0", count: 64))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == beforeBadChoice)
        let previous = preparation.preparation
        let runtime = SNESRuntimeMaterial(binding: setup.runtimeBinding, frame: try SNESRuntimeFrame(runtimeFrameFixture()),
            before: previous.before, after: previous.after, observation: previous.observation)
        await #expect(throws: (any Error).self) {
            try await store.saveSNESRuntime(runtime, source: setup, verify: { _ in throw RecoveryProbeError.refused("Verification failed") })
        }
        let rejectedRuntime = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("SNES-US-Runtime-") }
        #expect(rejectedRuntime.count == 1 && !FileManager.default.fileExists(atPath: rejectedRuntime[0].appendingPathComponent("manifest.json").path))
        await #expect(throws: (any Error).self) {
            try await store.saveSNESRuntime(runtime, source: setup, verify: { directory in
                try Data([1]).write(to: directory.appendingPathComponent("runtime.frame"))
            })
        }
        let rejected = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("SNES-US-Runtime-") }
        #expect(rejected.count == 2 && rejected.allSatisfy { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) })
        let runtimeURL = try await store.saveSNESRuntime(runtime, source: setup)
        _ = try SNESRuntimeMaterial.load(directory: runtimeURL, source: setup)
        let alternateURL = backup.appendingPathComponent("backup-boot2.img")
        let alternate = FileManager.default.fileExists(atPath: alternateURL.path) ? try Data(contentsOf: alternateURL) : nil
        let kernel = SNESKernelBackupReport(before: previous.before, after: previous.after, observation: previous.observation,
                                            active: setup.stock, backup: alternate)
        var otherBoot1 = previous.source.boot1
        otherBoot1[otherBoot1.startIndex] ^= 1
        let header = previous.source.header
        let frame = Data("SWIFTHAKCHI_DATA_SUPERBLOCK_V1 2048 \(BackupManifest.digest(header))\n".utf8) + header
        let otherReport = try SNESSetupReadinessReport(kernel: kernel, boot1: otherBoot1, partitions: previous.source.partitions, headerFrame: frame)
        let otherBackup = try await store.saveSNESSetup(otherReport)
        let otherMaterial = try SNESRecoveryMaterial.load(setup: otherBackup)
        #expect(throws: (any Error).self) { try SNESRecoveryMaterial.loadPackage(directory: recovery).requireExactSource(otherMaterial) }
        let guide = SNESBackupGuide(execute: { _ in Issue.record("Resuming must not contact the console"); return SNESSetupRecordReceipt(kind: .backup, directory: backup, manifestSHA256: setup.manifestSHA256) })
        try await guide.resume(found.evidence, unverifiedCount: found.unverifiedCount)
        #expect(guide.phase == .resumeConfirmNormal)
        #expect(!guide.canReviewStartupCheck && !guide.canReviewComponents)
        guide.confirmResumedNormalBoot()
        #expect(guide.phase == .componentsComplete)
        let componentFrame = try Data(contentsOf: components.appendingPathComponent("components.frame"))
        try Data([1]).write(to:components.appendingPathComponent("components.frame"))
        #expect(throws:(any Error).self) { try saved.revalidate() }
        let partial=try await SNESSetupResumeCatalog.resolve(root:root,backup:backup)
        #expect(partial.evidence.stage == .menuSupport && partial.unverifiedCount > 0)
        try componentFrame.write(to: components.appendingPathComponent("components.frame"))
        let substituted = SNESBackupGuide(execute: { _ in SNESSetupRecordReceipt(kind: .backup, directory: backup, manifestSHA256: setup.manifestSHA256) }, captureComponents: { _, _, _, _, _, _ in
            SNESSetupRecordReceipt(kind: .components, directory: components, manifestSHA256: String(repeating: "0", count: 64))
        })
        try await substituted.resume(partial.evidence, unverifiedCount: partial.unverifiedCount)
        substituted.confirmResumedNormalBoot(); substituted.reviewComponents(); await substituted.startComponents(ready: true)
        #expect(substituted.phase == .componentsReturnToNormal && substituted.componentsError != nil)
        #expect(substituted.componentsDirectory?.path == components.path)
        let continuation = SNESBackupGuide(execute: { _ in SNESSetupRecordReceipt(kind: .backup, directory: backup, manifestSHA256: setup.manifestSHA256) }, captureComponents: { _, _, _, _, _, _ in
            #expect(SNESSetupSelectedBinding.current != nil)
            return componentReceipt
        })
        try await continuation.resume(partial.evidence, unverifiedCount: partial.unverifiedCount)
        continuation.confirmResumedNormalBoot(); continuation.reviewComponents()
        await continuation.startComponents(ready: true)
        #expect(continuation.phase == .componentsReturnToNormal && continuation.componentsError == nil)

    }

    @Test func detachedOrOutOfOrderInputsAreRejectedBeforeFilesystemAccess() {
        let root=URL(fileURLWithPath:"/tmp/setup-root",isDirectory:true)
        #expect(throws:(any Error).self) {
            try SNESSetupResumeEvidence.load(root:root,backup:URL(fileURLWithPath:"/tmp/outside"),
                recovery:root.appendingPathComponent("recovery"),helpers:root.appendingPathComponent("helpers"))
        }
        #expect(throws:(any Error).self) {
            try SNESSetupResumeEvidence.load(root:root,backup:root.appendingPathComponent("backup"),
                recovery:root.appendingPathComponent("recovery"),helpers:root.appendingPathComponent("helpers"),
                startup:nil,support:root.appendingPathComponent("support"))
        }
    }

    @Test func manyUnrelatedBackupFoldersDoNotPreventListing() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        for _ in 0..<65 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("SNES-US-Setup-" + UUID().uuidString), withIntermediateDirectories: false)
        }
        #expect(try SNESSetupResumeCatalog.list(root: root).isEmpty)
    }
}
