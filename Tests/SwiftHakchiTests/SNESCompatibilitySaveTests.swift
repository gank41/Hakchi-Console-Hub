import Foundation
import Testing
@testable import SwiftHakchi

struct SNESCompatibilitySaveTests {
    private let rom=String(repeating:"a",count:64)
    @Test(arguments:[SNESCompatibilitySave.Kind.battery,.suspend])
    func ownEngineSaveRoundTripsWithoutChangingPayload(_ kind:SNESCompatibilitySave.Kind)throws {
        let payload=Data([0,255,32,13,10,0])
        let save=try SNESCompatibilitySave.create(payload:payload,kind:kind,gameCode:"CLV-U-ABCDE",romSHA256:rom)
        let reopened=try SNESCompatibilitySave(save.bytes,kind:kind,gameCode:"CLV-U-ABCDE",romSHA256:rom)
        #expect(reopened.payload==payload)
        #expect(payload==Data([0,255,32,13,10,0]))
    }
    @Test(arguments:["rom","game","kind","payload","truncated","trailing","foreign","huge"])
    func foreignOrChangedSaveNeverBecomesThisGamesState(_ fault:String)throws {
        let save=try SNESCompatibilitySave.create(payload:Data([1,2,3]),kind:.suspend,gameCode:"CLV-U-ABCDE",romSHA256:rom)
        var bytes=save.bytes
        if fault=="payload" {bytes[bytes.count-1] ^= 1}
        if fault=="truncated" {bytes.removeLast()}
        if fault=="trailing" {bytes.append(0)}
        if fault=="foreign" {bytes=Data("#!s9xsnp:0006\noriginal foreign save".utf8)}
        if fault=="huge" {bytes=Data(count:16*1024*1024+4097)}
        #expect(throws:(any Error).self) {try SNESCompatibilitySave(bytes,kind:fault=="kind" ? .battery:.suspend,
            gameCode:fault=="game" ? "CLV-U-XYZAB":"CLV-U-ABCDE",romSHA256:fault=="rom" ? String(repeating:"b",count:64):rom)}
    }
    @Test(arguments:["CLV-P-ABCDE","../ABCDE","CLV-U-ABCD","CLV-U-abcde","CLV-U-ABCDE\n"])
    func originalGamesAndUnboundIdentitiesCannotCreateCompatibilitySaves(_ code:String) {
        #expect(throws:(any Error).self) {try SNESCompatibilitySave.create(payload:Data([1]),kind:.battery,gameCode:code,romSHA256:rom)}
    }
}

struct SNESCompatibilitySaveHeaderTests {
    @Test(arguments:["engine","version","unknown","size"])
    func validJSONWithWrongIdentityOrUnknownFieldsIsStillRefused(_ fault:String)throws {
        let rom=String(repeating:"a",count:64)
        let original=try SNESCompatibilitySave.create(payload:Data([1,2,3]),kind:.suspend,gameCode:"CLV-U-ABCDE",romSHA256:rom)
        let first=try #require(original.bytes.firstIndex(of:10)),rest=original.bytes.suffix(from:original.bytes.index(after:first))
        let second=try #require(rest.firstIndex(of:10)),count=try #require(Int(String(decoding:rest[..<second],as:UTF8.self)))
        let body=rest.suffix(from:rest.index(after:second))
        var object=try #require(JSONSerialization.jsonObject(with:Data(body.prefix(count))) as? [String:Any])
        switch fault {
        case "engine":object["engineID"]="different-engine"
        case "version":object["version"]=2
        case "unknown":object["allowForeignSave"]=true
        default:object["payloadByteCount"]=4
        }
        let header=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        var changed=Data("HAKCHI_SNES_ENGINE_SAVE_V1\n\(header.count)\n".utf8);changed.append(header);changed.append(10);changed.append(Data(body.dropFirst(count+1)))
        #expect(throws:(any Error).self){try SNESCompatibilitySave(changed,kind:.suspend,gameCode:"CLV-U-ABCDE",romSHA256:rom)}
        #expect(try SNESCompatibilitySave(original.bytes,kind:.suspend,gameCode:"CLV-U-ABCDE",romSHA256:rom).payload==Data([1,2,3]))
    }
    @Test func saveCreationHasDistinctBatteryAndSnapshotBounds() {
        let rom=String(repeating:"a",count:64)
        #expect(throws:(any Error).self){try SNESCompatibilitySave.create(payload:Data(),kind:.battery,gameCode:"CLV-U-ABCDE",romSHA256:rom)}
        #expect(throws:(any Error).self){try SNESCompatibilitySave.create(payload:Data(count:128*1024+1),kind:.battery,gameCode:"CLV-U-ABCDE",romSHA256:rom)}
    }
}

struct SNESCompatibilityLibraryRecoveryTests {
    @Test func recoveryUsesVerifiedLibraryGameAndROM() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir=root.appendingPathComponent("CLV-U-ABCDE")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file=dir.appendingPathComponent("game.sfc"),rom=Data([1,2,3,4])
        try rom.write(to:file)
        var game=Game(code:"CLV-U-ABCDE",desktopContent:"Name=Game\n",consoleType:.snesUsa,source:.local)
        game.romPath=dir.path
        let source=try SNESLibraryROMSource.capture(directory:dir,filename:"game.sfc").0
        let save=try SNESCompatibilitySave.create(payload:Data([42]),kind:.battery,gameCode:game.code,romSHA256:source.sha256)
        #expect(try SNESCompatibilitySave.forLibraryRecovery(save.bytes,kind:.battery,game:game,source:source).payload==Data([42]))
        let otherROM=try SNESCompatibilitySave.create(payload:Data([42]),kind:.battery,gameCode:game.code,romSHA256:String(repeating:"b",count:64))
        #expect(throws:(any Error).self){try SNESCompatibilitySave.forLibraryRecovery(otherROM.bytes,kind:.battery,game:game,source:source)}
        var wrong=game;wrong=Game(code:"CLV-U-BCDEF",desktopContent:"Name=Other\n",consoleType:.snesUsa,source:.local);wrong.romPath=dir.path
        #expect(throws:(any Error).self){try SNESCompatibilitySave.forLibraryRecovery(save.bytes,kind:.battery,game:wrong,source:source)}
        var foreign=game;foreign.consoleType = .nes
        #expect(throws:(any Error).self){try SNESCompatibilitySave.forLibraryRecovery(save.bytes,kind:.battery,game:foreign,source:source)}
        var stock=game;stock.source = .stock
        #expect(throws:(any Error).self){try SNESCompatibilitySave.forLibraryRecovery(save.bytes,kind:.battery,game:stock,source:source)}
        let duplicate=dir.appendingPathComponent("another.smc");try rom.write(to:duplicate)
        #expect(throws:(any Error).self){try SNESCompatibilitySave.forLibraryRecovery(save.bytes,kind:.battery,game:game,source:source)}
        try FileManager.default.removeItem(at:duplicate)
        try Data([4,3,2,1]).write(to:file)
        #expect(throws:(any Error).self){try SNESCompatibilitySave.forLibraryRecovery(save.bytes,kind:.battery,game:game,source:source)}
    }
}
