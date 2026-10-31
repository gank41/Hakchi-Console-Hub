import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

actor SNESActiveBoot2FakeIO:SNESActiveBoot2IO {
    let source:SNESPreparationSource,base:SNESPreparationFakeIO,fault:String
    var reads=0,geometries=0
    let onGeometry:@Sendable () async throws->Void
    init(source:SNESPreparationSource,fault:String,onGeometry:@escaping @Sendable () async throws->Void={}){self.source=source;self.fault=fault;self.onGeometry=onGeometry;base=SNESPreparationFakeIO(source:source,fault:fault)}
    func inventory() async throws->[RecoveryProbeUSBDevice] {if fault=="attachment",reads>0 {return []};return try await base.inventory()}
    func boot(_ inputs:RecoveryBootInputs,expected:RecoveryProbeUSBDevice) async throws {try await base.boot(inputs,expected:expected)}
    func connect(expected:RecoveryProbeUSBDevice) async throws {try await base.connect(expected:expected)}
    func observe() async->String {await base.observe()}
    func readBoot2(_ slot:RecoveryBootSlot) async throws->RecoveryBoot2Read {try await (base as any RecoveryProbeIO).readBoot2(slot)}
    func readBoot1() async throws->Data {try await (base as any RecoveryProbeIO).readBoot1()}
    func readPartitions() async throws->Data {try await (base as any RecoveryProbeIO).readPartitions()}
    func readDataSuperblock() async throws->Data {try await (base as any RecoveryProbeIO).readDataSuperblock()}
    func disconnect() async {await base.disconnect()}
    func geometry(challenge:UUID) async throws->Data {
        geometries+=1;try await onGeometry()
        let bytes=physicalGeometryFixture(page:fault=="geometry" ? 4096:2048,blocks:fault=="changed-geometry" && geometries==2 ? 8192:4096)
        return physicalFrameFixture(bytes,kind:.geometry,challenge:challenge)
    }
    func readActive(challenge:UUID)throws->Data {
        reads+=1
        if fault=="cancel" {throw CancellationError()}
        if fault=="read" {throw SNESRuntimeBinding.failure()}
        var bytes=source.stock+Data(repeating:0xff,count:7340032-source.stock.count)
        if fault=="prefix" {bytes[0]^=1}
        if fault=="changed-range",reads==2 {bytes[bytes.count-1]^=1}
        return physicalFrameFixture(bytes,kind:.active,challenge:fault=="frame" ? UUID():challenge)
    }
}
@Suite(.serialized)
struct SNESActiveBoot2CaptureTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"] != nil),arguments:["none","inventory","boot","connect","identity","mounted-data","kernel","second-kernel","boot1","partitions","header","geometry","changed-geometry","read","prefix","changed-range","frame","cancel","attachment"])
    func readsOnlyStableSourceBoundPhysicalArea(_ fault:String) async throws {
        let path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_SETUP"]),helperPath=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"])
        let source=try SNESPreparationSource.load(SNESOfflineSource.load(snapshot:URL(fileURLWithPath:path))),helper=try SNESBoundedReadHelper.load(URL(fileURLWithPath:helperPath))
        let io=SNESActiveBoot2FakeIO(source:source,fault:fault),p=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:p.fes1,uboot:p.uboot,bootImage:p.bootImage)
        if fault=="none" {
            let result=try await SNESActiveBoot2SnapshotService(wait:{}).capture(source:source,inputs:inputs,helper:helper,io:io)
            let e=try result.checkedExport(),m=try #require(JSONSerialization.jsonObject(with:e.manifest) as? [String:Any])
            #expect(e.files["active-range.bin"]?.count==7340032 && e.files["active-range.bin"]?.prefix(source.stock.count)==source.stock)
            #expect(m["scope"] as? String=="snes-active-boot2-preimage" && m["complete"] as? Bool==true)
            for flag in ["firmwareWritten","firmwareInstallEligible","firmwareRestoreEligible","bootEligible"] {#expect(m[flag] as? Bool==false)}
            #expect(await io.reads==2);#expect(await io.geometries==2)
        } else {await #expect(throws:(any Error).self) {try await SNESActiveBoot2SnapshotService(wait:{}).capture(source:source,inputs:inputs,helper:helper,io:io)}}
        let events=await io.base.events
        #expect(events.filter{$0=="disconnect"}.count==1)
        #expect(events.filter{$0=="boot"}.count==(fault=="inventory" ? 0:1))
        if ["inventory","boot","connect","identity","mounted-data","kernel","second-kernel","boot1","partitions","header","geometry"].contains(fault) {#expect(await io.reads==0)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"] != nil),arguments:["source","helper","overlap"])
    func rechecksFilesAcrossSuspensionAndRefusesOverlappingCapture(_ fault:String) async throws {
        let original=try #require(try snesPreparationFixture()),path=try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_ACTIVE_READER"])
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let sourceDir=root.appendingPathComponent(original.source.directoryURL.lastPathComponent)
        try FileManager.default.copyItem(at:original.source.directoryURL,to:sourceDir)
        let source=try SNESPreparationSource.load(SNESOfflineSource.load(snapshot:sourceDir))
        let helperURL=root.appendingPathComponent("reader");try Data(contentsOf:URL(fileURLWithPath:path)).write(to:helperURL)
        let helper=try SNESBoundedReadHelper.load(helperURL),gate=SNESPhysicalCaptureGate(),service=SNESActiveBoot2SnapshotService(wait:{})
        let pins=try PinnedFELInputs.load(),inputs=RecoveryBootInputs(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage)
        let io=SNESActiveBoot2FakeIO(source:source,fault:"none",onGeometry:{
            if fault=="overlap" {await gate.pause()} else {
                try Data([1]).write(to:fault=="helper" ? helperURL:sourceDir.appendingPathComponent("boot1.bin"))
            }
        })
        let first=Task {try await service.capture(source:source,inputs:inputs,helper:helper,io:io)}
        if fault=="overlap" {
            await gate.waitUntilPaused()
            let second=SNESActiveBoot2FakeIO(source:source,fault:"none")
            await #expect(throws:LegacyInspectionError.self) {try await service.capture(source:source,inputs:inputs,helper:helper,io:second)}
            #expect(await second.base.events.isEmpty)
            await gate.release()
            _=try await first.value
        } else {
            do {_=try await first.value;Issue.record("Changed input accepted")} catch let failure as SNESActiveBoot2Failure {
                let export=try failure.checkedExport()
                let m=try #require(JSONSerialization.jsonObject(with:export.manifest) as? [String:Any])
                #expect(m["complete"] as? Bool==false)
            }
            #expect(await io.reads==0)
        }
        #expect(await io.base.events.filter{$0=="disconnect"}.count==1)
    }

}

private actor SNESPhysicalCaptureGate {
    private var reached=false,released=false,waiter:CheckedContinuation<Void,Never>?,reader:CheckedContinuation<Void,Never>?
    func pause() async {
        guard !released else{return};reached=true;waiter?.resume();waiter=nil
        await withCheckedContinuation {reader=$0}
    }
    func waitUntilPaused() async {if !reached {await withCheckedContinuation {waiter=$0}}}
    func release(){released=true;reader?.resume();reader=nil}
}
