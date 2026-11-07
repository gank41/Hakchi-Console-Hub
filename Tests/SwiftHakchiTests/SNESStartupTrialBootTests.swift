import Foundation
import Testing
import USBBridge
@testable import SwiftHakchi

actor SNESStartupTrialFixtureCache {
    static let shared=SNESStartupTrialFixtureCache()
    private var saved:PreparedSNESStartupTrial?
    func trial() async throws -> PreparedSNESStartupTrial {
        if let saved {return saved};let value=try await privateStartupTrial();saved=value;return value
    }
}
private actor StartupTrialFELSpy:FELSessionTransport {
    let trial:PreparedSNESStartupTrial,fault:String
    var events:[String]=[],uploads:[UInt32:Data]=[:],executions=0,sidReads=0
    init(trial:PreparedSNESStartupTrial,fault:String){self.trial=trial;self.fault=fault}
    func open(){events.append("open")}
    func close(){events.append("close")}
    func verifyBoard()->UInt32 {events.append("board");return fault=="board" ? 0:UInt32(EXPECTED_BOARD_ID)}
    func initializeDRAM(fes1:Data){events.append("dram");#expect(fes1==trial.fes1)}
    func write(address:UInt32,data:Data){events.append("write");uploads[address]=data}
    func read(address:UInt32,count:Int)throws->Data {
        if address==0x01c23800 {
            sidReads+=1;events.append("sid")
            var bytes=Data()
            let text=trial.expectedHWID
            for offset in stride(from:0,to:32,by:8) {
                let start=text.index(text.startIndex,offsetBy:offset),end=text.index(start,offsetBy:8)
                let word=try #require(UInt32(text[start..<end],radix:16))
                for shift in stride(from:0,to:32,by:8){bytes.append(UInt8(truncatingIfNeeded:word >> shift))}
            }
            #expect(count==16)
            if fault=="chip" || (fault=="late-chip" && sidReads==2){bytes[0]^=1}
            return bytes
        }
        if fault=="read-error" {throw SNESRuntimeBinding.failure()}
        var bytes=try #require(uploads[address]);#expect(bytes.count==count)
        if fault=="readback" && address==UInt32(TRANSFER_BASE_M){bytes[0]^=1}
        return bytes
    }
    func readHardwareIdentity()throws->Data {try read(address:0x01c23800,count:16)}
    func execute(address:UInt32)throws {executions+=1;events.append("execute");#expect(address==UInt32(UBOOT_BASE_M));if fault=="execute"{throw SNESRuntimeBinding.failure()}}
}
@Suite(.serialized)
struct SNESStartupTrialBootTests {
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil))
    func invalidatedAppEvidenceStopsBeforeRAMExecution() async throws {
        let trial = try await SNESStartupTrialFixtureCache.shared.trial(), spy = StartupTrialFELSpy(trial: trial, fault: "none")
        let flag = TrialValidationFlag(), service = FELService(makeSession: { spy })
        await #expect(throws: (any Error).self) {
            try await service.memboot(startupTrial: trial, progress: { status, _ in
                if status == "RAM images verified; requesting recovery boot…" { flag.invalidate() }
            }, validateInputs: { try flag.check() })
        }
        let events = await spy.events
        #expect(events.contains("dram")); #expect(!events.contains("execute")); #expect(events.last == "close")
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SWIFTHAKCHI_SNES_STARTUP_PREFLIGHT"] != nil),arguments:["none","chip","late-chip","readback","read-error","board","execute"])
    func checksChipBeforeUploadAndBeforeOneRAMExecution(_ fault:String) async throws {
        let trial=try await SNESStartupTrialFixtureCache.shared.trial(),spy=StartupTrialFELSpy(trial:trial,fault:fault)
        let service=FELService(makeSession:{spy})
        if fault=="none" {try await service.memboot(startupTrial:trial)}
        else {await #expect(throws:(any Error).self){try await service.memboot(startupTrial:trial)}}
        let events=await spy.events
        #expect(events.first=="open" && events.last=="close")
        #expect(events.filter{$0=="close"}.count==1)
        #expect(await spy.executions==(["none","execute"].contains(fault) ? 1:0))
        if fault=="chip" || fault=="board" {#expect(await spy.uploads.isEmpty);#expect(events.contains("dram")==false)}
        if fault=="none" {#expect(await spy.sidReads==2);#expect(await spy.uploads[UInt32(TRANSFER_BASE_M)]==trial.image)}
    }
}
private final class TrialValidationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var invalid = false
    func invalidate() { lock.lock(); defer { lock.unlock() }; invalid = true }
    func check() throws { lock.lock(); defer { lock.unlock() }; if invalid { throw SNESRuntimeBinding.failure() } }
}
