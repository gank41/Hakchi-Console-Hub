import Foundation
import Testing
import SwiftHakchiCore
@testable import SwiftHakchi

struct SNESIncludedGameCopyTests {
    private func fixture() -> (Data, Data, SNESOriginalGamesFrame.Entry) {
        let rom = GameGenie16BitTests.snes()
        let end = 48 + rom.count
        var image = Data(repeating: 0, count: end + 96)
        func set32(_ offset: Int, _ value: Int) {
            for index in 0..<4 { image[offset + index] = UInt8((value >> (index * 8)) & 255) }
        }
        set32(0, 0x100); set32(4, image.count); set32(8, 48); set32(12, end)
        image.replaceSubrange(48..<end, with: rom)
        let entry = SNESOriginalGamesFrame.Entry(code: "CLV-P-ABCDE", files: [], romName: "CLV-P-ABCDE.sfrom",
            romBytes: image.count, romSHA256: BackupManifest.digest(image), headers: Data(image.prefix(48)) + Data(image.suffix(48)))
        return (image, rom, entry)
    }
    @Test func extractsOnlyTheVerifiedGamePayloadWithoutChangingTheSource() throws {
        let (image, rom, entry) = fixture(), original = image
        #expect(try SNESIncludedGameCopy.rawROM(from: image, entry: entry) == rom)
        #expect(image == original)
    }
    @Test func refusesAlteredImagesAndUnverifiedContainerOffsets() throws {
        let (image, _, entry) = fixture()
        var changed = image; changed[100] ^= 1
        #expect(throws: (any Error).self) { try SNESIncludedGameCopy.rawROM(from: changed, entry: entry) }
        var wrong = image; wrong[8] = 1
        let rehashed = SNESOriginalGamesFrame.Entry(code: entry.code, files: [], romName: entry.romName,
            romBytes: wrong.count, romSHA256: BackupManifest.digest(wrong), headers: Data(wrong.prefix(48)) + Data(wrong.suffix(48)))
        #expect(throws: (any Error).self) { try SNESIncludedGameCopy.rawROM(from: wrong, entry: rehashed) }
    }
    @Test func acceptsOnlyTheChallengedAndVerifiedChunk() throws {
        let (image, _, entry) = fixture(), challenge = UUID(), context = String(repeating: "a", count: 64)
        let body = Data(image.prefix(SNESIncludedGameCopy.chunkSize))
        let digest = BackupManifest.digest(body)
        let header = "SWIFTHAKCHI_INCLUDED_CHUNK_V1 \(challenge.uuidString) \(context) \(entry.code) 0 \(body.count) \(digest)\n"
        let footer = "\nSWIFTHAKCHI_INCLUDED_CHUNK_END_V1 \(challenge.uuidString) \(digest)\n"
        let frame = Data(header.utf8) + body + Data(footer.utf8)
        #expect(try SNESIncludedGameCopy.chunk(frame, entry: entry, offset: 0, challenge: challenge, context: context) == body)
        #expect(throws: (any Error).self) { try SNESIncludedGameCopy.chunk(frame, entry: entry, offset: 0, challenge: UUID(), context: context) }
        var changed = frame; changed[header.utf8.count + 1] ^= 1
        #expect(throws: (any Error).self) { try SNESIncludedGameCopy.chunk(changed, entry: entry, offset: 0, challenge: challenge, context: context) }
        #expect(throws: (any Error).self) { try SNESIncludedGameCopy.chunk(frame + Data([0]), entry: entry, offset: 0, challenge: challenge, context: context) }
        #expect(throws: (any Error).self) { try SNESIncludedGameCopy.count(entry: entry, offset: 1) }
    }
}
