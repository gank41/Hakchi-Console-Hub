import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

func originalGamesBinding() -> SNESRuntimeBinding {
    .init(sourceSnapshot:"SNES-US-Setup-11111111-1111-1111-1111-111111111111",setupManifestSHA256:String(repeating:"a",count:64),expectedHWID:String(repeating:"1",count:32))
}
let originalGamesChallenge=UUID(uuidString:"11111111-2222-3333-4444-555555555555")!
func originalGamesFrameFixture(challenge:UUID=originalGamesChallenge) -> Data {
    let binding=originalGamesBinding(),wrapper=Data("#!/bin/sh\nexec /usr/bin/emulator \"$@\"\n".utf8)
    var raw=Data("SWIFTHAKCHI_SNES_ORIGINAL_GAMES_V1 \(challenge.uuidString)\nHWID \(binding.expectedHWID)\nWRAPPER \(wrapper.count) \(BackupManifest.digest(wrapper))\n".utf8)
    raw.append(wrapper);raw.append(10)
    for code in ["CLV-P-AAAAA","CLV-P-BBBBB"] {
        raw.append(Data("GAME \(code)\n".utf8))
        let files=[(code+".desktop",Data("[Desktop Entry]\nName=Été\nExec=/usr/bin/original\n".utf8)),(code+".png",Data([137,80,78,71,13,10,26,10]))]
        for (name,bytes) in files {raw.append(Data("FILE \(name) \(bytes.count) \(BackupManifest.digest(bytes))\n".utf8));raw.append(bytes);raw.append(10)}
        let headers=Data(repeating:127,count:96)
        raw.append(Data("ROM \(code).sfrom 65536 \(String(repeating:"c",count:64)) \(BackupManifest.digest(headers))\n".utf8));raw.append(headers);raw.append(Data("\nEND_GAME\n".utf8))
    }
    raw.append(Data("END 2\n".utf8));return raw
}
struct SNESOriginalGamesFrameTests {
    @Test func findsIncludedGameTitleAndLeavesUnknownCodesUnresolved() throws {
        let frame = try SNESOriginalGamesFrame(originalGamesFrameFixture(), binding: originalGamesBinding(), challenge: originalGamesChallenge)
        #expect(frame.gameTitle(for: "CLV-P-AAAAA") == "Été")
        #expect(frame.gameTitle(for: "CLV-P-XXXXX") == nil)
    }
    @Test func preservesExactMetadataAndOnlyFixedROMHeaders() throws {
        let raw=originalGamesFrameFixture(),frame=try SNESOriginalGamesFrame(raw,binding:originalGamesBinding(),challenge:originalGamesChallenge)
        #expect(frame.raw==raw && frame.entries.count==2)
        #expect(frame.entries.map(\.code)==["CLV-P-AAAAA","CLV-P-BBBBB"])
        #expect(frame.entries[0].files[0].data==Data("[Desktop Entry]\nName=Été\nExec=/usr/bin/original\n".utf8))
        #expect(frame.entries[0].romBytes==65536 && frame.entries[0].headers==Data(repeating:127,count:96))
        #expect(frame.entries[0].romSHA256==String(repeating:"c",count:64))
        #expect(frame.launcher==Data("#!/bin/sh\nexec /usr/bin/emulator \"$@\"\n".utf8))
    }
    @Test func rejectsWrongChallengeIdentityAndEveryTruncatedFrame() throws {
        let raw=originalGamesFrameFixture()
        #expect(throws:(any Error).self) {try SNESOriginalGamesFrame(raw,binding:originalGamesBinding(),challenge:UUID())}
        for n in [0,1,32,80,100,raw.count-1,raw.count-8] {#expect(throws:(any Error).self) {try SNESOriginalGamesFrame(Data(raw.prefix(n)),binding:originalGamesBinding(),challenge:originalGamesChallenge)}}
        #expect(throws:(any Error).self) {try SNESOriginalGamesFrame(raw+Data([0]),binding:originalGamesBinding(),challenge:originalGamesChallenge)}
        #expect(throws:(any Error).self) {try SNESOriginalGamesFrame(Data(count:8*1024*1024+1),binding:originalGamesBinding(),challenge:originalGamesChallenge)}
    }
    @Test func rejectsUnsafeNamesCountsHashesAndAmbiguousGroups() throws {
        let raw=originalGamesFrameFixture()
        let edits=[("HWID "+String(repeating:"1",count:32),"HWID "+String(repeating:"2",count:32)),("GAME CLV-P-AAAAA","GAME ../bad"),("FILE CLV-P-AAAAA.desktop","FILE ../evil.desktop"),("GAME CLV-P-BBBBB","GAME CLV-P-AAAAA"),("END 2","END 1"),("ROM CLV-P-AAAAA.sfrom 65536","ROM CLV-P-AAAAA.sfrom 16777217"),("ROM CLV-P-AAAAA.sfrom 65536","ROM CLV-P-AAAAA.sfrom 9223372036854775807"),("FILE CLV-P-AAAAA.png 8","FILE CLV-P-AAAAA.png 262145"),("FILE CLV-P-AAAAA.png 8","FILE CLV-P-AAAAA.png 08"),(String(repeating:"c",count:64),String(repeating:"g",count:64)),("Name=Été","Name=Autre")]
        for (old,new) in edits {
            var changed=raw;let range=try #require(changed.range(of:Data(old.utf8)));changed.replaceSubrange(range,with:Data(new.utf8))
            #expect(throws:(any Error).self) {try SNESOriginalGamesFrame(changed,binding:originalGamesBinding(),challenge:originalGamesChallenge)}
        }
        var changed=raw;let h=try #require(changed.range(of:Data(repeating:127,count:96)));changed[h.lowerBound]^=1
        #expect(throws:(any Error).self) {try SNESOriginalGamesFrame(changed,binding:originalGamesBinding(),challenge:originalGamesChallenge)}
    }
}
