import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

private actor SIDReaderSpy:FELSessionTransport {
    let fault:String
    let sid=Data([0x00,0x01,0x02,0x03,0x04,0x05,0x06,0x07,0x08,0x09,0x0a,0x0b,0x0c,0x0d,0x0e,0x0f])
    var image=Data(),events:[String]=[],ran=false
    init(_ fault:String){self.fault=fault}
    func open(){};func close(){};func verifyBoard()->UInt32 {0x166700}
    func initializeDRAM(fes1:Data){Issue.record("Identity read must not initialize DRAM")}
    func write(address:UInt32,data:Data){#expect(address==0x1000 && data.count==64);image=data;events.append("write")}
    func read(address:UInt32,count:Int)throws->Data {
        if address==0x01c23800 {events.append("byte-read");return Data([0x00,0,0,0,0x04,0,0,0,0x08,0,0,0,0x0c,0,0,0])}
        #expect(address==0x1000 && count==64);events.append("read")
        var b=image
        if ran {b.replaceSubrange(48..<64,with:sid)}
        if fault=="readback" || (fault=="output" && ran){b[0]^=1}
        return b
    }
    func execute(address:UInt32)throws {#expect(address==0x1000);events.append("execute");if fault=="execute" {throw FELError.execError(-4)};ran=true}
}
struct FELSIDReaderTests {
    @Test func cancellationBeforeStartDoesNotTouchMemory() async {
        let io=SIDReaderSpy("none")
        let task=Task {
            withUnsafeCurrentTask {$0?.cancel()}
            await #expect(throws:CancellationError.self) {try await FELSIDReader.read(from:io)}
        }
        await task.value
        #expect(await io.events.isEmpty)
    }
    @Test func matchesIndependentlyAssembledWordReadHelper() throws {
        #expect(BackupManifest.digest(FELSIDReader.image)=="3770876a52b11cdb2e51be92367c18cb2d82cf567873357fd7773b349f20cf2d")
    }
    @Test(arguments:["none","readback","execute","output"])
    func usesOnlyVerifiedFixedSRAMHelperAndReturnsAllSIDBits(_ fault:String) async throws {
        let io=SIDReaderSpy(fault)
        if fault=="none" {
            let sid=try await FELSIDReader.read(from:io)
            #expect(try SNESStartupSID.decode(sid)=="03020100070605040b0a09080f0e0d0c")
            #expect(await io.events==["write","read","execute","read"])
        } else {await #expect(throws:(any Error).self) {try await FELSIDReader.read(from:io)}}
        #expect(await io.events.contains("byte-read")==false)
        if fault=="readback" {#expect(await io.ran==false)}
    }
}
