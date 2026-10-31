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
