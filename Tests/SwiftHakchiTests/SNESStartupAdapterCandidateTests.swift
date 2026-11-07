import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func privateStartupAdapter() throws -> SNESStartupAdapterCandidate? {
    guard let material = try privateOriginalMenuMaterial() else { return nil }
    let env=ProcessInfo.processInfo.environment
    guard let data=env["SWIFTHAKCHI_SNES_CURRENT_DATA"],let hmod=env["SWIFTHAKCHI_SNES_CLOVERSHELL"],let bb=env["SWIFTHAKCHI_SNES_BUSYBOX"] else { return nil }
    let backup=try SNESDataSnapshotPackage.load(directory:URL(fileURLWithPath:data),expectedHWID:material.binding.expectedHWID)
    return try SNESStartupAdapterCandidate.prepare(material:material,daemonHmod:Data(contentsOf:URL(fileURLWithPath:hmod)),busybox:Data(contentsOf:URL(fileURLWithPath:bb)),backup:backup)
}
@Suite(.serialized)
struct SNESStartupAdapterCandidateTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_CANDIDATE"] != nil))
    func firstInstallRejectsBackupFromDifferentSetupWithoutBreakingLegacyReopen() throws {
        let env = ProcessInfo.processInfo.environment
        let candidatePath = try #require(env["SWIFTHAKCHI_SNES_STARTUP_CANDIDATE"])
        let dataPath = try #require(env["SWIFTHAKCHI_SNES_CURRENT_DATA"])
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let candidate = root.appendingPathComponent("SNES-Startup-Candidate-" + UUID().uuidString)
        let data = root.appendingPathComponent("SNES-Current-Data-" + UUID().uuidString)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: candidatePath), to: candidate)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: dataPath), to: data)
        let dataManifest = data.appendingPathComponent("manifest.json")
        var dataObject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: dataManifest)) as? [String: Any])
        var binding = try #require(dataObject["binding"] as? [String: Any])
        binding["sourceSnapshot"] = "SNES-US-Setup-11111111-1111-1111-1111-111111111111"
        dataObject["binding"] = binding
        try JSONSerialization.data(withJSONObject: dataObject, options: [.sortedKeys]).write(to: dataManifest)
        let candidateManifest = candidate.appendingPathComponent("manifest.json")
        var candidateObject = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: candidateManifest)) as? [String: Any])
        candidateObject["currentDataPath"] = data.path
        try JSONSerialization.data(withJSONObject: candidateObject, options: [.sortedKeys]).write(to: candidateManifest)
        let legacy = try SNESStartupAdapterCandidate.load(directory: candidate)
        #expect(throws: (any Error).self) { try SNESFirmwareMaterial.requireFirstInstallBackup(candidate: legacy) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    @MainActor func appPreparesFirstInstallCandidateFromMatchedSavedFilesWithoutConsole() async throws {
        let env = ProcessInfo.processInfo.environment
        func path(_ suffix: String) throws -> URL { URL(fileURLWithPath: try #require(env["SWIFTHAKCHI_SNES_" + suffix])) }
        func receipt(_ kind: SNESSetupRecordReceipt.Kind, _ url: URL) throws -> SNESSetupRecordReceipt {
            SNESSetupRecordReceipt(kind: kind, directory: url, manifestSHA256: BackupManifest.digest(try Data(contentsOf: url.appendingPathComponent("manifest.json"))))
        }
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let backup = try path("SETUP"), startup = try path("PREPARATION"), support = try path("MENU_SUPPORT")
        let components = try path("COMPONENTS"), runtime = try path("RUNTIME"), data = try path("CURRENT_DATA")
        let chain = try SNESSetupRecordChain(startup: receipt(.startup, startup), support: receipt(.menuSupport, support), components: receipt(.components, components))
        let store = try RecoveryBootSnapshotStore(root: root)
        let recovery = try await store.saveSNESRecoveryMaterial(SNESRecoveryMaterial.load(setup: backup))
        let helpers = try await store.saveSNESPortableHelpers()
        let config = AppConfig(); config.workspacePath = root.path; config.backupDirectoryPath = root.path; config.lastConsoleType = .snesUsa
        let app = AppState(startDeviceMonitoring: false, config: config, saveConfiguration: {},
            checkRecoveryHost: { Issue.record("Offline preparation accessed the console") })
        app.isPreparingSync = true
        let dataReceipt = SNESDataSnapshotReceipt(directory: data, manifestSHA256: BackupManifest.digest(try Data(contentsOf: data.appendingPathComponent("manifest.json"))))
        let hmod = try Data(contentsOf: path("CLOVERSHELL")), busybox = try Data(contentsOf: path("BUSYBOX"))
        let result = try await app.prepareSNESStartupCandidate(backup: receipt(.backup, backup), recovery: recovery, helpers: helpers, chain: chain,
            data: dataReceipt, runtime: receipt(.runtime, runtime), progress: { _ in }, loadTools: {
                try await SNESStartupToolInputs.acquire(fetch: { url, _ in url.lastPathComponent == "busybox" ? busybox : hmod })
            })
        #expect(result.kind == .candidate)
        let candidate = try SNESStartupAdapterCandidate.load(directory: result.directory)
        #expect(!candidate.hasMenuSupport)
        _ = try NativeSNESStartupPreflightIO(candidate: candidate)
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    func candidateExportReturnsVerifiedReceiptAndRemovesCompletionOnFailure() async throws {
        let candidate = try #require(try privateStartupAdapter())
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecoveryBootSnapshotStore(root: root)
        let receipt = try await store.saveSNESStartupCandidateWithReceipt(candidate)
        #expect(receipt.kind == .candidate)
        #expect(receipt.manifestSHA256 == BackupManifest.digest(try Data(contentsOf: receipt.directory.appendingPathComponent("manifest.json"))))
        #expect(try SNESStartupAdapterCandidate.load(directory: receipt.directory).image == candidate.image)
        do {
            _ = try await store.saveSNESStartupCandidateWithReceipt(candidate, verify: { _ in throw SNESRuntimeBinding.failure() })
            Issue.record("A failing final verifier must not return a completed candidate")
        } catch { }
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(directories.count == 2)
        let incomplete = try #require(directories.first(where: { $0 != receipt.directory }))
        #expect(!FileManager.default.fileExists(atPath: incomplete.appendingPathComponent("manifest.json").path))
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_XZ_CANDIDATE"] != nil))
    func preservesHistoricalXZForRecoveryEvidenceReconstruction() throws {
        let env=ProcessInfo.processInfo.environment
        let path=try #require(env["SWIFTHAKCHI_SNES_XZ_CANDIDATE"]),evidence=try #require(env["SWIFTHAKCHI_SNES_XZ_PREFLIGHT"])
        let directory=URL(fileURLWithPath:path),candidate=try SNESStartupAdapterCandidate.load(directory:directory)
        #expect(candidate.image==(try Data(contentsOf:directory.appendingPathComponent("startup.img"))))
        let p=try PinnedFELInputs.load()
        let historical=try PreparedSNESStartupTrial.prepare(candidate:candidate,evidence:URL(fileURLWithPath:evidence),recovery:.init(fes1:p.fes1,uboot:p.uboot,bootImage:p.bootImage))
        try historical.validateCurrent()
        #expect(historical.image==candidate.image)
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    func keepsStockStartupAndAddsOnlyNamespacedRAMSupport() throws {
        let candidate=try #require(try privateStartupAdapter())
        let original=try LegacyBootImageBuilder.inspect(candidate.material.support.setup.stock)
        let changed=try LegacyBootImageBuilder.inspect(candidate.image)
        #expect(changed.kernel==original.kernel)
        #expect(changed.header[64..<576]==original.header[64..<576])
        #expect(candidate.image.count<=4*1024*1024)
        try SNESColdBootPolicy.require(boot1:candidate.material.support.source.preparation.source.boot1,image:candidate.image)
        // These bytes already exist in the verified original root; don't package a duplicate pair.
        #expect(!changed.archive.entries.contains { ["swifthakchi/libc.so.6","swifthakchi/ld-linux-armhf.so.3"].contains($0.name) })
        for entry in original.archive.entries where entry.name != "sbin/init" {
            var expected=entry;if entry.name=="." { expected.fields[4]+=1 }
            #expect(changed.archive.entries.first { $0.name==entry.name }==expected)
        }
        let originalNames=Set(original.archive.entries.map(\.name))
        #expect(changed.archive.entries.filter { !originalNames.contains($0.name) }.allSatisfy { $0.name=="swifthakchi" || $0.name.hasPrefix("swifthakchi/") })
        #expect(changed.archive.entries.filter { $0.name.hasSuffix(".ko") }.isEmpty)
        let files=Dictionary(uniqueKeysWithValues:changed.archive.entries.map { ($0.name,$0.data) })
        #expect(files["swifthakchi/original-usb"]?.count==2002)
        let rows=String(decoding:try #require(files["swifthakchi/files.sha256"]),as:UTF8.self).split(separator:"\n")
        var names=Set<String>()
        for row in rows {
            let pair=row.components(separatedBy:"  ");#expect(pair.count==2)
            let name=String(pair[1].dropFirst());names.insert(name)
            #expect(BackupManifest.digest(try #require(files[name]))==pair[0])
        }
        #expect(names==Set(changed.archive.entries.filter { $0.fields[1]&0xf000==0x8000 && $0.name != "swifthakchi/files.sha256" }.map(\.name)))
        let exported=try candidate.checkedExport(),m=try #require(JSONSerialization.jsonObject(with:exported.manifest) as? [String:Any])
        #expect(m["scope"] as? String=="snes-original-profile-startup")
        for flag in ["bootEligible","firmwareInstallEligible","firmwareWritten","firmwareRestoreEligible"] { #expect(m[flag] as? Bool==false) }
        #expect(m["profilePolicy"] as? String=="original-existing-data")
        #expect(exported.files["startup.img"]==candidate.image)
        if let path=ProcessInfo.processInfo.environment["SWIFTHAKCHI_STARTUP_ARM_EXPORT"] {
            let root=URL(fileURLWithPath:path)
            for (name,bytes) in files where name.hasPrefix("swifthakchi/") {
                try bytes.write(to:root.appendingPathComponent(String(name.dropFirst(12))),options:.withoutOverwriting)
            }
        }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_CURRENT_DATA"] != nil))
    func savedCandidateReconstructsAndRejectsImageAndEligibilityEdits() async throws {
        let candidate=try #require(try privateStartupAdapter()),root=try testDirectory();defer { try? FileManager.default.removeItem(at:root) }
        let exported=try candidate.checkedExport(),folder=root.appendingPathComponent("SNES-Startup-Candidate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        for (name,bytes) in exported.files.merging(["manifest.json":exported.manifest],uniquingKeysWith: { $1 }) {
            try bytes.write(to:folder.appendingPathComponent(name));try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:folder.appendingPathComponent(name).path)
        }
        #expect(try SNESStartupAdapterCandidate.load(directory:folder).image==candidate.image)
        #expect(try SNESStartupAdapterCandidate.load(directory:folder, expectedManifestSHA256:BackupManifest.digest(exported.manifest)).image==candidate.image)
        #expect(throws:(any Error).self) { try SNESStartupAdapterCandidate.load(directory:folder, expectedManifestSHA256:String(repeating:"0",count:64)) }
        let receipt=SNESSetupRecordReceipt(kind:.candidate,directory:folder,manifestSHA256:BackupManifest.digest(exported.manifest))
        try AppState.requireSavedSNESCandidate(receipt,image:candidate.image)
        let wrong=SNESSetupRecordReceipt(kind:.candidate,directory:folder,manifestSHA256:String(repeating:"0",count:64))
        #expect(throws:(any Error).self) { try AppState.requireSavedSNESCandidate(wrong,image:candidate.image) }
        let imageURL=folder.appendingPathComponent("startup.img");var changed=candidate.image;changed[2048]^=1;try changed.write(to:imageURL)
        #expect(throws:(any Error).self) { try AppState.requireSavedSNESCandidate(receipt,image:candidate.image) }
        try candidate.image.write(to:imageURL)
        let manifest=folder.appendingPathComponent("manifest.json")
        var object=try #require(JSONSerialization.jsonObject(with:exported.manifest) as? [String:Any]);object["bootEligible"]=true
        try JSONSerialization.data(withJSONObject:object).write(to:manifest)
        #expect(throws:(any Error).self) { try SNESStartupAdapterCandidate.load(directory:folder) }
        try exported.manifest.write(to:manifest)
        var image=candidate.image;image[2048]^=1;try image.write(to:folder.appendingPathComponent("startup.img"))
        object=try #require(JSONSerialization.jsonObject(with:exported.manifest) as? [String:Any]);object["imageSHA256"]=BackupManifest.digest(image)
        try JSONSerialization.data(withJSONObject:object).write(to:manifest)
        #expect(throws:(any Error).self) { try SNESStartupAdapterCandidate.load(directory:folder) }
    }
}
