import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

let startupTrialFEL=RecoveryProbeUSBDevice(vendorID:0x1f3a,productID:0xefe8,deviceVersion:0x2b3,deviceClass:0,locationID:42,product:"",registryEntryID:1)
let startupTrialUSB=RecoveryProbeUSBDevice(vendorID:0x1f3a,productID:0xefe8,deviceVersion:0x6a04,deviceClass:0,locationID:42,product:"Swift Hakchi SNES Startup",registryEntryID:2)
actor StartupTrialSessionFake:SNESStartupTrialIO {
    let expected:SNESStartupTrialExpectation,fault:String
    var booted:Bool,events:[String]=[],reports=0
    init(expected:SNESStartupTrialExpectation,fault:String,booted:Bool=false){self.expected=expected;self.fault=fault;self.booted=booted}
    func inventory()->[RecoveryProbeUSBDevice] {
        events.append("inventory")
        if fault=="inventory" {return [startupTrialFEL,startupTrialFEL]}
        if fault=="no-arrival",booted {return []}
        if fault=="attachment",reports>0 {return []}
        return [booted ? startupTrialUSB:startupTrialFEL]
    }
    func boot(expected:RecoveryProbeUSBDevice)throws {events.append("boot");#expect(expected==startupTrialFEL);if fault=="boot" {throw SNESRuntimeBinding.failure()};booted=true}
    func connect(expected:RecoveryProbeUSBDevice)throws {events.append("connect");#expect(expected==startupTrialUSB);if fault=="connect" {throw SNESRuntimeBinding.failure()}}
    func report(challenge:UUID)throws->Data {
        events.append("report");reports+=1
        if fault=="cancel" {throw CancellationError()}
        let id=(fault=="report" || (fault=="second" && reports==2)) ? UUID():challenge
        return startupTrialReportFixture(challenge:id,hwid:expected.hwid,runtime:expected.runtimeSHA256,wrapper:expected.wrapperSHA256)
    }
    func disconnect(){events.append("close")}
}
@Suite(.serialized)
struct SNESStartupTrialSessionTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil),arguments:[0,20000])
    func retainsBoundedFailureEvidenceEvenWhenSourceReceiptChanges(_ count:Int) async throws {
        let original=try await SNESStartupTrialFixtureCache.shared.trial(),root=try testDirectory()
        defer {try? FileManager.default.removeItem(at:root)}
        let receipt=root.appendingPathComponent(original.evidence.directory.lastPathComponent)
        try FileManager.default.copyItem(at:original.evidence.directory,to:receipt)
        let pins=try PinnedFELInputs.load()
        let trial=try PreparedSNESStartupTrial.prepare(candidate:original.candidate,evidence:receipt,recovery:.init(fes1:pins.fes1,uboot:pins.uboot,bootImage:pins.bootImage))
        let manifest=receipt.appendingPathComponent("manifest.json")
        var raw=try Data(contentsOf:manifest);raw.append(32);try raw.write(to:manifest)
        #expect(throws:(any Error).self) {try trial.validateCurrent()}
        let backups=root.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:false)
        let store=try RecoveryBootSnapshotStore(root:backups)
        let saved=try await store.saveSNESStartupTrialFailure(.init(stage:"checking-menu-and-startup",report:Data(repeating:65,count:count)),trial:trial)
        let evidence=count==0 ? Data():try Data(contentsOf:saved.appendingPathComponent("partial-report.bin"))
        let m=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:saved.appendingPathComponent("manifest.json"))) as? [String:Any])
        #expect(evidence.count==min(count,16384) && m["complete"] as? Bool==false && m["firmwareInstallEligible"] as? Bool==false)
        #expect(m["stage"] as? String=="checking-menu-and-startup")
        if count==0 {#expect(try FileManager.default.contentsOfDirectory(atPath:saved.path)==["manifest.json"])}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func recordsUnderlyingFailureBeforeAnyReportArrives() async throws {
        let trial=try await SNESStartupTrialFixtureCache.shared.trial(),io=StartupTrialSessionFake(expected:try .checked(trial),fault:"boot")
        do {_=try await SNESStartupTrialService(wait:{}).capture(trial:trial,io:io);Issue.record("Expected fake boot failure")}
        catch let failure as SNESStartupTrialFailure {
            let e=try failure.checkedExport(trial:trial),m=try #require(JSONSerialization.jsonObject(with:e.manifest) as? [String:Any])
            #expect(m["stage"] as? String=="temporary-startup")
            #expect((m["reason"] as? String)?.isEmpty==false)
            #expect(e.files.isEmpty)
        }
    }
    @Test func recognizesOnlyExpectedNewUSBDevice()throws {
        #expect(try SNESStartupTrialUSBPolicy.after([startupTrialUSB],original:startupTrialFEL)==startupTrialUSB)
        #expect(try SNESStartupTrialUSBPolicy.after([startupTrialFEL],original:startupTrialFEL)==nil)
        #expect(try SNESStartupTrialUSBPolicy.after([],original:startupTrialFEL)==nil)
        let wrong=RecoveryProbeUSBDevice(vendorID:0x1f3a,productID:0xefe8,deviceVersion:0x6a03,deviceClass:0,locationID:42,product:"Swift Hakchi SNES Original Menu Test",registryEntryID:3)
        #expect(throws:(any Error).self) {try SNESStartupTrialUSBPolicy.after([wrong],original:startupTrialFEL)}
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil),arguments:["none","inventory","boot","connect","report","second","attachment","cancel","no-arrival"])
    func runsOnceAndClosesOnEveryOutcome(_ fault:String) async throws {
        let trial=try await SNESStartupTrialFixtureCache.shared.trial(),io=StartupTrialSessionFake(expected:try .checked(trial),fault:fault)
        let service=SNESStartupTrialService(wait:{},attempts:2)
        if fault=="none" {
            let result=try await service.capture(trial:trial,io:io),e=try result.checkedExport(trial:trial)
            let m=try #require(JSONSerialization.jsonObject(with:e.manifest) as? [String:Any])
            #expect(result.phase=="started" && result.reports.count==2)
            #expect(m["firmwareWritten"] as? Bool==false && m["firmwareInstallEligible"] as? Bool==false && m["profileWritesPossible"] as? Bool==true)
        } else {await #expect(throws:(any Error).self) {try await service.capture(trial:trial,io:io)}}
        let events=await io.events
        #expect(events.filter{$0=="close"}.count==1)
        #expect(events.filter{$0=="boot"}.count==(fault=="inventory" ? 0:1))
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func afterGameCheckNeverRequestsAnotherBoot() async throws {
        let trial=try await SNESStartupTrialFixtureCache.shared.trial(),expected=try SNESStartupTrialExpectation.checked(trial)
        let first=StartupTrialSessionFake(expected:expected,fault:"none")
        let started=try await SNESStartupTrialService(wait:{}).capture(trial:trial,io:first)
        let io=StartupTrialSessionFake(expected:expected,fault:"none",booted:true)
        let result=try await SNESStartupTrialService(wait:{}).capture(trial:trial,started:started,io:io)
        #expect(result.phase=="after-gameplay")
        #expect(await io.events.contains("boot")==false)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func exportsExactReadOnlyReportForExecutionFixture() async throws {
        let trial=try await SNESStartupTrialFixtureCache.shared.trial()
        let script=try SNESStartupTrialCommands.script(trial:trial,challenge:UUID(uuidString:"11111111-1111-1111-1111-111111111111")!)
        #expect(script.isEmpty==false)
        if let p=ProcessInfo.processInfo.environment["SWIFTHAKCHI_STARTUP_TRIAL_EXPORT"] {try Data(script.utf8).write(to:URL(fileURLWithPath:p).appendingPathComponent("report.sh"),options:.withoutOverwriting)}
    }
}
