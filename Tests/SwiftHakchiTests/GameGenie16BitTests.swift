import Foundation
import ImageIO
import Testing
@testable import SwiftHakchi
struct GameGenie16BitTests {
    @Test func independentUpstreamDecoderVectors() throws {
        for (code,address,value) in [("C2C9-4E2C",UInt32(0xB6A85F),UInt8(0xAD)),("D568-C34D",0xB882B8,7),("DF47-0915",0x192D35,1),("FFFF-FFFF",0x441414,0x11)] {
            let decoded=try #require(GameGenieSNES.decode(code));#expect(decoded.address==address && decoded.value==value)
            #expect(GameGenieSNES.encode(address:address,value:value)==code)
        }
        for (code,address,value) in [("ATBT-AA32",UInt32(0x338),UInt16(0x6004)),("AE3T-AACL",0x334A,1),("GJ6A-CA7A",0x138A0,0x6032),("AAAA-AAAB",1,0)] {
            let decoded=try #require(GameGenieGenesis.decode(code));#expect(decoded.address==address && decoded.value==value)
        }
        #expect(GameGenieSNES.decode("ZZZZ-ZZZZ")==nil && GameGenieGenesis.decode("OOOO-OOOO")==nil)
    }
    static func snes(hi:Bool=false,copier:Bool=false)->Data {
        var data=Data(repeating:0,count:2*1024*1024),h=hi ? 0xFFC0:0x7FC0
        data.replaceSubrange(h..<h+21,with:Data("SYNTHETIC TEST ROM   ".utf8))
        data[h+0x15]=hi ? 0x21:0x20;data[h+0x16]=0;data[h+0x17]=11;data[h+0x18]=0
        data[h+0x1C]=0xFF;data[h+0x1D]=0xFF;data[h+0x1E]=0;data[h+0x1F]=0
        data[h+0x3C]=0;data[h+0x3D]=0x80
        return (copier ? Data(repeating:0x5A,count:512):Data())+data
    }
    static func genesis()->Data {
        var data=Data(repeating:0,count:0x40000)
        data.replaceSubrange(0x100..<0x110,with:Data("SEGA GENESIS    ".utf8))
        data[0x1A4]=0;data[0x1A5]=3;data[0x1A6]=0xFF;data[0x1A7]=0xFF
        return data
    }
    @Test func patchesMappedBytesAndPreservesHeadersAndOriginal() throws {
        let source=Self.snes(copier:true),code=GameGenieSNES.encode(address:0x808123,value:0x45)
        let result=try GameGenieROMPatcher.patch(data:source,system:.snes,extension:"smc",codes:[code])
        #expect(result.data[512+0x123]==0x45 && result.data.prefix(512)==source.prefix(512))
        #expect(source[512+0x123]==0)
        #expect(throws:(any Error).self){try GameGenieROMPatcher.patch(data:source,system:.snes,extension:"smc",codes:[GameGenieSNES.encode(address:0x7E8123,value:1)])}
        let hi=try GameGenieROMPatcher.patch(data:Self.snes(hi:true),system:.snes,extension:"sfc",codes:[GameGenieSNES.encode(address:0xC12345,value:0x67)])
        #expect(hi.data[0x12345]==0x67)
        let md=Self.genesis(),patched=try GameGenieROMPatcher.patch(data:md,system:.genesis,extension:"md",codes:["ATBT-AA32"])
        #expect(patched.data[0x338]==0x60 && patched.data[0x339]==4 && patched.data[0x18E]==0x60 && patched.data[0x18F]==4)
        #expect(md[0x338]==0)
        #expect(throws:(any Error).self){try GameGenieROMPatcher.patch(data:md,system:.genesis,extension:"smd",codes:["ATBT-AA32"])}
        #expect(throws:(any Error).self){try GameGenieROMPatcher.patch(data:md,system:.genesis,extension:"md",codes:["9999-9999"])}
        #expect(throws:(any Error).self){try GameGenieROMPatcher.patch(data:md,system:.genesis,extension:"md",codes:["AAAA-AAAB"])}
    }
}
extension GameGenieTests {
    @Test(arguments:[GameGenieSystem.snes,.genesis])
    func sixteenBitCopiesAreOptInAndUpdateOnlyTheOwnedVariant(system:GameGenieSystem) throws {
        let root=try testDirectory();defer{try? FileManager.default.removeItem(at:root)}
        let config=AppConfig.shared,old=config.workspacePath,oldType=config.lastConsoleType,oldID=config.lastDeviceId
        let console:ConsoleType=system == .snes ? .snesUsa:.megaDrive
        config.workspacePath=root.path;config.lastConsoleType=console;config.lastDeviceId=""
        defer{config.workspacePath=old;config.lastConsoleType=oldType;config.lastDeviceId=oldID}
        let ext=system == .snes ? "sfc":"md",bytes=system == .snes ? GameGenie16BitTests.snes():GameGenie16BitTests.genesis()
        let source=root.appendingPathComponent("Example."+ext);try bytes.write(to:source)
        let manager=GameManagerService();try manager.importROMs(urls:[source],consoleType:console)
        let original=try #require(manager.games.first),session=try GameGenieWorkflow.open(game:original,manager:manager)
        var profile=try session.loadProfile()
        #expect(profile.codeSystem==system)
        #expect(throws:(any Error).self){try GameGenieVariantStore.save(session:session,profile:profile,manager:manager)}
        profile.effects=[.init(name:"Test",codes:[system == .snes ? GameGenieSNES.encode(address:0x808123,value:0x45):"ATBT-AA32"],enabled:true)]
        try session.saveProfile(profile,manager:manager);#expect(manager.games.count==1)
        let copy=try GameGenieVariantStore.save(session:session,profile:profile,manager:manager)
        #expect(manager.games.count==2 && copy.name.hasSuffix(" [Cheat Code]"))
        #expect(try Data(contentsOf:session.romURL)==bytes)
        let again=try GameGenieVariantStore.save(session:session,profile:profile,manager:manager)
        #expect(again.code==copy.code && manager.games.count==2)
        let reopened=try GameGenieWorkflow.open(game:again,manager:manager)
        profile.effects[0].enabled=false
        let off=try GameGenieVariantStore.save(session:reopened,profile:profile,manager:manager)
        #expect(off.code==copy.code && manager.games.count==2)
        #expect(try Data(contentsOf:URL(fileURLWithPath:off.romPath).appendingPathComponent(off.code+"."+ext))==bytes)
    }
}

