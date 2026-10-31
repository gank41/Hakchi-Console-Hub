import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESFirmwareMaterialTests {
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
        #expect(BackupManifest.digest(writer.bytes)==SNESBoundedWriteHelper.sha256)
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
    func buildsExactCompleteInputFromVerifiedOriginalAndTestedCandidate() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),payload=try m.input()
        #expect(m.direction == .install && m.parentReviewSHA256==nil)
        #expect(payload.count==14680088)
        #expect(payload.prefix(24)==m.geometry)
        #expect(payload[24..<7340056]==m.original.active)
        #expect(payload[7340056...]==m.target)
        #expect(m.target.prefix(6285312)==m.trial.image)
        #expect(m.target[6285312..<6291456].allSatisfy{$0==255})
        #expect(m.target[6291456...]==m.original.active[6291456...])
        #expect(m.changedUnits.allSatisfy{(0..<48).contains($0)} && !m.changedUnits.isEmpty)
        try m.validateCurrent()
    }
}
