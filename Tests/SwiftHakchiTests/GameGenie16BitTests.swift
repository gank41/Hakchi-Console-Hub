import Foundation
import ImageIO
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi
struct GameGenie16BitTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_CONTRA_COPY"] != nil,
                   "Requires an explicitly supplied private console copy"))
    func suppliedContraCopyCanBePreparedAfterPatching() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_CONTRA_COPY"])
        let source = try Data(contentsOf: URL(fileURLWithPath: path))
        let code = GameGenieSNES.encode(address: 0x808123, value: source[0x123])
        let result = try GameGenieROMPatcher.patch(data: source, system: .snes, extension: "sfc", codes: [code])
        let prepared = try SNESCanoeImage.prepare(rom: result.data)
        #expect(prepared.presetID == 0x1036 && !prepared.isHiROM)
        let listed = try GameGenieROMPatcher.patch(data: source, system: .snes, extension: "sfc", codes: ["22BB-AD01"])
        #expect(try SNESCanoeImage.prepare(rom: listed.data).presetID == 0x1036)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == source)
    }
    @Test func contraTitleOverflowUsesLoROMAndNativePreset() throws {
        let h = 0x7fc0
        var source = Data(repeating: 0, count: 1024 * 1024)
        source.replaceSubrange(h..<(h + 22), with: Data("CONTRA3 THE ALIEN WARS".utf8))
        source[h + 0x16] = 0; source[h + 0x17] = 10; source[h + 0x18] = 0; source[h + 0x19] = 1
        source[h + 0x1c] = 0xff; source[h + 0x1d] = 0xff
        source[h + 0x3c] = 0; source[h + 0x3d] = 0x80
        let original = source
        let code = GameGenieSNES.encode(address: 0x808123, value: 0x45)
        let result = try GameGenieROMPatcher.patch(data: source, system: .snes, extension: "sfc", codes: [code])
        #expect(result.data[0x123] == 0x45 && source == original && result.data[h + 0x15] == 0x53)
        let packaged = try SNESCanoeImage.prepare(rom: result.data)
        #expect(!packaged.isHiROM && packaged.presetID == 0x1036)
        var other = source; other[h] = 65
        #expect(throws: (any Error).self) { try GameGenieROMPatcher.validate(data: other, system: .snes, extension: "sfc") }
    }
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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_3MB_ROM"] != nil,
                   "Requires an explicitly supplied private 3 MiB HiROM fixture"))
    func suppliedGameCreatesASeparateCheatCodeCopy() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_3MB_ROM"])
        let originalBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let config = AppConfig.shared, old = config.workspacePath, oldType = config.lastConsoleType
        config.workspacePath = root.path; config.lastConsoleType = .snesUsa
        defer { config.workspacePath = old; config.lastConsoleType = oldType }
        let fixture = root.appendingPathComponent("Example.smc")
        try originalBytes.write(to: fixture)
        let manager = GameManagerService(); try manager.importROMs(urls: [fixture], consoleType: .snesUsa)
        let original = try #require(manager.games.first)
        let session = try GameGenieWorkflow.open(game: original, manager: manager)
        var profile = try session.loadProfile()
        profile.effects = [.init(name: "Test", codes: ["6971-ED62"], enabled: true)]
        let copy = try GameGenieVariantStore.save(session: session, profile: profile, manager: manager)
        #expect(manager.games.count == 2)
        #expect(copy.name.hasSuffix(" [Cheat Code]"))
        #expect(try Data(contentsOf: session.romURL) == originalBytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == originalBytes)
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy.romPath).appendingPathComponent(copy.code + ".smc")) != originalBytes)
    }

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
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_UNEVEN_SNES_ROMS"] != nil,
                   "Requires explicitly supplied private game files"))
    func suppliedUnevenGamesPatchWithoutChangingTheirFiles() throws {
        let encoded = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_UNEVEN_SNES_ROMS"])
        let paths = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))
        #expect(paths.count >= 4)
        for path in paths {
            let url = URL(fileURLWithPath: path), source = try Data(contentsOf: url)
            let layout = try GameGenieROMPatcher.SNESLayout(source)
            let code = GameGenieSNES.encode(address: layout.hi ? 0xC08001 : 0x808001, value: 0x42)
            let output = try GameGenieROMPatcher.patch(data: source, system: .snes, extension: url.pathExtension, codes: [code]).data
            let rom = output.dropFirst(layout.prefix), length = rom.count
            let whole = 1 << (Int.bitWidth - 1 - length.leadingZeroBitCount), tail = length - whole
            let checksum = (rom.prefix(whole).reduce(UInt32(0)) { $0 + UInt32($1) }
                            + UInt32(whole / tail) * rom.suffix(tail).reduce(UInt32(0)) { $0 + UInt32($1) }) & 0xFFFF
            let header = layout.prefix + layout.header
            #expect((UInt32(output[header + 0x1E]) | UInt32(output[header + 0x1F]) << 8) == checksum)
            #expect(try Data(contentsOf: url) == source)
        }
    }

    @Test(arguments: [false, true], [1280, 1536, 2560, 3072])
    func ordinaryUnevenROMsUseTheirMirroredChecksum(hi: Bool, kibibytes: Int) throws {
        var rom = Self.snes(hi: hi)
        let length = kibibytes * 1024
        if length < rom.count { rom = Data(rom.prefix(length)) }
        if length > rom.count { rom.append(Data(repeating: 0x13, count: length - rom.count)) }
        let header = hi ? 0xFFC0 : 0x7FC0
        rom[header + 0x17] = length <= 2 * 1024 * 1024 ? 11 : 12
        let original = rom
        let code = GameGenieSNES.encode(address: hi ? 0xC08001 : 0x808001, value: 0x42)
        let patched = try GameGenieROMPatcher.patch(data: rom, system: .snes, extension: "sfc", codes: [code]).data
        let offset = hi ? 0x8001 : 1
        #expect(patched[offset] == 0x42)
        #expect(rom == original)
        let whole = 1 << (Int.bitWidth - 1 - length.leadingZeroBitCount)
        let tail = length - whole
        let mirrored = (patched.prefix(whole).reduce(UInt32(0)) { $0 + UInt32($1) }
                        + UInt32(whole / tail) * patched.suffix(tail).reduce(UInt32(0)) { $0 + UInt32($1) }) & 0xFFFF
        #expect((UInt32(patched[header + 0x1E]) | UInt32(patched[header + 0x1F]) << 8) == mirrored)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_SNES_PROFILE"] != nil,
                   "Requires explicitly supplied private game and profile fixtures"))
    @MainActor func suppliedProfileContainsDisabledValidEffectsForTheExactGame() throws {
        let profilePath = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_SNES_PROFILE"])
        let romPath = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_3MB_ROM"])
        let profile = try JSONDecoder().decode(GameGenieProfile.self, from: Data(contentsOf: URL(fileURLWithPath: profilePath)))
        try profile.validate(sha256: GameGenieWorkflow.digest(Data(contentsOf: URL(fileURLWithPath: romPath))))
        #expect(profile.codeSystem == .snes)
        #expect(profile.effects.count == 3)
        #expect(profile.enabledCodes.isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_SNES_CATALOG"] != nil,
                   "Requires an explicitly supplied private code catalog"))
    func suppliedCatalogFindsTheSelectedGameAndItsGroupedCodes() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_SNES_CATALOG"])
        let catalog = try GameGenieOfflineCatalog.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(catalog.searchGames("NBA Hang Time") == ["NBA Hang Time"])
        let rows = catalog.entries(game: "NBA Hang Time")
        #expect(rows.count == 3)
        #expect(rows.contains { $0.selectableCodes(system: .snes) == ["4071-EDF7", "6D9C-7DBF"] })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_3MB_ROM"] != nil,
                   "Requires an explicitly supplied private 3 MiB HiROM fixture"))
    func suppliedThreeMegabyteHiROMCanProduceAnIndependentPatch() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWIFTHAKCHI_TEST_3MB_ROM"])
        let source = try Data(contentsOf: URL(fileURLWithPath: path))
        let output = try GameGenieROMPatcher.patch(data: source, system: .snes, extension: "smc", codes: ["6971-ED62", "4071-EDF7", "6D9C-7DBF", "CED7-84DA"]).data
        #expect(output.count == source.count)
        #expect(output != source)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == source)
        let prefix = source.count % 32768 == 512 ? 512 : 0
        let rom = output.dropFirst(prefix)
        let checksum = (rom.prefix(2 * 1024 * 1024).reduce(UInt32(0)) { $0 + UInt32($1) }
                        + 2 * rom.suffix(1024 * 1024).reduce(UInt32(0)) { $0 + UInt32($1) }) & 0xFFFF
        #expect((UInt32(output[prefix + 0xFFDE]) | UInt32(output[prefix + 0xFFDF]) << 8) == checksum)
    }

    @Test(arguments: [false, true])
    func threeMegabyteHiROMUsesMirroredChecksumAndPreservesOriginal(copier: Bool) throws {
        var rom = Self.snes(hi: true)
        rom[0xFFD7] = 12
        rom.append(Data(repeating: 0x13, count: 1024 * 1024))
        let source = (copier ? Data(repeating: 0x5A, count: 512) : Data()) + rom
        let code = GameGenieSNES.encode(address: 0xE81234, value: 0x42)
        let output = try GameGenieROMPatcher.patch(data: source, system: .snes, extension: "smc", codes: [code]).data
        let prefix = copier ? 512 : 0
        #expect(output.count == source.count)
        #expect(output[prefix + 0x281234] == 0x42)
        #expect(source[prefix + 0x281234] == 0x13)
        #expect(output.prefix(prefix) == source.prefix(prefix))
        let bytes = output.dropFirst(prefix)
        let checksum = (bytes.prefix(2 * 1024 * 1024).reduce(UInt32(0)) { $0 + UInt32($1) }
                        + 2 * bytes.suffix(1024 * 1024).reduce(UInt32(0)) { $0 + UInt32($1) }) & 0xFFFF
        let headerChecksum = UInt32(output[prefix + 0xFFDE]) | UInt32(output[prefix + 0xFFDF]) << 8
        #expect(headerChecksum == checksum)
        #expect(throws: (any Error).self) {
            try GameGenieROMPatcher.patch(data: source, system: .snes, extension: "smc", codes: [GameGenieSNES.encode(address: 0xF81234, value: 0x42)])
        }
    }

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