extension GameGenie16BitTests {
    @Test func conflictsUnsupportedMapsAndHeaderWritesRefuseBeforeOutput() throws {
        let lo=Self.snes(),a=GameGenieSNES.encode(address:0x808123,value:1),b=GameGenieSNES.encode(address:0x808123,value:2)
        #expect(throws:GameGenieError.self){try GameGenieROMPatcher.patch(data:lo,system:.snes,extension:"sfc",codes:[a,b])}
        for address:UInt32 in [0x008000,0xF08123,0x807FDC] {
            if address==0x008000 {continue} // Ordinary reset-bank ROM is valid.
            #expect(throws:(any Error).self){try GameGenieROMPatcher.patch(data:lo,system:.snes,extension:"sfc",codes:[GameGenieSNES.encode(address:address,value:1)])}
        }
        var chip=lo;chip[0x7FD6]=0x23
        #expect(throws:(any Error).self){try GameGenieROMPatcher.patch(data:chip,system:.snes,extension:"sfc",codes:[a])}
        var ambiguous=lo;ambiguous.replaceSubrange(0xFFC0..<0x10000,with:Self.snes(hi:true)[0xFFC0..<0x10000])
        #expect(throws:(any Error).self){try GameGenieROMPatcher.patch(data:ambiguous,system:.snes,extension:"sfc",codes:[a])}
        let output=try GameGenieROMPatcher.patch(data:lo,system:.snes,extension:"sfc",codes:[a]).data
        let sum=output.reduce(UInt32(0)){$0+UInt32($1)}&65535
        #expect(UInt32(output[0x7FDE])+UInt32(output[0x7FDF])*256==sum)
        let odd=try GameGenieROMPatcher.patch(data:Self.genesis(),system:.genesis,extension:"md",codes:["AE3T-AACM"])
        #expect(odd.data[0x334A]==0 && odd.data[0x334B]==1)
    }
}


extension GameGenieTests {
    @Test(arguments: [GameGenieSystem.nes, .snes, .genesis])
    func cheatArtworkUsesConsoleBoxShape(system: GameGenieSystem) throws {
        let art = try GameGenieVariantStore.artwork(system: system)
        let source = try #require(CGImageSourceCreateWithData(art as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(system == .snes ? image.width > image.height : image.height > image.width)
        #expect(image.width <= 228 && image.height <= 204)
    }
}
