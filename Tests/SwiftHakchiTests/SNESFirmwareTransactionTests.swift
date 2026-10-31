import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

actor SNESFirmwareFakeIO:SNESFirmwareIO {
    let material:SNESFirmwareMaterial,base:SNESPreparationFakeIO,fault:String
    var active:Data,stages=0,verifications=0,writes=0,reads=0,geometryReads=0,kernelReads=0
    init(material:SNESFirmwareMaterial,fault:String) {self.material=material;self.fault=fault;active=material.preimage;base=SNESPreparationFakeIO(source:material.source,fault:fault)}
    func inventory() async throws->[RecoveryProbeUSBDevice] {if fault=="attachment",(stages>0 || reads>0) {return []};return try await base.inventory()}
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws {try await base.boot(inputs,expected:expected)}
    func connect(expected:RecoveryProbeUSBDevice) async throws {try await base.connect(expected:expected)}
    func observe() async->String {await base.observe()}
    func readBoot2(_ slot:RecoveryBootSlot)throws->RecoveryBoot2Read {
        kernelReads+=1
        if fault=="kernel" {return .image(Data([1]))}
        return .image(writes>0 ? material.targetImage:material.currentImage)
    }
    func readBoot1() async throws->Data {try await (base as any RecoveryProbeIO).readBoot1()}
    func readPartitions() async throws->Data {try await (base as any RecoveryProbeIO).readPartitions()}
    func readDataSuperblock() async throws->Data {try await (base as any RecoveryProbeIO).readDataSuperblock()}
    func geometry(challenge:UUID)->Data {geometryReads+=1;var bytes=material.geometry;if fault=="geometry" {bytes[20]^=1};return physicalFrameFixture(bytes,kind:.geometry,challenge:challenge)}
    func readActive(challenge:UUID)->Data {reads+=1;var bytes=active;if fault=="unstable",reads>1 {bytes[0]^=1};if fault=="preimage",writes==0 {bytes[bytes.count-1]^=1};if fault=="readback",writes>0 {bytes[0]^=1};return physicalFrameFixture(bytes,kind:.active,challenge:challenge)}
    func stage()throws {stages+=1;if fault=="stage" {throw SNESRuntimeBinding.failure()};if fault=="cancel-before" {throw CancellationError()}}
    func verifyStaged()throws {verifications+=1;if fault=="verify" {throw SNESRuntimeBinding.failure()}}
    func replace(_ permit:SNESFirmwareWritePermit)throws {
        writes+=1;active=material.target
        if fault=="write" {throw SNESRuntimeBinding.failure()}
        if fault=="write-evidence" {throw SNESFirmwareCommandFailure(transport:-73,exit:27,output:Data("partial".utf8),errors:Data("driver refused".utf8))}
        if fault=="cancel-after" {throw CancellationError()}
    }
    func disconnect() async {await base.disconnect()}
}
@Suite(.serialized)
struct SNESFirmwareTransactionTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil))
    func restoresExactOriginalRangeFromAcceptedInstall() async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer{try? FileManager.default.removeItem(at:root)}
        let prepared=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),parent=try SNESFirmwareJournal(operation:prepared.operation,reviewSHA256:prepared.reviewSHA256,material:m,guard:g)
        try await parent.preflightVerified();_=try await parent.beginWrite();try await parent.readbackVerified();try await parent.startupVerified();try await parent.acceptMenu()
        let restore=try SNESFirmwareMaterial.restore(accepted:await parent.acceptedInstall()),checked=try SNESFirmwareGuard.prepare(restore)
        try await parent.close()
        let p=try SNESFirmwareJournal.prepare(material:restore,root:root,guard:checked)
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let j=try await SNESFirmwareJournal.reopen(operation:p.operation,reviewSHA256:p.reviewSHA256,recovery:inputs)
        try await j.preflightVerified()
        let io=SNESFirmwareFakeIO(material:restore,fault:"none")
        _=try await SNESFirmwareTransaction(wait:{}).run(mode:.write,journal:j,guard:checked,inputs:inputs,io:io)
        #expect(try await j.phase() == .readbackVerified)
        #expect(await io.active==m.original.active)
        #expect(await io.writes==1)
        try await j.acceptMenu();try await j.close()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["preflight","none","identity","kernel","boot1","partitions","header","geometry","preimage","stage","verify","attachment","cancel-before","write","write-evidence","readback","cancel-after"])
    func fullPreflightOneDispatchAndUncertainOutcomesSurvive(_ fault:String) async throws {
        let m=try await SNESFirmwareFixtureCache.shared.value(),g=try await SNESFirmwareGuardFixtureCache.shared.value()
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:m,root:root,guard:g),j=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        let io=SNESFirmwareFakeIO(material:m,fault:fault),pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        if fault != "preflight" {try await j.preflightVerified()}
        do {
            _=try await SNESFirmwareTransaction(wait:{}).run(mode:fault=="preflight" ? .preflight:.write,journal:j,guard:g,inputs:inputs,io:io)
            #expect(["preflight","none"].contains(fault))
        } catch {
            #expect(!["preflight","none"].contains(fault))
            if ["write","write-evidence","readback","cancel-after"].contains(fault) {#expect(error is SNESFirmwareTransactionError)}
            if fault=="write-evidence" {let detail=SNESFirmwareDiagnostic.failureDetail(error);#expect(detail.contains("-73") && detail.contains("27"))}
        }
        let phase=try await j.phase()
        #expect(phase==(fault=="preflight" ? .preflightVerified:fault=="none" ? .readbackVerified:["write","write-evidence","readback","cancel-after"].contains(fault) ? .uncertain:.stoppedBeforeWrite))
        #expect(await io.writes==(["none","write","write-evidence","readback","cancel-after"].contains(fault) ? 1:0))
        #expect(await io.base.events.filter{$0=="disconnect"}.count==1)
        try await j.close()
        let reopened=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:m,guard:g)
        #expect(try await reopened.phase()==phase)
        if phase == .uncertain {await #expect(throws:(any Error).self){try await reopened.beginWrite()}}
        try await reopened.close()
    }
}
