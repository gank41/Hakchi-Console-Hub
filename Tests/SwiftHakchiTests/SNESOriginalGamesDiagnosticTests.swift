import Foundation
import Testing
import os
@testable import SwiftHakchi

@Suite(.serialized)
struct SNESOriginalGamesDiagnosticTests {
    @Test(arguments:[[],["--capture-snes-original-games"],["--capture-snes-original-games","relative",String(repeating:"a",count:64),"/tmp"],["--capture-snes-original-games","/tmp","bad","/tmp"],["--capture-snes-original-games","/tmp",String(repeating:"a",count:64),"relative"]])
    func malformedArgumentsNeverLoadInputsOrConstructConnection(_ args:[String]) async throws {
        let calls=OSAllocatedUnfairLock(initialState:0)
        do {
            let result=try await SNESOriginalGamesDiagnostic.runIfPresent(args,loadInputs:{calls.withLock{$0+=1};throw SNESOriginalGamesFrame.failure()},makeIO:{_ in calls.withLock{$0+=1};throw SNESOriginalGamesFrame.failure()})
            #expect(args.isEmpty && result==nil)
        } catch {#expect(!args.isEmpty)}
        #expect(calls.withLock{$0}==0)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["none","prepared","readback","host"])
    func onlyAcceptedInstallCanCaptureAndJournalIsUnchanged(_ fault:String) async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer {try? FileManager.default.removeItem(at:root)}
        let journals=root.appendingPathComponent("journals");try FileManager.default.createDirectory(at:journals,withIntermediateDirectories:false)
        let p=try SNESFirmwareJournal.prepare(material:m,root:journals,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        if fault != "prepared" {try await j.preflightVerified();_=try await j.beginWrite();try await j.readbackVerified()}
        if fault=="none" || fault=="host" {try await j.startupVerified();try await j.acceptMenu()}
        let phase=try await j.phase();try await j.close()
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage),calls=OSAllocatedUnfairLock(initialState:0)
        let io=OriginalGamesFake(expected:try .checked(m.trial),fault:"none"),backups=root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:false)
        let args=["--capture-snes-original-games",p.operation.path,p.reviewSHA256,backups.path]
        do {
            let raw=try #require(try await SNESOriginalGamesDiagnostic.runIfPresent(args,loadInputs:{inputs},requireOperation:{_ in},checkHost:{if fault=="host" {throw SNESOriginalGamesFrame.failure()}},makeIO:{_ in calls.withLock{$0+=1};return io}))
            #expect(fault=="none")
            let object=try #require(JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any])
            let saved=URL(fileURLWithPath:try #require(object["directory"] as? String))
            let names=try FileManager.default.contentsOfDirectory(atPath:saved.path)
            #expect(Set(names)==Set(["manifest.json","catalog.frame","report-0.txt","report-1.txt"]))
            let mode=try FileManager.default.attributesOfItem(atPath:saved.path)[.posixPermissions] as? Int
            #expect(mode==0o700)
            for name in names {#expect(try FileManager.default.attributesOfItem(atPath:saved.appendingPathComponent(name).path)[.posixPermissions] as? Int==0o600)}
        } catch {#expect(fault != "none","Unexpected: \(error)")}
        #expect(calls.withLock{$0}==(fault=="none" ? 1:0))
        let reopened=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        #expect(try await reopened.phase()==phase);try await reopened.close()
    }
}
