import Foundation
import Darwin
import Testing
@testable import SwiftHakchi

struct SNESRecoveryBindingTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HC_BINDING_FIXTURE"] != nil))
    func actualCRecordMatchesVerifiedLibraryAndIndependentSession() throws {
        let root=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["HC_BINDING_FIXTURE"]),isDirectory:true)
        let region=root.appendingPathComponent("region",isDirectory:true)
        var st=stat();try #require(stat(region.path,&st)==0)
        let expected=SNESRecoveryBinding.Region(path:region.appendingPathComponent("ram.srm").path,type:0,device:UInt64(st.st_dev),inode:UInt64(st.st_ino))
        let dir=root.appendingPathComponent("CLV-U-ABCDE",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        try Data([1,2,3,4]).write(to:dir.appendingPathComponent("game.sfc"))
        var game=Game(code:"CLV-U-ABCDE",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local);game.romPath=dir.path
        let source=try SNESLibraryROMSource.capture(directory:dir,filename:"game.sfc").0
        let save=try SNESCompatibilitySave.create(payload:Data([42]),kind:.battery,gameCode:game.code,romSHA256:source.sha256)
        let descriptor=try Data(contentsOf:root.appendingPathComponent("binding"))
        let session=Data([1]+Array(repeating:0,count:15))
        func validate(_ d:Data,_ token:Data,_ epoch:UInt64,_ r:[SNESRecoveryBinding.Region]) throws -> SNESCompatibilitySave {
            try SNESRecoveryBinding.validate(descriptor:d,save:save.bytes,kind:.battery,game:game,source:source,session:token,epoch:epoch,regions:r)
        }
        #expect(try validate(descriptor,session,7,[expected]).payload==Data([42]))
        #expect(throws:(any Error).self){try validate(descriptor,Data(repeating:0,count:16),7,[expected])}
        #expect(throws:(any Error).self){try validate(descriptor,Data([2]+Array(repeating:0,count:15)),7,[expected])}
        #expect(throws:(any Error).self){try validate(descriptor,session,8,[expected])}
        #expect(throws:(any Error).self){try validate(descriptor,session,7,[.init(path:expected.path,type:0,device:expected.device,inode:expected.inode+1)])}
        #expect(throws:(any Error).self){try validate(descriptor,session,7,[.init(path:expected.path,type:1,device:expected.device,inode:expected.inode)])}
        #expect(throws:(any Error).self){try validate(descriptor,session,7,[.init(path:expected.path+"x",type:0,device:expected.device,inode:expected.inode)])}
        #expect(throws:(any Error).self){try validate(descriptor,session,7,[expected,expected])}
        var wrongGame=Game(code:"CLV-U-ZZZZZ",desktopContent:"Name=Other\n",consoleType:.snesUsa,source:.local);wrongGame.romPath=dir.path
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validate(descriptor:descriptor,save:save.bytes,kind:.battery,game:wrongGame,source:source,session:session,epoch:7,regions:[expected])}
        var foreign=game;foreign.consoleType = .nes
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validate(descriptor:descriptor,save:save.bytes,kind:.battery,game:foreign,source:source,session:session,epoch:7,regions:[expected])}
        let otherDir=root.appendingPathComponent("other/CLV-U-ABCDE",isDirectory:true)
        try FileManager.default.createDirectory(at:otherDir,withIntermediateDirectories:true)
        try Data([9,8,7,6]).write(to:otherDir.appendingPathComponent("other.sfc"))
        let otherSource=try SNESLibraryROMSource.capture(directory:otherDir,filename:"other.sfc").0
        var otherGame=game;otherGame.romPath=otherDir.path
        let otherLibrarySave=try SNESCompatibilitySave.create(payload:Data([42]),kind:.battery,gameCode:game.code,romSHA256:otherSource.sha256)
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validate(descriptor:descriptor,save:otherLibrarySave.bytes,kind:.battery,game:otherGame,source:otherSource,session:session,epoch:7,regions:[expected])}
        let other=try SNESCompatibilitySave.create(payload:Data([42]),kind:.battery,gameCode:game.code,romSHA256:String(repeating:"b",count:64))
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validate(descriptor:descriptor,save:other.bytes,kind:.battery,game:game,source:source,session:session,epoch:7,regions:[expected])}
        #expect(throws:(any Error).self){try validate(descriptor+Data([10]),session,7,[expected])}
        var tampered=descriptor;tampered[tampered.startIndex] ^= 1
        #expect(throws:(any Error).self){try validate(tampered,session,7,[expected])}
        try Data([4,3,2,1]).write(to:dir.appendingPathComponent("game.sfc"))
        #expect(throws:(any Error).self){try validate(descriptor,session,7,[expected])}
    }
}

