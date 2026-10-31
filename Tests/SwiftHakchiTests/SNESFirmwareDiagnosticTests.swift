import Foundation
import Testing
import os
@testable import SwiftHakchi

struct SNESFirmwareDiagnosticTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["none","early","write"])
    func writeRequiresReviewTokenAndPreservesUncertainState(_ fault:String) async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        if fault != "early" {try await j.preflightVerified()};try await j.close()
        let io=SNESFirmwareFakeIO(material:m,fault:fault),pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let args=["--write-snes-firmware",p.operation.path,p.reviewSHA256,"--confirm-reviewed-write"]
        do {
            let raw=try #require(try await SNESFirmwareDiagnostic.runIfPresent(args,loadInputs:{inputs},requireOperation:{_ in},checkHost:{},makeIO:{_,_ in io},detail:{_ in}))
            let result=try #require(JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any])
            #expect(fault=="none" && result["phase"] as? String=="readbackVerified")
        } catch {#expect(fault != "none")}
        let reopened=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        #expect(try await reopened.phase()==(fault=="none" ? .readbackVerified:fault=="early" ? .prepared:.uncertain))
        #expect(await io.writes==(fault=="early" ? 0:1))
        await #expect(throws:(any Error).self){try await reopened.beginWrite()}
        try await reopened.close()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func acceptanceRequiresStartupThenBuildsOriginalRestoreWithoutUSB() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        try await j.preflightVerified();_=try await j.beginWrite();try await j.readbackVerified();try await j.close()
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage),calls=OSAllocatedUnfairLock(initialState:0)
        let accept=["--accept-snes-firmware",p.operation.path,p.reviewSHA256,"--confirm-menu-and-gameplay"]
        await #expect(throws:(any Error).self){try await SNESFirmwareDiagnostic.runIfPresent(accept,loadInputs:{inputs},requireOperation:{_ in},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()},detail:{_ in})}
        let startup=StartupTrialSessionFake(expected:try .checked(m.trial),fault:"none",booted:true)
        let checked=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--check-snes-installed-startup",p.operation.path,p.reviewSHA256],loadInputs:{inputs},requireOperation:{_ in},checkHost:{},makeStartupIO:{_ in startup}))
        #expect(checked.contains("startupVerified"))
        _=try #require(try await SNESFirmwareDiagnostic.runIfPresent(accept,loadInputs:{inputs},requireOperation:{_ in},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()}))
        let raw=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--prepare-snes-stock-restore",p.operation.path,p.reviewSHA256],loadInputs:{inputs},requireOperation:{_ in},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()}))
        let result=try #require(JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any]),operation=try #require(result["operation"] as? String),review=try #require(result["reviewSHA256"] as? String)
        #expect(result["USBOpened"] as? Bool==false && result["firmwareWritten"] as? Bool==false)
        #expect(calls.withLock{$0}==0)
        let restore=try await SNESFirmwareJournal.reopen(operation:URL(fileURLWithPath:operation),reviewSHA256:review,recovery:inputs)
        let material=try await restore.verifiedMaterial()
        #expect(material.direction == .restore && material.target==m.original.active && material.preimage==m.target)
        try await restore.close()
    }
    @Test func retainsBoundedPrivateFailureCause() {
        let failure=SNESFirmwareCommandFailure(transport:-43,exit:19,output:Data("partial".utf8),errors:Data("driver refused".utf8))
        let detail=SNESFirmwareDiagnostic.failureDetail(failure)
        #expect(detail.contains("-43") && detail.contains("19"))
        #expect(!detail.isEmpty && detail.utf8.count<=16384)
    }

    @Test(arguments:[["--prepare-snes-firmware"],["--prepare-snes-firmware","relative"],["--write-snes-firmware","/tmp/anything",String(repeating:"0",count:64)],["--accept-snes-firmware","/tmp/anything",String(repeating:"0",count:64)],["--inspect-snes-firmware"],["--check-snes-installed-startup","relative",String(repeating:"0",count:64)],["--preflight-snes-firmware","/tmp/anything","bad"],["--preflight-snes-firmware","/tmp/anything",String(repeating:"0",count:64),"extra"]])
    func rejectsInvalidRequestsBeforeDependencies(_ args:[String]) async {
        let calls=OSAllocatedUnfairLock(initialState:0)
        await #expect(throws:(any Error).self){try await SNESFirmwareDiagnostic.runIfPresent(args,loadInputs:{calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()},root:{calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()},requireOperation:{_ in calls.withLock{$0+=1}},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()})}
        #expect(calls.withLock{$0}==0)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func refusesOversizedPreparationAndPreflightsOriginalRestore() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),root=try testDirectory(),request=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:request)}
        let path=request.appendingPathComponent("request.json");try JSONEncoder().encode(m.paths).write(to:path)
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let calls=OSAllocatedUnfairLock(initialState:0)
        await #expect(throws:(any Error).self) {try await SNESFirmwareDiagnostic.runIfPresent(["--prepare-snes-firmware",path.path],loadInputs:{inputs},root:{root},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()})}
        #expect(calls.withLock{$0}==0)
        #expect(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
        // A historically installed oversized image must still be restorable to its original bytes.
        let g=try await SNESFirmwareGuardFixtureCache.shared.value()
        let parentPrepared=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g)
        let parent=try SNESFirmwareJournal(operation:parentPrepared.operation,reviewSHA256:parentPrepared.reviewSHA256,material:m,guard:g)
        try await parent.preflightVerified();_=try await parent.beginWrite();try await parent.readbackVerified();try await parent.close()
        let raw=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--prepare-snes-stock-restore",parentPrepared.operation.path,parentPrepared.reviewSHA256],loadInputs:{inputs},requireOperation:{_ in},checkHost:{calls.withLock{$0+=1}},makeIO:{_,_ in calls.withLock{$0+=1};throw SNESRuntimeBinding.failure()}))
        #expect(calls.withLock{$0}==0)
        let result=try #require(try JSONSerialization.jsonObject(with:Data(raw.utf8)) as? [String:Any])
        let operation=try #require(result["operation"] as? String),review=try #require(result["reviewSHA256"] as? String)
        let output=try #require(try await SNESFirmwareDiagnostic.runIfPresent(["--preflight-snes-firmware",operation,review],loadInputs:{inputs},requireOperation:{url in #expect(url.deletingLastPathComponent().path==root.path)},checkHost:{calls.withLock{$0+=1}},makeIO:{material,_ in SNESFirmwareFakeIO(material:material,fault:"none")}))
        let checked=try #require(try JSONSerialization.jsonObject(with:Data(output.utf8)) as? [String:Any])
        #expect(checked["firmwareWritten"] as? Bool == false)
        #expect(checked["phase"] as? String == "preflightVerified")
        #expect(calls.withLock{$0}==1)
    }
}
