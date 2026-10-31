import Foundation
import Testing
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESActiveBoot2DiagnosticTests {
    @Test func invalidInputNeverConstructsIO() async throws {
        #expect(try await SNESActiveBoot2Diagnostic.runIfPresent(["--other"])==nil)
        for a in [["--snapshot-snes-active-boot2"],["--snapshot-snes-active-boot2","relative","/tmp/a","/tmp"],["--snapshot-snes-active-boot2","/missing","/tmp/a","/tmp"]] {
            await #expect(throws:(any Error).self) {
                try await SNESActiveBoot2Diagnostic.runIfPresent(a,checkHost:{Issue.record("Unexpected host check")},makeIO:{_,_ in fatalError("Unexpected IO")})
            }
        }
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"] != nil),arguments:["none","host","helper-change","read"])
    func savesOnlyVerifiedCopyOrInertFailure(_ fault:String) async throws {
        let source=try #require(try snesPreparationFixture()),helperPath=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"])
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let helper=root.appendingPathComponent("reader"),destination=root.appendingPathComponent("backups")
        try Data(contentsOf:URL(fileURLWithPath:helperPath)).write(to:helper)
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:false)
        let io=SNESActiveBoot2FakeIO(source:source,fault:fault)
        let args=["--snapshot-snes-active-boot2",source.source.directoryURL.path,helper.path,destination.path]
        do {
            let text=try await SNESActiveBoot2Diagnostic.runIfPresent(args,checkHost:{
                if fault=="host" {throw SNESRuntimeBinding.failure()}
                if fault=="helper-change" {try Data([1]).write(to:helper)}
            },makeIO:{_,_ in
                if fault=="host" || fault=="helper-change" {Issue.record("Unsafe input constructed IO")}
                return io
            })
            #expect(fault=="none")
            let output=try #require(text)
            let parsed=try #require(JSONSerialization.jsonObject(with:Data(output.utf8)) as? [String:Any])
            #expect(parsed["areaBytes"] as? Int==7340032 && parsed["firmwareWritten"] as? Bool==false)
        } catch {#expect(fault != "none")}
        let folders=try FileManager.default.contentsOfDirectory(at:destination,includingPropertiesForKeys:nil)
        #expect(folders.count==(["host","helper-change"].contains(fault) ? 0:1))
        if let dir=folders.first {
            let m=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:dir.appendingPathComponent("manifest.json"))) as? [String:Any])
            #expect(m["complete"] as? Bool==(fault=="none"))
            #expect(m["firmwareWritten"] as? Bool==false)
            #expect(await io.base.events.filter{$0=="disconnect"}.count==1)
        }
    }
}
