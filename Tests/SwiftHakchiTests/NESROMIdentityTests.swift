import Foundation
import Testing
@testable import SwiftHakchi

struct NESROMIdentityTests {
    static func rom(trainer: Bool = false, trailer: Int = 0) -> Data {
        var header = Data([78, 69, 83, 26, 1, 1, trainer ? 4 : 0, 0] + Array(repeating: 0, count: 8))
        if trainer { header.append(Data(repeating: 43, count: 512)) }
        header.append(Data(repeating: 17, count: 16_384))
        header.append(Data(repeating: 29, count: 8_192))
        header.append(Data(repeating: 91, count: trailer))
        return header
    }
    @Test(arguments: [127, 128]) func checksumExcludesTrailingCollectionTags(count: Int) throws {
        let dir = try testDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("tagged.NES")
        let bytes = Self.rom(trailer: count); try bytes.write(to: url)
        #expect(CRC32.romChecksum(file: url) == CRC32.checksum(Self.rom().dropFirst(16)))
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test func checksumExcludesTrainerFromCartridgeIdentity() throws {
        let dir = try testDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("trainer.nes"); try Self.rom(trainer: true).write(to: url)
        #expect(CRC32.romChecksum(file: url) == CRC32.checksum(Self.rom().dropFirst(16)))
    }
    @Test func truncatedOrUnsupportedNES2CannotClaimCanonicalIdentity() throws {
        let dir = try testDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("bad.nes")
        try Self.rom().dropLast().write(to: url)
        #expect(CRC32.romChecksum(file: url) == nil)
        var nes2 = Self.rom(); nes2[7] = 8; try nes2.write(to: url)
        #expect(CRC32.romChecksum(file: url) == nil)
    }
}

extension NESROMIdentityTests {
    @Test func folderImportCollectsTopLevelRawROMsCaseInsensitively() throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try Self.rom().write(to: root.appendingPathComponent("First.NES"))
        try Self.rom().write(to: root.appendingPathComponent("Second.nes"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("README.txt"))
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Self.rom().write(to: nested.appendingPathComponent("third.nes"))
        #expect(try ROMImportPolicy.collectFolder(root, for: .nes).map(\.lastPathComponent) == ["First.NES", "Second.nes"])
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.nes"), withDestinationURL: root.appendingPathComponent("First.NES"))
        #expect(throws: (any Error).self) { try ROMImportPolicy.collectFolder(root, for: .nes) }
    }
}
