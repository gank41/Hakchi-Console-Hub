import Foundation
import Testing
@testable import SwiftHakchi

private func sourceBuiltCoreFixture() throws -> (core:Data, archive:Data, notice:Data) {
    let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_COMPATIBILITY_BUILD"])
    let root=URL(fileURLWithPath:path), source=root.appendingPathComponent("snes9x2010-fe690dd321fa5a46b5234a2bde089d2518c62b0e")
    return (try Data(contentsOf:source.appendingPathComponent("snes9x2010_libretro.so")),
            try Data(contentsOf:root.appendingPathComponent("snes9x2010-fe690dd3.tar.gz")),
            try Data(contentsOf:source.appendingPathComponent("LICENSE.txt")))
}
struct SNESCompatibilityCorePackageTests {
    @Test func bundledCoreMatchesReviewedSourceAndNotice() throws {
        let package = try SNESCompatibilityCorePackage.loadBundled()
        #expect(package.core.count == 3_385_720)
        #expect(package.notice.count == 6_100)
        #expect(package.inspection.dependencies.contains("libc.so.6"))
    }
    @Test func unknownOrOversizedInputsNeverBecomeACorePackage() {
        for data in [Data(),Data(count:1024),Data(count:8*1024*1024+1)] {
            #expect(throws:(any Error).self) { try SNESCompatibilityCorePackage(core:data,sourceArchive:Data(),notice:Data()) }
        }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_COMPATIBILITY_BUILD"] != nil))
    func exactReproducedCoreKeepsItsSourceAndNoticeBinding() throws {
        let fixture=try sourceBuiltCoreFixture()
        let package=try SNESCompatibilityCorePackage(core:fixture.core,sourceArchive:fixture.archive,notice:fixture.notice)
        #expect(package.core==fixture.core)
        #expect(package.notice==fixture.notice)
        let manifest=try #require(JSONSerialization.jsonObject(with:package.manifest) as? [String:Any])
        let core=try #require(manifest["core"] as? [String:Any])
        let source=try #require(manifest["source"] as? [String:Any])
        let notice=try #require(manifest["notice"] as? [String:Any])
        #expect(core["sha256"] as? String == "ea4fab232ce2479c61099240d20196172051027fb7f55a9eabf2c5d9c4342286")
        #expect(source["archiveSHA256"] as? String == "7d2d2a21c2c00e6c5a83c8b51c18fccb6a9b3764584aa5ceb4b231e3a7c0ab6c")
        #expect(notice["sha256"] as? String == "2d5875c99c5895e9e8d104dd777dc7fdeee0fd96bed0bca38e83b90b480d2523")
        #expect(package.inspection.requiredVersions == ["GLIBC_2.4","GLIBC_2.7","GLIBC_2.17"])
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_COMPATIBILITY_BUILD"] != nil),
          arguments:["core-byte","core-short","core-extra","archive-byte","archive-short","notice-byte","notice-missing"])
    func changedArtifactSourceOrNoticeIsRejected(_ fault:String) throws {
        var f=try sourceBuiltCoreFixture()
        switch fault {
        case "core-byte":f.core[8192] ^= 1
        case "core-short":f.core.removeLast()
        case "core-extra":f.core.append(0)
        case "archive-byte":f.archive[100] ^= 1
        case "archive-short":f.archive.removeLast()
        case "notice-byte":f.notice[100] ^= 1
        default:f.notice=Data()
        }
        #expect(throws:(any Error).self) { try SNESCompatibilityCorePackage(core:f.core,sourceArchive:f.archive,notice:f.notice) }
    }
}
