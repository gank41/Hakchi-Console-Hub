import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

actor OriginalGamesFake: SNESOriginalGamesIO {
    let expected:SNESStartupTrialExpectation,fault:String
    let mutate: @Sendable () throws -> Void
    var events:[String]=[],reports=0,captured=false
    init(expected:SNESStartupTrialExpectation,fault:String,mutate:@escaping @Sendable () throws -> Void={}) {self.expected=expected;self.fault=fault;self.mutate=mutate}
    func inventory() -> [RecoveryProbeUSBDevice] {
        events.append("inventory")
        if fault=="inventory" {return [startupTrialUSB,startupTrialUSB]}
        if fault=="fingerprint" {return [startupTrialFEL]}
        if fault=="attachment" && captured {return []}
        return [startupTrialUSB]
    }
    func connect(expected:RecoveryProbeUSBDevice)throws {events.append("connect");if fault=="connect" {throw SNESOriginalGamesFrame.failure()}}
    func report(challenge:UUID)throws->Data {
        reports+=1;events.append("report")
        let id=(fault=="report" || fault=="second" && reports==2) ? UUID():challenge
        var data=startupTrialReportFixture(challenge:id,hwid:expected.hwid,runtime:expected.runtimeSHA256,wrapper:expected.wrapperSHA256)
        if fault=="pid" && reports==2 {data=Data(String(decoding:data,as:UTF8.self).replacingOccurrences(of:"MCP_PID=101",with:"MCP_PID=103").utf8)}
        return data
    }
    func originalGames(challenge:UUID)throws->Data {
        captured=true;events.append("catalog")
        if fault=="cancel" {throw CancellationError()}
        try mutate()
        var data=originalGamesFrameFixture(challenge:fault=="challenge" ? UUID():challenge)
        // Replace identity without interpreting or executing catalog contents.
        let old=Data(("HWID "+String(repeating:"1",count:32)).utf8),new=Data(("HWID "+expected.hwid).utf8)
        if let range=data.range(of:old) {data.replaceSubrange(range,with:new)}
        if fault=="frame" {data.append(0)}
        return data
    }
    func disconnect(){events.append("close")}
}

@Suite(.serialized)
struct SNESOriginalGamesCaptureTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func editedSourceHelperPreventsCatalogResult() async throws {
        let base=try await SNESFirmwareFixtureCache.shared.value(),root=try testDirectory()
        defer {try? FileManager.default.removeItem(at:root)}
        let writer=root.appendingPathComponent("writer");try FileManager.default.copyItem(at:base.writer.location,to:writer)
        let p=base.paths,paths=SNESFirmwarePaths(candidate:p.candidate,preflight:p.preflight,started:p.started,played:p.played,original:p.original,reader:p.reader,writer:writer.path)
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let m=try SNESFirmwareMaterial.install(paths:paths,recovery:inputs),g=try SNESFirmwareGuard.prepare(m)
        let journalRoot=root.appendingPathComponent("journals");try FileManager.default.createDirectory(at:journalRoot,withIntermediateDirectories:false)
        let prepared=try SNESFirmwareJournal.prepare(material:m,root:journalRoot,guard:g),j=try SNESFirmwareJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:m,guard:g)
        try await j.preflightVerified();_=try await j.beginWrite();try await j.readbackVerified();try await j.startupVerified();try await j.acceptMenu()
        let accepted=try await j.acceptedInstall(),io=OriginalGamesFake(expected:try .checked(m.trial),fault:"none",mutate:{let h=try FileHandle(forWritingTo:writer);try h.seekToEnd();try h.write(contentsOf:Data([0]));try h.close()})
        await #expect(throws:(any Error).self) {try await SNESOriginalGamesCapture().capture(accepted:accepted,guard:g,io:io)}
        #expect(await io.events.filter{$0=="close"}.count==1)
        try await j.close()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["none","inventory","fingerprint","connect","report","second","attachment","cancel","challenge","frame","pid"])
    func capturesOnlyAcceptedStableConnectionAndClosesOnce(_ fault:String) async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer {try? FileManager.default.removeItem(at:root)}
        let journals=root.appendingPathComponent("journals");try FileManager.default.createDirectory(at:journals,withIntermediateDirectories:false)
        let p=try SNESFirmwareJournal.prepare(material:m,root:journals,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        try await j.preflightVerified();_=try await j.beginWrite();try await j.readbackVerified();try await j.startupVerified();try await j.acceptMenu()
        let accepted=try await j.acceptedInstall(),before=try FileManager.default.contentsOfDirectory(atPath:p.operation.path)
        let io=OriginalGamesFake(expected:try .checked(m.trial),fault:fault)
        do {
            let result=try await SNESOriginalGamesCapture().capture(accepted:accepted,guard:g,io:io)
            #expect(fault=="none")
            let e=try result.checkedExport(),manifest=try #require(JSONSerialization.jsonObject(with:e.manifest) as? [String:Any])
            #expect(Set(e.files.keys)==Set(["catalog.frame","report-0.txt","report-1.txt"]))
            #expect(manifest["complete"] as? Bool==true && manifest["syncEligible"] as? Bool==false)
            #expect(manifest["firmwareWritten"] as? Bool==false)
            let frame=try SNESOriginalGamesFrame(try #require(e.files["catalog.frame"]),binding:m.trial.candidate.material.binding,challenge:try #require(UUID(uuidString:manifest["catalogChallenge"] as? String ?? "")))
            #expect(frame.entries.count==2)
            let backups=root.appendingPathComponent("Backups");try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:false)
            let store=try RecoveryBootSnapshotStore(root:backups),saved=try await store.saveSNESOriginalGames(result)
            let manifestBefore=try Data(contentsOf:saved.appendingPathComponent("manifest.json"))
            let failed=try RecoveryBootSnapshotStore(root:backups,synchronize:{_ in -1})
            await #expect(throws:(any Error).self) {try await failed.saveSNESOriginalGames(result)}
            #expect(try Data(contentsOf:saved.appendingPathComponent("manifest.json"))==manifestBefore)
            for name in try FileManager.default.contentsOfDirectory(atPath:backups.path) where name != saved.lastPathComponent {
                #expect(!FileManager.default.fileExists(atPath:backups.appendingPathComponent(name+"/manifest.json").path))
            }

        } catch {#expect(fault != "none","Unexpected: \(error)")}
        #expect(await io.events.filter{$0=="close"}.count==1)
        #expect(try await j.phase() == .menuAccepted)
        #expect(try FileManager.default.contentsOfDirectory(atPath:p.operation.path)==before)
        try await j.close()
    }
}
