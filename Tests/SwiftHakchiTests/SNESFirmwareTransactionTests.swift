import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

actor SNESFirmwareFakeIO:SNESFirmwareIO,SNESDataHashIO {
    let material:SNESFirmwareMaterial,base:SNESPreparationFakeIO,fault:String
    var active:Data,stages=0,verifications=0,writes=0,reads=0,geometryReads=0,kernelReads=0,dataHashes=0
    private var holdInventory=false,holdDisconnect=false
    private var inventoryContinuation:CheckedContinuation<Void,Never>?,disconnectContinuation:CheckedContinuation<Void,Never>?
    var inventoryWaiting:Bool {inventoryContinuation != nil}
    var disconnectWaiting:Bool {disconnectContinuation != nil}
    func holdNextInventory() {holdInventory=true}
    func releaseInventory() {holdInventory=false;let pending=inventoryContinuation;inventoryContinuation=nil;pending?.resume()}
    func holdNextDisconnect() {holdDisconnect=true}
    func releaseDisconnect() {holdDisconnect=false;let pending=disconnectContinuation;disconnectContinuation=nil;pending?.resume()}
    init(material:SNESFirmwareMaterial,fault:String) {self.material=material;self.fault=fault;active=material.preimage;base=SNESPreparationFakeIO(source:material.source,fault:fault)}
    func inventory() async throws->[RecoveryProbeUSBDevice] {
        if holdInventory {holdInventory=false;await withCheckedContinuation {inventoryContinuation=$0}}
        if fault=="attachment",(stages>0 || reads>0) {return []};return try await base.inventory()
    }
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
    func dataHash(challenge:UUID)throws->Data {
        dataHashes += 1
        let count=try material.source.dataSnapshotPlan().byteCount
        let digest = fault == "changed-data" ? String(repeating:"0",count:64) : material.trial.candidate.backup.sha256
        return Data("SWIFTHAKCHI_SNES_DATA_HASH_V1 \(challenge.uuidString) \(count) \(digest)\n".utf8)
    }
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
    func simulateFirmwareWrite() { writes += 1; active = material.target }
    func disconnect() async {
        if holdDisconnect {holdDisconnect=false;await withCheckedContinuation {disconnectContinuation=$0}}
        await base.disconnect()
    }
}
/// Test-only observer proving the transaction reached its own close call.
actor SNESObservedFirmwareIO:SNESFirmwareIO,SNESReviewedPreflightIO,SNESReviewedSessionOwner {
    let base:NativeSNESFirmwareIO
    private(set) var disconnectCalls=0
    init(_ base:NativeSNESFirmwareIO){self.base=base}
    func beginReviewedSession() async throws->SNESReviewedSessionLease {try await base.beginReviewedSession()}
    func inventory() async throws->[RecoveryProbeUSBDevice] {try await base.inventory()}
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws {try await base.boot(inputs,expected:expected)}
    func connect(expected:RecoveryProbeUSBDevice) async throws {try await base.connect(expected:expected)}
    func observe() async throws->String {try await base.observe()}
    func readBoot2(_ slot:RecoveryBootSlot) async throws->RecoveryBoot2Read {try await base.readBoot2(slot)}
    func readBoot1() async throws->Data {try await base.readBoot1()}
    func readPartitions() async throws->Data {try await base.readPartitions()}
    func readDataSuperblock() async throws->Data {try await base.readDataSuperblock()}
    func geometry(challenge:UUID) async throws->Data {try await base.geometry(challenge:challenge)}
    func readActive(challenge:UUID) async throws->Data {try await base.readActive(challenge:challenge)}
    func stage() async throws {try await base.stage()}
    func verifyStaged() async throws {try await base.verifyStaged()}
    func replace(_ permit:SNESFirmwareWritePermit) async throws {try await base.replace(permit)}
    func verifyReviewedPreflight(context:RecoverySessionContext,header:Data,reservation:UUID) async throws->SNESReviewedPreflightProof {
        try await base.verifyReviewedPreflight(context:context,header:header,reservation:reservation)
    }
    func disconnect() async {disconnectCalls += 1;await base.disconnect()}
}
@Suite(.serialized)
struct SNESFirmwareTransactionTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_PREIMAGE"] != nil),arguments:["disconnect-before","cancel-before","disconnect-after"])
    func interruptedNativeDispatchLeavesDurableUncertainty(_ fault:String) async throws {
        let installed=try await SNESFirmwareFixtureCache.shared.value(),installGuard=try await SNESFirmwareGuardFixtureCache.shared.value(),root=try testDirectory()
        defer {try? FileManager.default.removeItem(at:root)}
        let p=try SNESFirmwareJournal.prepare(material:installed,root:root,guard:installGuard)
        let parent=try SNESFirmwareJournal(operation:p.operation,reviewSHA256:p.reviewSHA256,material:installed,guard:installGuard)
        try await parent.preflightVerified();_=try await parent.beginWrite();try await parent.readbackVerified()
        let material=try SNESFirmwareMaterial.restore(installed:await parent.restorableInstall()),checked=try SNESFirmwareGuard.prepare(material)
        try await parent.close()
        let child=try SNESFirmwareJournal.prepare(material:material,root:root,guard:checked)
        let journal=try SNESFirmwareJournal(operation:child.operation,reviewSHA256:child.reviewSHA256,material:material,guard:checked)
        try await journal.preflightVerified()
        let libraryRoot=try testDirectory();defer {try? FileManager.default.removeItem(at:libraryRoot)}
        let base=SNESFirmwareFakeIO(material:material,fault:"none"),shell=SNESFirmwareShellFake(material:material,fault:"none")
        let io=try NativeSNESFirmwareIO(material:material,guard:checked,base:base,shell:shell,testLibraryRoot:libraryRoot)
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        await shell.holdFirmwareDispatch(before:fault != "disconnect-after")
        let task=Task {try await SNESFirmwareTransaction(wait:{}).run(mode:.write,journal:journal,guard:checked,inputs:inputs,io:io)}
        let deadline=ContinuousClock.now.advanced(by:.seconds(60))
        while !(await shell.firmwareWaiting) && ContinuousClock.now < deadline && !Task.isCancelled {try? await Task.sleep(for:.milliseconds(10))}
        guard !Task.isCancelled,await shell.firmwareWaiting else {
            task.cancel();await shell.releaseFirmwareDispatch();await io.disconnect();_=try? await task.value
            Issue.record("Transaction did not reach the guarded writer");try await journal.close();return
        }
        if fault=="cancel-before" {task.cancel()} else {await io.disconnect()}
        await shell.releaseFirmwareDispatch()
        do { _=try await task.value;Issue.record("Interrupted transaction reported success") }
        catch {#expect(error is SNESFirmwareTransactionError)}
        #expect(await shell.writeCalls == (fault=="disconnect-after" ? 1:0))
        #expect(try await journal.phase() == .uncertain)
        await #expect(throws:(any Error).self) {try await journal.beginWrite()}
        try await journal.close()
        let reopened=try await SNESFirmwareJournal.reopen(operation:child.operation,reviewSHA256:child.reviewSHA256,recovery:inputs)
        #expect(try await reopened.phase() == .uncertain)
        await #expect(throws:(any Error).self) {try await reopened.beginWrite()}
        try await reopened.close()
    }
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