struct SNESRecoveryBindingInvariantTests {
    @Test func boundedInputChecksMatchCGrammar() {
        #expect(SNESRecoveryBinding.validGameCode("CLV-U-ABCDE"))
        for code in ["CLV-U-ABCD", "CLV-U-abcdef", "CLV-P-ABCDE", "CLV-U-ABCD!", "CLV-U-ABCDE\n", String(repeating:"A",count:1_000_000)] {
            #expect(!SNESRecoveryBinding.validGameCode(code))
        }
        #expect(SNESRecoveryBinding.boundedPathBytes("/"+String(repeating:"a",count:1022))?.count == 1023)
        #expect(SNESRecoveryBinding.boundedPathBytes("/"+String(repeating:"a",count:1023)) == nil)
        #expect(SNESRecoveryBinding.boundedPathBytes("/"+String(repeating:"é",count:512)) == nil)
        #expect(SNESRecoveryBinding.boundedPathBytes("/"+String(repeating:"a",count:1_000_000)) == nil)
    }

    @Test(arguments:["alias","case"])
    func duplicatePhysicalRegionIsRejected(_ variant:String) throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir=root.appendingPathComponent("CLV-U-ABCDE",isDirectory:true)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try Data([1,2,3,4]).write(to:dir.appendingPathComponent("game.sfc"))
        var game=Game(code:"CLV-U-ABCDE",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local);game.romPath=dir.path
        let source=try SNESLibraryROMSource.capture(directory:dir,filename:"game.sfc").0
        let save=try SNESCompatibilitySave.create(payload:Data([42]),kind:.battery,gameCode:game.code,romSHA256:source.sha256)
        for reserved in ["intent-save.srm","INTENT-save.srm","checkpoint-save.srm","CHECKPOINT-save.srm"] {
            let r=SNESRecoveryBinding.Region(path:"/trusted/"+reserved,type:0,device:123,inode:456)
            let record=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(source.sha256)\n01000000000000000000000000000000\n7\n1\n0 123 456 \(r.path)\n".utf8)
            #expect(throws:(any Error).self){try SNESRecoveryBinding.validate(descriptor:record,save:save.bytes,kind:.battery,game:game,source:source,session:Data([1]+Array(repeating:0,count:15)),epoch:7,regions:[r])}
        }
        let first=SNESRecoveryBinding.Region(path:"/trusted/ram.srm",type:0,device:123,inode:456)
        let second=SNESRecoveryBinding.Region(path:variant == "alias" ? "/alias/ram.srm" : "/trusted/RAM.SRM",type:1,device:123,inode:456)
        let descriptor=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(source.sha256)\n01000000000000000000000000000000\n7\n2\n0 123 456 \(first.path)\n1 123 456 \(second.path)\n".utf8)
        let token=Data([1]+Array(repeating:0,count:15))
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validate(descriptor:descriptor,save:save.bytes,kind:.battery,game:game,source:source,session:token,epoch:7,regions:[first,second])}
        let distinct=SNESRecoveryBinding.Region(path:"/trusted/clock.rtc",type:1,device:123,inode:456)
        let valid=Data("HC-BINDING-1\nCLV-U-ABCDE\n\(source.sha256)\n01000000000000000000000000000000\n7\n2\n0 123 456 /trusted/ram.srm\n1 123 456 /trusted/clock.rtc\n".utf8)
        #expect(try SNESRecoveryBinding.validate(descriptor:valid,save:save.bytes,kind:.battery,game:game,source:source,session:token,epoch:7,regions:[first,distinct]).payload==Data([42]))
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validate(descriptor:valid+Data([10]),save:save.bytes,kind:.battery,game:game,source:source,session:token,epoch:7,regions:[first,distinct])}
        #expect(throws:(any Error).self){try SNESRecoveryBinding.validate(descriptor:valid,save:save.bytes,kind:.battery,game:game,source:source,session:token,epoch:8,regions:[first,distinct])}
    }
}
