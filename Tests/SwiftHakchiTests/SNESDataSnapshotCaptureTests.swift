import Foundation
import CryptoKit
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

actor SNESDataSnapshotFakeIO: SNESDataSnapshotIO {
    let source: SNESPreparationSource, base: SNESPreparationFakeIO, fault: String, plan: SNESDataSnapshotPlan
    let digest: String
    var chunks = 0, hashes = 0, observations = 0
    init(source: SNESPreparationSource, fault: String, digestOverride: String? = nil) throws {
        self.source = source; self.fault = fault
        base = SNESPreparationFakeIO(source: source, fault: fault)
        plan = try SNESDataSnapshotPlan(partitionSectors: StockRestorePartitions.dataSectors(String(decoding: source.partitions, as: UTF8.self)))
        var hash = SHA256()
        for i in 0..<plan.chunkCount {
            var data = Data(repeating: 0, count: try plan.range(i).count)
            if i == 0 { data.replaceSubrange(0..<source.header.count, with: source.header) }
            hash.update(data: data)
        }
        digest = digestOverride ?? hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func inventory() async throws -> [RecoveryProbeUSBDevice] {
        if (fault == "attachment" && chunks > 0) || (fault == "detached-after-final-observation" && observations >= 5) { return [] }
        return try await base.inventory()
    }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async throws { try await base.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async throws { try await base.connect(expected: expected) }
    func observe() async throws -> String { observations += 1; return await base.observe() }
    func readBoot2(_ slot: RecoveryBootSlot) async throws -> RecoveryBoot2Read { try await (base as any RecoveryProbeIO).readBoot2(slot) }
    func readBoot1() async throws -> Data { try await (base as any RecoveryProbeIO).readBoot1() }
    func readPartitions() async throws -> Data {
        let data = try await (base as any RecoveryProbeIO).readPartitions()
        return fault == "partition-changed-after-save-hash" && hashes >= 3 ? data + Data("changed".utf8) : data
    }
    func readDataSuperblock() async throws -> Data { try await (base as any RecoveryProbeIO).readDataSuperblock() }
    func disconnect() async { await base.disconnect() }
    func dataHash(challenge: UUID) -> Data {
        hashes += 1
        if fault == "hash" { return Data("incomplete".utf8) }
        let h = (fault == "changed-hash" && hashes == 2) || (fault == "changed-after-save" && hashes == 3) ? String(repeating: "1", count: 64) : digest
        return Data("SWIFTHAKCHI_SNES_DATA_HASH_V1 \(challenge.uuidString) \(plan.byteCount) \(h)\n".utf8)
    }
    func dataChunk(index: Int, challenge: UUID) throws -> Data {
        chunks += 1
        if fault == "cancel" { throw CancellationError() }
        if fault == "chunk" { return Data("partial".utf8) }
        var data = Data(repeating: 0, count: try plan.range(index).count)
        if index == 0 { data.replaceSubrange(0..<source.header.count, with: source.header) }
        return snesDataFrame(data, challenge: challenge, index: index)
    }
}
private actor BlockingRuntimeIO: RecoveryProbeIO {
    let base: RuntimeCaptureIO
    var entered = false
    init(hwid: String) { base = RuntimeCaptureIO(hwid: hwid) }
    func inventory() async -> [RecoveryProbeUSBDevice] { await base.inventory() }
    func boot(_ inputs: RecoveryBootInputs, expected: RecoveryProbeUSBDevice) async { await base.boot(inputs, expected: expected) }
    func connect(expected: RecoveryProbeUSBDevice) async { await base.connect(expected: expected) }
    func disconnect() async { await base.disconnect() }
    func observe() async -> String { await base.observe() }
    func readSNESRuntime() async throws -> Data {
        entered = true
        try await Task.sleep(for: .seconds(30))
        return runtimeFrameFixture()
    }
}
@Suite(.serialized)
struct SNESDataSnapshotCaptureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil), arguments: ["none", "changed-after-save"])
    @MainActor func appSavesAndChecksDataBeforeClosingTheRecoverySession(_ fault: String) async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let components = try #require(try await originalComponentSourceFixture(root: root))
        let setup = components.material.setup
        let source = try SNESPreparationSource.load(setup)
        let pins = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let store = try RecoveryBootSnapshotStore(root: root)
        let componentResult = try await SNESOriginalComponentService(wait: {}).capture(source: components, inputs: inputs,
            io: OriginalComponentFakeIO(source: components))
        let componentReceipt = try await store.saveSNESOriginalComponentsWithReceipt(componentResult)
        let chain = SNESSetupRecordChain(
            startup: SNESSetupRecordReceipt(kind: .startup, directory: components.material.source.directoryURL, manifestSHA256: components.material.source.manifestSHA256),
            support: SNESSetupRecordReceipt(kind: .menuSupport, directory: components.material.directoryURL, manifestSHA256: components.material.manifestSHA256),
            components: componentReceipt)
        let backup = SNESSetupRecordReceipt(kind: .backup, directory: setup.directoryURL, manifestSHA256: setup.manifestSHA256)
        let recovery = try await store.saveSNESRecoveryMaterial(SNESRecoveryMaterial.load(setup: setup.directoryURL))
        let helpers = try await store.saveSNESPortableHelpers()
        let io = try SNESDataSnapshotFakeIO(source: source, fault: fault)
        let config = AppConfig(); config.workspacePath = root.path; config.backupDirectoryPath = root.path; config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: {}, makeSNESDataSnapshotIO: { _ in io })
        app.isPreparingSync = true
        do {
            let receipt = try await app.backupSNESData(backup: backup, recovery: recovery, helpers: helpers, chain: chain, progress: { _ in }, detail: { _ in })
            #expect(fault == "none")
            let checked = try SNESDataSnapshotPackage.load(receipt: receipt, source: source)
            #expect(checked.sha256 == (await io.digest))
        } catch let error as SNESDataSnapshotPostSaveError {
            #expect(fault == "changed-after-save" && error.backupVerified)
            #expect(FileManager.default.fileExists(atPath: error.location.appendingPathComponent("manifest.json").path))
        }
        #expect(await io.hashes == 3)
        #expect(await io.base.events.filter { $0 == "disconnect" }.count == 1)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil))
    func unverifiedSaveLocationIsNotReportedAsAConfirmedBackup() async throws {
        let source = try #require(try snesPreparationFixture())
        let io = try SNESDataSnapshotFakeIO(source: source, fault: "none")
        let pins = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing")
        do {
            _ = try await SNESDataSnapshotService(wait: {}).captureAndSave(source: source, inputs: inputs, io: io, save: { _ in
                SNESDataSnapshotReceipt(directory: missing, manifestSHA256: String(repeating: "0", count: 64))
            })
            Issue.record("An unverified save location was accepted")
        } catch let error as SNESDataSnapshotPostSaveError {
            #expect(!error.backupVerified && error.location == missing)
            #expect(!error.localizedDescription.contains("A backup was saved"))
        }
        #expect(await io.base.events.filter { $0 == "disconnect" }.count == 1)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil), arguments: ["none", "changed-after-save", "detached-after-final-observation", "partition-changed-after-save-hash"])
    func savesAndChecksBackupBeforeClosingRecoverySession(_ fault: String) async throws {
        let source = try #require(try snesPreparationFixture())
        let io = try SNESDataSnapshotFakeIO(source: source, fault: fault)
        let pins = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryBootSnapshotStore(root: root)
        do {
            let checkedSession = try await SNESDataSnapshotService(wait: {}).captureAndSave(source: source, inputs: inputs, io: io, save: { result in
                #expect(await io.base.events.last != "disconnect")
                return try await store.saveSNESDataSnapshotWithReceipt(result)
            })
            #expect(fault == "none")
            let checked = try SNESDataSnapshotPackage.load(receipt: checkedSession.backup, source: source)
            #expect(checked.sha256 == (await io.digest))
        } catch {
            #expect(fault != "none")
            #expect((error as? SNESDataSnapshotPostSaveError)?.backupVerified == true)
        }
        #expect(await io.hashes == 3)
        #expect(await io.base.events.filter { $0 == "disconnect" }.count == 1)
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("SNES-Current-Data-") }
        #expect(backups.count == 1 && FileManager.default.fileExists(atPath: backups[0].appendingPathComponent("manifest.json").path))
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    func liveComparisonRejectsBackupFromDifferentSetupEvenWithSameHardwareID() async throws {
        let source = try #require(try snesPreparationFixture())
        let originalPath = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"])
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: originalPath), to: copy)
        let bootURL = copy.appendingPathComponent("boot1.bin")
        var boot = try Data(contentsOf: bootURL); boot[0] ^= 1; try boot.write(to: bootURL)
        let manifestURL = copy.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var files = try #require(manifest["files"] as? [String: String])
        files["boot1.bin"] = BackupManifest.digest(boot); manifest["files"] = files
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        let package = try SNESDataSnapshotPackage.load(directory: copy, expectedHWID: source.source.expectedHWID)
        let io = try SNESDataSnapshotFakeIO(source: source, fault: "none", digestOverride: package.sha256)
        let pins = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pins.fes1, uboot: pins.uboot, bootImage: pins.bootImage)
        _ = try await RecoverySessionCoordinator(wait: {}).run(inputs: inputs, io: io, validateObservation: {
            let observation = try SNESBackupPolicy.observation($0); try source.requireObservation(observation); return observation
        }) { context in
            await #expect(throws: (any Error).self) {
                try await SNESDataSnapshotLiveCheck.verify(package: package, source: source, context: context,
                                                           header: source.header, connection: io)
            }
        }
        #expect(await io.hashes == 0)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    func receiptMustMatchTheSelectedSetupEvenWhenHardwareIDMatches() throws {
        let source = try #require(try snesPreparationFixture())
        let originalPath = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"])
        let root = try testDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: originalPath), to: copy)
        let manifestURL = copy.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifestURL)
        let receipt = SNESDataSnapshotReceipt(directory: copy, manifestSHA256: BackupManifest.digest(original))
        let accepted = try SNESDataSnapshotPackage.load(receipt: receipt, source: source)
        #expect(accepted.binding == source.source.runtimeBinding)
        let wrong = SNESDataSnapshotReceipt(directory: copy, manifestSHA256: String(repeating: "0", count: 64))
        #expect(throws: (any Error).self) { try SNESDataSnapshotPackage.load(receipt: wrong, source: source) }

        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var binding = try #require(object["binding"] as? [String: Any])
        binding["sourceSnapshot"] = "SNES-US-Setup-11111111-1111-1111-1111-111111111111"
        object["binding"] = binding
        let altered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try altered.write(to: manifestURL)
        let forged = SNESDataSnapshotReceipt(directory: copy, manifestSHA256: BackupManifest.digest(altered))
        let sameHardware = try SNESDataSnapshotPackage.load(directory: copy, expectedHWID: source.source.expectedHWID)
        #expect(sameHardware.binding != source.source.runtimeBinding)
        #expect(throws: (any Error).self) { try accepted.revalidate() }
        #expect(throws: (any Error).self) { try SNESDataSnapshotPackage.load(receipt: forged, source: source) }

        var mounted = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var context = try #require(mounted["context"] as? [String: Any])
        var observation = try #require(context["observation"] as? [String: Any])
        var mounts = try #require(observation["mounts"] as? [String])
        mounts.append("tmpfs /newroot/scratch tmpfs ro 0 0")
        observation["mounts"] = mounts; context["observation"] = observation; mounted["context"] = context
        let mountedManifest = try JSONSerialization.data(withJSONObject: mounted, options: [.sortedKeys])
        try mountedManifest.write(to: manifestURL)
        let mountedReceipt = SNESDataSnapshotReceipt(directory: copy, manifestSHA256: BackupManifest.digest(mountedManifest))
        _ = try SNESDataSnapshotPackage.load(directory: copy, expectedHWID: source.source.expectedHWID)
        #expect(throws: (any Error).self) { try SNESDataSnapshotPackage.load(receipt: mountedReceipt, source: source) }

        // A later backup may legitimately contain different data while retaining
        // the same console and filesystem identity. Modify only the fixture copy.
        var newer = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var files = try #require(newer["files"] as? [String: String])
        let chunks = files.keys.filter { $0.hasPrefix("data-") && $0.hasSuffix(".bin") && $0 != "data-header.bin" }.sorted()
        let last = try #require(chunks.last)
        var full = SHA256()
        for name in chunks {
            let url = copy.appendingPathComponent(name)
            var bytes = try Data(contentsOf: url)
            if name == last {
                bytes[bytes.count - 1] ^= 1
                try bytes.write(to: url)
                files[name] = BackupManifest.digest(bytes)
            }
            full.update(data: bytes)
        }
        newer["files"] = files
        newer["sha256"] = full.finalize().map { String(format: "%02x", $0) }.joined()
        let newerManifest = try JSONSerialization.data(withJSONObject: newer, options: [.sortedKeys])
        try newerManifest.write(to: manifestURL)
        let newerReceipt = SNESDataSnapshotReceipt(directory: copy, manifestSHA256: BackupManifest.digest(newerManifest))
        let newerBackup = try SNESDataSnapshotPackage.load(receipt: newerReceipt, source: source)
        #expect(newerBackup.sha256 != accepted.sha256 && newerBackup.binding == accepted.binding)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil))
    @MainActor func failedFinalVerificationCannotLeaveACompletedDataBackup() async throws {
        let source=try #require(try snesPreparationFixture()),io=try SNESDataSnapshotFakeIO(source:source,fault:"none")
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let result=try await SNESDataSnapshotService(wait:{}).capture(source:source,inputs:inputs,io:io)
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let store=try RecoveryBootSnapshotStore(root:root)
        await #expect(throws:(any Error).self) {
            try await store.saveSNESDataSnapshot(result,verify:{_ in throw RecoveryProbeError.refused("verification failed")})
        }
        let folders=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter{$0.lastPathComponent.hasPrefix("SNES-Current-Data-")}
        #expect(folders.count==1)
        #expect(folders.allSatisfy{!FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path)})
        await #expect(throws:(any Error).self) {
            try await store.saveSNESDataSnapshot(result,verify:{ directory in
                let url=directory.appendingPathComponent("manifest.json")
                var object=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:url)) as? [String:Any])
                var binding=try #require(object["binding"] as? [String:Any])
                binding["sourceSnapshot"]="SNES-US-Setup-11111111-1111-1111-1111-111111111111"
                object["binding"]=binding
                try JSONSerialization.data(withJSONObject:object).write(to:url)
            })
        }
        let unfinished=try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter{$0.lastPathComponent.hasPrefix("SNES-Current-Data-")}
        #expect(unfinished.count==2)
        #expect(unfinished.allSatisfy{!FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path)})
        await #expect(throws:(any Error).self) {
            try await store.saveSNESDataSnapshot(result, verify: { directory in
                try Data([1]).write(to: directory.appendingPathComponent("data-0000.bin"))
            })
        }
        let damaged = try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter{$0.lastPathComponent.hasPrefix("SNES-Current-Data-")}
        #expect(damaged.count == 3 && damaged.allSatisfy { !FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path) })
        let receipt=try await store.saveSNESDataSnapshotWithReceipt(result)
        let complete=receipt.directory
        let reopened=try SNESDataSnapshotPackage.load(directory:complete,expectedHWID:source.source.expectedHWID)
        #expect(reopened.byteCount==300*1024*1024 && reopened.sha256==result.sha256 && reopened.manifestSHA256==receipt.manifestSHA256)
        let componentSource = try #require(try await originalComponentSourceFixture(root: root))
        let componentResult = try await SNESOriginalComponentService(wait: {}).capture(source: componentSource, inputs: inputs,
            io: OriginalComponentFakeIO(source: componentSource))
        let componentReceipt = try await store.saveSNESOriginalComponentsWithReceipt(componentResult)
        let chain = SNESSetupRecordChain(
            startup: SNESSetupRecordReceipt(kind: .startup, directory: componentSource.material.source.directoryURL, manifestSHA256: componentSource.material.source.manifestSHA256),
            support: SNESSetupRecordReceipt(kind: .menuSupport, directory: componentSource.material.directoryURL, manifestSHA256: componentSource.material.manifestSHA256),
            components: componentReceipt)
        let backupReceipt = SNESSetupRecordReceipt(kind: .backup, directory: source.source.directoryURL, manifestSHA256: source.source.manifestSHA256)
        let recovery = try await store.saveSNESRecoveryMaterial(SNESRecoveryMaterial.load(setup: source.source.directoryURL))
        let helpers = try await store.saveSNESPortableHelpers()
        let runtimeIO = RuntimeCaptureIO(hwid: source.source.expectedHWID), host = ConnectionCallCounter()
        let config = AppConfig(); config.workspacePath = root.path; config.backupDirectoryPath = root.path; config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: { await host.record(1) }, makeSNESRuntimeIO: { runtimeIO })
        app.isPreparingSync = true
        let wrong = SNESDataSnapshotReceipt(directory: complete, manifestSHA256: String(repeating: "0", count: 64))
        await #expect(throws: (any Error).self) {
            try await app.captureSNESRuntime(backup: backupReceipt, recovery: recovery, helpers: helpers, chain: chain, data: wrong, progress: { _ in })
        }
        let beforeHost = await host.ids, beforeRuntime = await runtimeIO.events
        #expect(beforeHost.isEmpty && beforeRuntime.isEmpty)
        let runtime = try await app.captureSNESRuntime(backup: backupReceipt, recovery: recovery, helpers: helpers, chain: chain, data: receipt, progress: { _ in })
        _ = try SNESRuntimeMaterial.load(directory: runtime.directory, source: source.source)
        let runtimeManifest = try Data(contentsOf: runtime.directory.appendingPathComponent("manifest.json"))
        #expect(runtime.kind == .runtime && runtime.manifestSHA256 == BackupManifest.digest(runtimeManifest))
        let hostCalls = await host.ids, reads = await runtimeIO.reads, events = await runtimeIO.events
        #expect(hostCalls.count == 1 && reads == 2 && events.last == "disconnect")
        let cancelledIO = RuntimeCaptureIO("cancel", hwid: source.source.expectedHWID)
        let cancelled = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: {}, makeSNESRuntimeIO: { cancelledIO })
        cancelled.isPreparingSync = true
        await #expect(throws: CancellationError.self) {
            try await cancelled.captureSNESRuntime(backup: backupReceipt, recovery: recovery, helpers: helpers, chain: chain, data: receipt, progress: { _ in })
        }
        #expect(await cancelledIO.events.last == "disconnect")
        let blocking = BlockingRuntimeIO(hwid: source.source.expectedHWID)
        let interruptible = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: {}, makeSNESRuntimeIO: { blocking })
        interruptible.isPreparingSync = true
        let operation = Task {
            try await interruptible.captureSNESRuntime(backup: backupReceipt, recovery: recovery, helpers: helpers, chain: chain, data: receipt, progress: { _ in })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while !(await blocking.entered) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let started = await blocking.entered
        #expect(started)
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(await blocking.base.events.last == "disconnect")
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"] != nil),
        arguments: ["none", "inventory", "boot", "connect", "identity", "mounted-data", "kernel", "boot1", "partitions", "header", "hash", "chunk", "attachment", "changed-hash", "cancel"])
    func validatesCurrentConsoleAndClosesExactlyOnce(fault: String) async throws {
        let available = try snesPreparationFixture()
        let source = try #require(available), io = try SNESDataSnapshotFakeIO(source: source, fault: fault)
        let pinned = try PinnedFELInputs.load()
        let inputs = RecoveryBootInputs(fes1: pinned.fes1, uboot: pinned.uboot, bootImage: pinned.bootImage)
        if fault == "none" {
            let result = try await SNESDataSnapshotService(wait: {}).capture(source: source, inputs: inputs, io: io)
            let export = try result.checkedExport()
            #expect(result.chunks.count == 38)
            #expect(export.files["data-header.bin"] == source.header)
            #expect(export.files["data-0000.bin"]?.prefix(2048) == source.header)
            let m = try #require(JSONSerialization.jsonObject(with: export.manifest) as? [String: Any])
            #expect(m["complete"] as? Bool == true)
            #expect(m["firmwareWritten"] as? Bool == false)
            #expect(m["firmwareRestoreEligible"] as? Bool == false)
            let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
            let saved = try await RecoveryBootSnapshotStore(root: root).saveSNESDataSnapshot(result)
            let checked = try SNESDataSnapshotPackage.load(directory: saved, expectedHWID: source.source.expectedHWID)
            #expect(checked.byteCount == 300*1024*1024)
            #expect(checked.sha256 == result.sha256)
            try checked.revalidate()
            #expect(throws: (any Error).self) { try SNESDataSnapshotPackage.load(directory: saved, expectedHWID: String(repeating: "1", count: 32)) }
            // Copy/link substitution, surplus files and edited safety flags cannot pass.
            let first = saved.appendingPathComponent("data-0000.bin")
            try FileManager.default.linkItem(at: first, to: root.appendingPathComponent("linked"))
            #expect(throws: (any Error).self) { try checked.revalidate() }
            try FileManager.default.removeItem(at: root.appendingPathComponent("linked"))
            try Data([1]).write(to: saved.appendingPathComponent("extra"))
            #expect(throws: (any Error).self) { try checked.revalidate() }
            try FileManager.default.removeItem(at: saved.appendingPathComponent("extra"))
            let manifest = saved.appendingPathComponent("manifest.json"), original = try Data(contentsOf: manifest)
            var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
            object["firmwareRestoreEligible"] = true
            try JSONSerialization.data(withJSONObject: object).write(to: manifest)
            #expect(throws: (any Error).self) { try checked.revalidate() }
            try original.write(to: manifest)
            try Data([0]).write(to: first)
            #expect(throws: (any Error).self) { try checked.revalidate() }

        } else {
            await #expect(throws: (any Error).self) { try await SNESDataSnapshotService(wait: {}).capture(source: source, inputs: inputs, io: io) }
        }
        let events = await io.base.events
        #expect(events.filter { $0 == "disconnect" }.count == 1)
        if ["inventory", "boot", "connect", "identity", "mounted-data", "kernel", "boot1", "partitions", "header", "hash"].contains(fault) { #expect(await io.chunks == 0) }
        if fault == "attachment" || fault == "chunk" || fault == "cancel" { #expect(await io.chunks == 1) }
    }
}
